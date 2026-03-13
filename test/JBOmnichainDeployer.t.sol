// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
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
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";

import {JBOmnichainDeployer} from "../src/JBOmnichainDeployer.sol";
import {IJBOmnichainDeployer} from "../src/interfaces/IJBOmnichainDeployer.sol";
import {JBDeployerHookConfig} from "../src/structs/JBDeployerHookConfig.sol";
import {JBOmnichain721Config} from "../src/structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "../src/structs/JBSuckerDeploymentConfig.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

/// @notice Unit tests for JBOmnichainDeployer.
contract TestJBOmnichainDeployer is Test {
    JBOmnichainDeployer deployer;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));

    address projectOwner = makeAddr("projectOwner");
    address sucker = makeAddr("sucker");
    address randomAddr = makeAddr("random");
    address dataHookAddr = makeAddr("dataHook");
    address hookAddr = makeAddr("hook721");

    uint256 projectId = 42;
    uint256 rulesetId = 100;

    function setUp() public {
        // Mock permissions.setPermissionsFor in constructor.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );

        deployer = new JBOmnichainDeployer(
            suckerRegistry,
            hookDeployer,
            permissions,
            projects,
            address(0) // trustedForwarder
        );

        // Default mocks.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, projectId), abi.encode(projectOwner)
        );
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Hook deployer mocks (every path now deploys a 721 hook).
        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());

        // Default mock: 721 hook returns original weight and empty specs (0 tiers).
        vm.mockCall(
            hookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(0), new JBPayHookSpecification[](0))
        );
    }

    //*********************************************************************//
    // --- Constructor --------------------------------------------------- //
    //*********************************************************************//

    function test_constructor() public view {
        assertEq(address(deployer.PROJECTS()), address(projects));
        assertEq(address(deployer.SUCKER_REGISTRY()), address(suckerRegistry));
        assertEq(address(deployer.HOOK_DEPLOYER()), address(hookDeployer));
    }

    //*********************************************************************//
    // --- supportsInterface --------------------------------------------- //
    //*********************************************************************//

    function test_supportsInterface() public view {
        assertTrue(deployer.supportsInterface(type(IJBOmnichainDeployer).interfaceId));
        assertTrue(deployer.supportsInterface(type(IJBRulesetDataHook).interfaceId));
        assertTrue(deployer.supportsInterface(type(IERC721Receiver).interfaceId));
    }

    //*********************************************************************//
    // --- onERC721Received ---------------------------------------------- //
    //*********************************************************************//

    function test_onERC721Received_acceptsFromProjects() public {
        vm.prank(address(projects));
        bytes4 result = deployer.onERC721Received(address(0), address(0), 1, "");
        assertEq(result, IERC721Receiver.onERC721Received.selector);
    }

    function test_onERC721Received_revertsIfNotProjects() public {
        vm.prank(randomAddr);
        vm.expectRevert();
        deployer.onERC721Received(address(0), address(0), 1, "");
    }

    //*********************************************************************//
    // --- beforePayRecordedWith ----------------------------------------- //
    //*********************************************************************//

    function test_beforePayRecordedWith_noHookReturnsOriginalWeight() public {
        JBBeforePayRecordedContext memory context = _makePayContext(projectId, rulesetId);

        (uint256 weight, JBPayHookSpecification[] memory specs) = deployer.beforePayRecordedWith(context);

        assertEq(weight, context.weight, "should return original weight");
        assertEq(specs.length, 0, "should return empty specs");
    }

    function test_beforePayRecordedWith_forwardsToDataHook() public {
        // First we need to set up a data hook by calling launchProjectFor.
        // Instead, let's directly test by using a rulesetId that maps to a stored hook.
        // We need to call a function that stores the data hook mapping internally.
        // Since _dataHookOf is internal, we set it up via launchProjectFor.

        // Mock controller.launchProjectFor.
        IJBController controller = IJBController(makeAddr("controller"));
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(IJBProjects.count.selector),
            abi.encode(uint256(41)) // next will be 42
        );
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.launchProjectFor.selector), abi.encode(projectId)
        );

        // Create ruleset config with a data hook.
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig(dataHookAddr, true, false);

        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](0);

        // We need to mock JBSuckerDeploymentConfig (no suckers for simplicity).
        // Call launchProjectFor to store the data hook.
        vm.mockCall(
            address(projects),
            abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)"))),
            abi.encode()
        );

        JBOmnichain721Config memory empty721Config;
        deployer.launchProjectFor(
            projectOwner, "test", empty721Config, configs, terminals, "", _emptySuckerConfig(), controller
        );

        // Now the data hook should be stored for projectId at rulesetId = block.timestamp.
        uint256 storedRulesetId = block.timestamp;

        // Mock the data hook to return specific values.
        JBPayHookSpecification[] memory mockSpecs = new JBPayHookSpecification[](0);
        vm.mockCall(
            dataHookAddr,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(999), mockSpecs)
        );

        JBBeforePayRecordedContext memory context = _makePayContext(projectId, storedRulesetId);

        (uint256 weight,) = deployer.beforePayRecordedWith(context);
        assertEq(weight, 999, "should forward to data hook");
    }

    //*********************************************************************//
    // --- beforeCashOutRecordedWith ------------------------------------- //
    //*********************************************************************//

    function test_beforeCashOutRecordedWith_suckerGetsZeroTax() public {
        // Mock sucker registry to say holder IS a sucker.
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );

        JBBeforeCashOutRecordedContext memory context = _makeCashOutContext(projectId, rulesetId, sucker);

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,) =
            deployer.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, 0, "sucker should get 0 tax");
        assertEq(cashOutCount, context.cashOutCount, "should pass through cashOutCount");
        assertEq(totalSupply, context.totalSupply, "should pass through totalSupply");
    }

    function test_beforeCashOutRecordedWith_nonSuckerGetsOriginalTax() public {
        // Mock sucker registry to say holder is NOT a sucker.
        vm.mockCall(
            address(suckerRegistry), abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector), abi.encode(false)
        );

        JBBeforeCashOutRecordedContext memory context = _makeCashOutContext(projectId, rulesetId, randomAddr);

        (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply,) =
            deployer.beforeCashOutRecordedWith(context);

        assertEq(cashOutTaxRate, context.cashOutTaxRate, "non-sucker should get original tax");
        assertEq(cashOutCount, context.cashOutCount);
        assertEq(totalSupply, context.totalSupply);
    }

    //*********************************************************************//
    // --- hasMintPermissionFor ------------------------------------------ //
    //*********************************************************************//

    function test_hasMintPermissionFor_trueForSucker() public {
        vm.mockCall(
            address(suckerRegistry),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, projectId, sucker),
            abi.encode(true)
        );

        JBRuleset memory ruleset;
        assertTrue(deployer.hasMintPermissionFor(projectId, ruleset, sucker));
    }

    function test_hasMintPermissionFor_falseForRandom() public {
        vm.mockCall(
            address(suckerRegistry), abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector), abi.encode(false)
        );

        JBRuleset memory ruleset;
        assertFalse(deployer.hasMintPermissionFor(projectId, ruleset, randomAddr));
    }

    //*********************************************************************//
    // --- deploySuckersFor: Permissions --------------------------------- //
    //*********************************************************************//

    function test_deploySuckersFor_revertsIfUnauthorized() public {
        // Mock permissions to return false.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false)
        );

        vm.prank(randomAddr);
        vm.expectRevert();
        deployer.deploySuckersFor(projectId, _emptySuckerConfig());
    }

    //*********************************************************************//
    // --- extraDataHookOf ----------------------------------------------- //
    //*********************************************************************//

    function test_extraDataHookOf_returnsEmpty() public view {
        JBDeployerHookConfig memory hook = deployer.extraDataHookOf(projectId, 999);
        assertEq(address(hook.dataHook), address(0));
    }

    //*********************************************************************//
    // --- Helpers ------------------------------------------------------- //
    //*********************************************************************//

    function _makePayContext(uint256 pid, uint256 rid) internal returns (JBBeforePayRecordedContext memory) {
        return JBBeforePayRecordedContext({
            terminal: makeAddr("terminal"),
            payer: randomAddr,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 1 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            projectId: pid,
            rulesetId: rid,
            beneficiary: randomAddr,
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
        address dataHook,
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
            dataHook: dataHook,
            metadata: 0
        });
        return config;
    }

    function _emptySuckerConfig() internal pure returns (JBSuckerDeploymentConfig memory config) {
        config.deployerConfigurations = new JBSuckerDeployerConfig[](0);
        config.salt = bytes32(0);
    }
}
