// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {JBOmnichainDeployer} from "../src/JBOmnichainDeployer.sol";
import {JBSuckerDeploymentConfig} from "../src/structs/JBSuckerDeploymentConfig.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

/// @notice Mock data hook that returns custom cashout values and grants mint permission.
contract CustomCashOutHook is IJBRulesetDataHook {
    uint256 public cashOutTaxRateReturn;
    uint256 public cashOutCountReturn;
    uint256 public totalSupplyReturn;
    bool public mintPermission;

    function setReturns(uint256 taxRate, uint256 count, uint256 supply) external {
        cashOutTaxRateReturn = taxRate;
        cashOutCountReturn = count;
        totalSupplyReturn = supply;
    }

    function setMintPermission(bool granted) external {
        mintPermission = granted;
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, JBPayHookSpecification[] memory)
    {
        return (context.weight, new JBPayHookSpecification[](0));
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata)
        external
        view
        override
        returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        return (cashOutTaxRateReturn, cashOutCountReturn, totalSupplyReturn, new JBCashOutHookSpecification[](0));
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external view override returns (bool) {
        return mintPermission;
    }

    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }
}

/// @title OmnichainDeployerEdgeCases
/// @notice Mock-based unit tests for edge cases and error paths not covered by existing tests.
contract OmnichainDeployerEdgeCases is Test {
    JBOmnichainDeployer deployer;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));

    address projectOwner = makeAddr("projectOwner");
    address sucker = makeAddr("sucker");
    address attacker = makeAddr("attacker");

    CustomCashOutHook customHook;

    uint256 projectId = 42;
    uint256 rulesetId;

    function setUp() public {
        customHook = new CustomCashOutHook();

        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );

        deployer = new JBOmnichainDeployer(suckerRegistry, hookDeployer, permissions, projects, address(0));

        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, projectId), abi.encode(projectOwner)
        );
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Default: not a sucker.
        vm.mockCall(
            address(suckerRegistry), abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector), abi.encode(false)
        );
    }

    // =========================================================================
    // Error path: InvalidHook — setting dataHook to deployer itself
    // =========================================================================
    function test_setup_revert_InvalidHook() public {
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
        configs[0] = _makeRulesetConfig(address(deployer), true, false);

        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_InvalidHook.selector);
        deployer.launchProjectFor(
            projectOwner, "test", configs, new JBTerminalConfig[](0), "", _emptySuckerConfig(), controller
        );
    }

    // =========================================================================
    // Error path: ProjectIdMismatch — controller returns wrong project ID
    // =========================================================================
    function test_launch_revert_ProjectIdMismatch() public {
        IJBController controller = IJBController(makeAddr("controller"));

        vm.mockCall(address(projects), abi.encodeWithSelector(IJBProjects.count.selector), abi.encode(uint256(41)));
        // Controller returns project ID 99 instead of expected 42.
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.launchProjectFor.selector),
            abi.encode(uint256(99))
        );

        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(address(0), false, false);

        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_ProjectIdMismatch.selector);
        deployer.launchProjectFor(
            projectOwner, "test", configs, new JBTerminalConfig[](0), "", _emptySuckerConfig(), controller
        );
    }

    // =========================================================================
    // Weight edge case: weight = 0 when totalSplitAmount >= context.amount.value
    // =========================================================================
    function test_beforePay_weightZero_whenProjectAmountZero() public {
        // Launch project with no custom hook.
        _launchProjectWithHook(address(0));
        rulesetId = block.timestamp;

        // Mock a 721 hook that returns a spec whose amount equals the full payment.
        address mock721 = makeAddr("mock721");
        _storeTiered721Hook(mock721);

        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](1);
        specs[0] = JBPayHookSpecification({hook: IJBPayHook(mock721), amount: 1 ether, metadata: ""});

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(1000), specs)
        );

        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, rulesetId);
        ctx.amount.value = 1 ether;
        ctx.weight = 1000;

        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);
        assertEq(weight, 0, "Weight should be 0 when full amount goes to splits");
    }

    // =========================================================================
    // Weight edge case: weight preserved when no splits and no hooks
    // =========================================================================
    function test_beforePay_weightPreserved_whenNoSplits() public {
        _launchProjectWithHook(address(0));
        rulesetId = block.timestamp;

        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, rulesetId);
        ctx.weight = 12_345;

        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(ctx);
        assertEq(weight, 12_345, "Weight should be preserved with no hooks");
        assertEq(specs.length, 0, "No specs expected");
    }

    // =========================================================================
    // Weight edge case: large weight near max — verify no overflow in mulDiv
    // =========================================================================
    function test_beforePay_largeWeight_mulDivSafety() public {
        _launchProjectWithHook(address(customHook));
        rulesetId = block.timestamp;

        // Custom hook returns near-max weight.
        vm.mockCall(
            address(customHook),
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(type(uint256).max, new JBPayHookSpecification[](0))
        );

        // Mock a 721 hook that takes 50% as splits.
        address mock721 = makeAddr("mock721");
        _storeTiered721Hook(mock721);

        JBPayHookSpecification[] memory specs721 = new JBPayHookSpecification[](1);
        specs721[0] = JBPayHookSpecification({hook: IJBPayHook(mock721), amount: 0.5 ether, metadata: ""});

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(0), specs721)
        );

        JBBeforePayRecordedContext memory ctx = _makePayContext(projectId, rulesetId);
        ctx.amount.value = 1 ether;
        ctx.weight = 1000;

        // Should not revert — mulDiv handles large values.
        (uint256 weight,) = deployer.beforePayRecordedWith(ctx);
        // weight = mulDiv(type(uint256).max, 0.5 ether, 1 ether) = type(uint256).max / 2
        assertEq(weight, type(uint256).max / 2, "mulDiv should handle near-max weight safely");
    }

    // =========================================================================
    // Cashout edge case: no hooks returns original values
    // =========================================================================
    function test_beforeCashOut_noHooks_returnsOriginalValues() public {
        // Launch with no custom hook.
        _launchProjectWithHook(address(0));
        rulesetId = block.timestamp;

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 5000, "Should return original tax rate");
        assertEq(cashOutCount, 1000, "Should return original cashOutCount");
        assertEq(totalSupply, 10_000, "Should return original totalSupply");
    }

    // =========================================================================
    // Cashout edge case: custom hook only (no 721) forwards correctly
    // =========================================================================
    function test_beforeCashOut_customHookOnly_forwardsCorrectly() public {
        customHook.setReturns(2000, 500, 8000);

        _launchProjectWithCustomCashOutHook(address(customHook));
        rulesetId = block.timestamp;

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 2000, "Should return custom hook tax rate");
        assertEq(cashOutCount, 500, "Should return custom hook cashOutCount");
        assertEq(totalSupply, 8000, "Should return custom hook totalSupply");
    }

    // =========================================================================
    // Cashout edge case: sucker bypasses 721 hook entirely
    // =========================================================================
    function test_beforeCashOut_suckerPriority_overrides721() public {
        // Launch with custom hook.
        customHook.setReturns(9000, 999, 999);

        _launchProjectWithCustomCashOutHook(address(customHook));
        rulesetId = block.timestamp;

        // Store a 721 hook too.
        address mock721 = makeAddr("mock721");
        _storeTiered721Hook(mock721);

        // Mark as sucker.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, sucker);

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 0, "Sucker should get 0 tax regardless of hooks");
        assertEq(cashOutCount, 1000, "Sucker should get original cashOutCount");
        assertEq(totalSupply, 10_000, "Sucker should get original totalSupply");
    }

    // =========================================================================
    // Cashout edge case: 721 hook skipped when useDataHookForCashOut is false
    // =========================================================================
    function test_beforeCashOut_721HookSkipped_whenFlagFalse() public {
        // Launch with useDataHookForCashOut = false (pay-only hook).
        _launchProjectWithHook(address(0));
        rulesetId = block.timestamp;

        // Store a 721 hook that would change values if called.
        address mock721 = makeAddr("mock721ForCashOut");
        _storeTiered721Hook(mock721);

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(9999), uint256(1), uint256(1), new JBCashOutHookSpecification[](0))
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        // Since useDataHookForCashOut is false, the 721 hook should NOT be called.
        // Original values should be returned.
        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 5000, "Should return original tax rate, not 721 hook's 9999");
        assertEq(cashOutCount, 1000, "Should return original cashOutCount, not 721 hook's 1");
        assertEq(totalSupply, 10_000, "Should return original totalSupply, not 721 hook's 1");
    }

    // =========================================================================
    // Cashout edge case: 721 hook called when useDataHookForCashOut is true
    // =========================================================================
    function test_beforeCashOut_721HookCalled_whenFlagTrue() public {
        // Launch with useDataHookForCashOut = true.
        _launchProjectWithCustomCashOutHook(address(0));
        rulesetId = block.timestamp;

        // Store a 721 hook that returns custom values.
        address mock721 = makeAddr("mock721ForCashOut");
        _storeTiered721Hook(mock721);

        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(uint256(9999), uint256(1), uint256(1), new JBCashOutHookSpecification[](0))
        );

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        // Since useDataHookForCashOut is true, the 721 hook SHOULD be called.
        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 9999, "Should return 721 hook's tax rate");
        assertEq(cashOutCount, 1, "Should return 721 hook's cashOutCount");
        assertEq(totalSupply, 1, "Should return 721 hook's totalSupply");
    }

    // =========================================================================
    // Cashout edge case: custom hook skipped when useDataHookForCashOut is false
    // =========================================================================
    function test_beforeCashOut_customHookSkipped_whenFlagFalse() public {
        // Launch with useDataHookForCashOut = false but a custom hook set.
        customHook.setReturns(2000, 1, 1);
        _launchProjectWithHook(address(customHook));
        rulesetId = block.timestamp;

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        // Since useDataHookForCashOut is false, the custom hook should NOT be called.
        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 5000, "Should return original tax rate, not custom hook's 2000");
        assertEq(cashOutCount, 1000, "Should return original cashOutCount, not custom hook's 1");
        assertEq(totalSupply, 10_000, "Should return original totalSupply, not custom hook's 1");
    }

    // =========================================================================
    // Cashout edge case: flag true, no hooks set, returns original values
    // =========================================================================
    function test_beforeCashOut_flagTrue_noHooks_returnsOriginal() public {
        // Launch with useDataHookForCashOut = true but no custom hook and no 721 hook.
        _launchProjectWithCustomCashOutHook(address(0));
        rulesetId = block.timestamp;

        JBBeforeCashOutRecordedContext memory ctx = _makeCashOutContext(projectId, rulesetId, attacker);

        // No 721 hook, no custom hook — should fall through to original values.
        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,) = deployer.beforeCashOutRecordedWith(ctx);
        assertEq(cashOutTaxRate, 5000, "Should return original tax rate");
        assertEq(cashOutCount, 1000, "Should return original cashOutCount");
        assertEq(totalSupply, 10_000, "Should return original totalSupply");
    }

    // =========================================================================
    // Mint permission: custom hook grants
    // =========================================================================
    function test_hasMintPermission_customHookGrants() public {
        customHook.setMintPermission(true);

        _launchProjectWithHook(address(customHook));
        rulesetId = block.timestamp;

        JBRuleset memory ruleset;
        ruleset.id = uint48(rulesetId);

        assertTrue(deployer.hasMintPermissionFor(projectId, ruleset, attacker), "Custom hook should grant mint");
    }

    // =========================================================================
    // Mint permission: custom hook denies but sucker overrides
    // =========================================================================
    function test_hasMintPermission_customHookDenies_suckerOverrides() public {
        customHook.setMintPermission(false);

        _launchProjectWithHook(address(customHook));
        rulesetId = block.timestamp;

        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );

        JBRuleset memory ruleset;
        ruleset.id = uint48(rulesetId);

        assertTrue(deployer.hasMintPermissionFor(projectId, ruleset, sucker), "Sucker should override custom hook deny");
    }

    // =========================================================================
    // Mint permission: no hook returns false
    // =========================================================================
    function test_hasMintPermission_noHook_returnsFalse() public {
        _launchProjectWithHook(address(0));
        rulesetId = block.timestamp;

        JBRuleset memory ruleset;
        ruleset.id = uint48(rulesetId);

        assertFalse(deployer.hasMintPermissionFor(projectId, ruleset, attacker), "No hook should return false");
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
        configs[0] = _makeRulesetConfig(hook, true, false);

        deployer.launchProjectFor(
            projectOwner, "test", configs, new JBTerminalConfig[](0), "", _emptySuckerConfig(), controller
        );
    }

    function _launchProjectWithCustomCashOutHook(address hook) internal {
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
        configs[0] = _makeRulesetConfig(hook, false, true);

        deployer.launchProjectFor(
            projectOwner, "test", configs, new JBTerminalConfig[](0), "", _emptySuckerConfig(), controller
        );
    }

    function _storeTiered721Hook(address hook721) internal {
        // Use vm.store to set tiered721HookOf[projectId] = hook721.
        // Slot is keccak256(abi.encode(projectId, 0)) for slot 0 (tiered721HookOf mapping).
        bytes32 slot = keccak256(abi.encode(projectId, uint256(0)));
        vm.store(address(deployer), slot, bytes32(uint256(uint160(hook721))));
        assertEq(address(deployer.tiered721HookOf(projectId)), hook721, "721 hook should be stored");
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
