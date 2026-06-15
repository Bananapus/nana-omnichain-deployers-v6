// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {JBOmnichainDeployer} from "../src/JBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "../src/structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "../src/structs/JBSuckerDeploymentConfig.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

interface IJBControllerProjectUriForTest {
    function setUriOf(uint256 projectId, string calldata uri) external;
}

/// @notice A `JBProjects` stand-in that records the fee payer the deployer advertises through `IJBPayerTracker`
/// while `createFor` runs — modelling a `pay`-routing creation-fee receiver that credits the original payer.
contract RecordingProjects {
    uint256 internal immutable PROJECT_ID;

    address public recordedPayerDuringCreate;
    bool public recordedSupportsTracker;

    constructor(uint256 projectId) {
        PROJECT_ID = projectId;
    }

    function createFor(address) external payable returns (uint256) {
        // The deployer (the caller) must expose the resolved fee payer for the duration of this call.
        recordedPayerDuringCreate = IJBPayerTracker(msg.sender).originalPayer();
        recordedSupportsTracker = JBOmnichainDeployer(msg.sender).supportsInterface(type(IJBPayerTracker).interfaceId);
        return PROJECT_ID;
    }

    function safeTransferFrom(address, address, uint256) external {}
}

/// @notice Proves `JBOmnichainDeployer` advertises the resolved fee payer (the EOA launching the project) to
/// `JBProjects.createFor`, rather than itself, so a `pay`-routing creation-fee receiver credits the user.
contract TestFeePayerAttribution is Test {
    JBOmnichainDeployer deployer;
    RecordingProjects projects;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBController controller = IJBController(makeAddr("controller"));

    address projectOwner = makeAddr("projectOwner");
    address feePayer = makeAddr("feePayer");
    address hookAddr = makeAddr("hook721");

    uint256 projectId = 42;

    function setUp() public {
        projects = new RecordingProjects(projectId);

        // Constructor wiring: the deployer reads `PROJECTS`/`DIRECTORY` off the controller.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.PROJECTS.selector), abi.encode(projects));
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBController.DIRECTORY.selector), abi.encode(directory)
        );

        deployer = new JBOmnichainDeployer(
            suckerRegistry,
            hookDeployer,
            permissions,
            controller,
            address(0) // trustedForwarder
        );

        // Launch-path mocks: every launch deploys a 721 hook, queues rulesets, and confirms the controller.
        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.launchRulesetsFor.selector),
            abi.encode(uint256(block.timestamp))
        );
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, projectId),
            abi.encode(controller)
        );
        vm.mockCall(
            address(controller), abi.encodeWithSelector(IJBControllerProjectUriForTest.setUriOf.selector), abi.encode()
        );
    }

    /// @notice The deployer reports adherence to `IJBPayerTracker`.
    function test_supportsInterface_payerTracker() public view {
        assertTrue(deployer.supportsInterface(type(IJBPayerTracker).interfaceId));
    }

    /// @notice `originalPayer` is `address(0)` outside of an in-flight launch.
    function test_originalPayer_zeroOutsideLaunch() public view {
        assertEq(deployer.originalPayer(), address(0), "no forwarding in progress");
    }

    /// @notice During `createFor`, the deployer advertises the resolved fee payer (the launching EOA), and the
    /// transient slot is cleared back to `address(0)` once the launch returns.
    function test_advertisesResolvedFeePayerDuringCreateFor() public {
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig();
        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](0);
        JBOmnichain721Config memory empty721Config;

        vm.prank(feePayer);
        deployer.launchProjectFor(projectOwner, "test", empty721Config, configs, terminals, "", _emptySuckerConfig());

        assertEq(projects.recordedPayerDuringCreate(), feePayer, "createFor should see the resolved fee payer");
        assertTrue(projects.recordedSupportsTracker(), "deployer should report IJBPayerTracker during createFor");
        assertEq(deployer.originalPayer(), address(0), "originalPayer should be cleared after the launch");
    }

    //*********************************************************************//
    // --- Helpers ------------------------------------------------------- //
    //*********************************************************************//

    function _makeRulesetConfig() internal pure returns (JBRulesetConfig memory config) {
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
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }

    function _emptySuckerConfig() internal pure returns (JBSuckerDeploymentConfig memory config) {
        config.deployerConfigurations = new JBSuckerDeployerConfig[](0);
        config.salt = bytes32(0);
    }
}
