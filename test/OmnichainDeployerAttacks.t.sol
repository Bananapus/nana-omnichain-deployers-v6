// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {JBOmnichainDeployer} from "../src/JBOmnichainDeployer.sol";
import {IJBOmnichainDeployer} from "../src/interfaces/IJBOmnichainDeployer.sol";
import {JBSuckerDeploymentConfig} from "../src/structs/JBSuckerDeploymentConfig.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

/// @notice Mock data hook that always reverts.
contract RevertingDataHook is IJBRulesetDataHook {
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata)
        external
        pure
        override
        returns (uint256, JBPayHookSpecification[] memory)
    {
        revert("Hook always reverts");
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        revert("Hook always reverts");
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure override returns (bool) {
        return false;
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

/// @notice Mock data hook that inflates weight.
contract InflatingDataHook is IJBRulesetDataHook {
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata)
        external
        pure
        override
        returns (uint256, JBPayHookSpecification[] memory)
    {
        return (type(uint256).max, new JBPayHookSpecification[](0));
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        return (context.cashOutTaxRate, context.cashOutCount, context.totalSupply, new JBCashOutHookSpecification[](0));
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure override returns (bool) {
        return false;
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

/// @title OmnichainDeployerAttacks
/// @notice Adversarial security tests for JBOmnichainDeployer.
contract OmnichainDeployerAttacks is Test {
    JBOmnichainDeployer deployer;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));

    address projectOwner = makeAddr("projectOwner");
    address sucker = makeAddr("sucker");
    address attacker = makeAddr("attacker");
    address dataHookAddr;
    RevertingDataHook revertingHook;
    InflatingDataHook inflatingHook;

    uint256 projectId = 42;
    uint256 rulesetId = 100;

    function setUp() public {
        revertingHook = new RevertingDataHook();
        inflatingHook = new InflatingDataHook();
        dataHookAddr = makeAddr("dataHook");

        // Mock permissions.setPermissionsFor in constructor.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );

        deployer = new JBOmnichainDeployer(suckerRegistry, hookDeployer, permissions, projects, address(0));

        // Default mocks.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, projectId), abi.encode(projectOwner)
        );
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
    }

    // =========================================================================
    // Test 1: onERC721Received rejects non-PROJECTS NFTs
    // =========================================================================
    function test_onERC721Received_rejectsNonProjectsNFT() public {
        address randomNFT = makeAddr("randomNFT");
        vm.prank(randomNFT);
        vm.expectRevert();
        deployer.onERC721Received(address(0), address(0), 1, "");
    }

    // =========================================================================
    // Test 2: Sucker tax bypass — legitimate sucker gets 0% tax
    // =========================================================================
    function test_suckerTaxBypass_legitimate() public {
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, sucker);

        (uint256 cashOutTaxRate,,,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 0, "Sucker should get 0 tax");
    }

    // =========================================================================
    // Test 3: Fake sucker — non-sucker does NOT get tax bypass
    // =========================================================================
    function test_fakeSucker_doesNotGetBypass() public {
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, attacker),
            abi.encode(false)
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        (uint256 cashOutTaxRate,,,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 5000, "Non-sucker should get original tax");
    }

    // =========================================================================
    // Test 4: hasMintPermissionFor — random address denied
    // =========================================================================
    function test_hasMintPermission_randomDenied() public {
        vm.mockCall(
            address(suckerRegistry), abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector), abi.encode(false)
        );

        JBRuleset memory ruleset;
        assertFalse(deployer.hasMintPermissionFor(projectId, ruleset, attacker));
    }

    // =========================================================================
    // Test 5: deploySuckersFor — unauthorized caller reverts
    // =========================================================================
    function test_deploySuckersFor_noPermission_reverts() public {
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false)
        );

        vm.prank(attacker);
        vm.expectRevert();
        deployer.deploySuckersFor(projectId, _emptySuckerConfig());
    }

    // =========================================================================
    // Test 6: beforePayRecordedWith — no hook stored, pass through weight
    // =========================================================================
    function test_beforePay_noHook_returnsOriginalWeight() public {
        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, rulesetId);

        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(ctx);

        assertEq(weight, ctx.weight, "Should return original weight");
        assertEq(specs.length, 0, "Should return no specs");
    }

    // =========================================================================
    // Test 7: Reverting hook blocks all payments when forwarded
    // =========================================================================
    function test_revertingHook_blocksPayments() public {
        // Launch a project with the reverting hook as data hook.
        _launchProjectWithHook(address(revertingHook));

        uint256 storedRulesetId = block.timestamp;

        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, storedRulesetId);

        // The deployer forwards to the reverting hook — should revert.
        vm.expectRevert("Hook always reverts");
        deployer.beforePayRecordedWith(ctx);
    }

    // =========================================================================
    // Test 8: Inflating hook returns type(uint256).max weight
    // =========================================================================
    function test_inflatingHook_returnsMaxWeight() public {
        _launchProjectWithHook(address(inflatingHook));

        uint256 storedRulesetId = block.timestamp;

        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, storedRulesetId);

        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);
        assertEq(weight, type(uint256).max, "Inflating hook should return max weight");
    }

    // =========================================================================
    // Test 9: Reverting hook blocks cash-outs for non-suckers
    // =========================================================================
    function test_revertingHook_blocksCashOutForNonSucker() public {
        _launchProjectWithHook(address(revertingHook));

        uint256 storedRulesetId = block.timestamp;

        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, attacker),
            abi.encode(false)
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, storedRulesetId, attacker);

        // Non-sucker triggers hook forwarding which reverts.
        vm.expectRevert("Hook always reverts");
        deployer.beforeCashOutRecordedWith(ctx);
    }

    // =========================================================================
    // Test 10: Sucker bypasses reverting hook for cash-outs
    // =========================================================================
    function test_suckerBypassesRevertingHook_forCashOut() public {
        _launchProjectWithHook(address(revertingHook));

        uint256 storedRulesetId = block.timestamp;

        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, storedRulesetId, sucker);

        // Sucker gets early return with 0 tax — never hits the reverting hook.
        (uint256 cashOutTaxRate,,,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 0, "Sucker bypasses hook and gets 0 tax");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _launchProjectWithHook(address hook) internal {
        IJBController controller = IJBController(makeAddr("controller"));

        vm.mockCall(address(projects), abi.encodeWithSelector(IJBProjects.count.selector), abi.encode(uint256(41)));
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.launchProjectFor.selector), abi.encode(projectId)
        );
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(bytes4(keccak256("safeTransferFrom(address,address,uint256)"))),
            abi.encode()
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(hook, true, true);

        deployer.launchProjectFor(
            projectOwner, "test", configs, new JBTerminalConfig[](0), "", _emptySuckerConfig(), controller
        );
    }

    function _makePayContext(uint256 pid, uint256 rid) internal returns (JBBeforePayRecordedContext memory) {
        return JBBeforePayRecordedContext({
            terminal: makeAddr("terminal"),
            payer: attacker,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 1 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            projectId: pid,
            rulesetId: rid,
            beneficiary: attacker,
            weight: 1000,
            reservedPercent: 0,
            metadata: ""
        });
    }

    function _makeCashOutContext(
        uint256 pid,
        uint256 rid,
        address holder
    )
        internal
        returns (JBBeforeCashOutRecordedContext memory)
    {
        return JBBeforeCashOutRecordedContext({
            terminal: makeAddr("terminal"),
            holder: holder,
            projectId: pid,
            rulesetId: rid,
            cashOutCount: 1000,
            totalSupply: 10_000,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 5 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            useTotalSurplus: false,
            cashOutTaxRate: 5000,
            metadata: ""
        });
    }

    function _makeRulesetConfig(
        address hook,
        bool useForPay,
        bool useForCashOut
    )
        internal
        pure
        returns (JBRulesetConfig memory)
    {
        JBRulesetConfig memory config;
        config.metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: useForPay,
            useDataHookForCashOut: useForCashOut,
            dataHook: hook,
            metadata: 0
        });
        return config;
    }

    function _emptySuckerConfig() internal pure returns (JBSuckerDeploymentConfig memory config) {
        config.deployerConfigurations = new JBSuckerDeployerConfig[](0);
        config.salt = bytes32(0);
    }
}
