// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesets} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "../../src/structs/JBOmnichain721Config.sol";

/// @title ValidateController
/// @notice Regression test: functions that accept a controller parameter must validate it
///         against the project's controller in the JBDirectory.
contract ValidateController is Test {
    JBOmnichainDeployer deployer;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJB721TiersHookDeployer hookDeployer721 = IJB721TiersHookDeployer(makeAddr("hookDeployer"));
    address hookAddr = makeAddr("hook721");

    IJBController legitimateController = IJBController(makeAddr("legitimateController"));
    IJBController fakeController = IJBController(makeAddr("fakeController"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBRulesets rulesets = IJBRulesets(makeAddr("rulesets"));

    address projectOwner = makeAddr("projectOwner");

    uint256 projectId = 42;

    function setUp() public {
        // Mock permissions.setPermissionsFor in constructor.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );

        deployer =
            new JBOmnichainDeployer(suckerRegistry, hookDeployer721, permissions, projects, directory, address(0));

        // Default mocks: permissions always pass.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, projectId), abi.encode(projectOwner)
        );
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Mock the directory to say the legitimate controller is the project's controller.
        // The deployer now uses its immutable DIRECTORY (passed in constructor) instead of controller.DIRECTORY().
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector, projectId),
            abi.encode(IERC165(address(legitimateController)))
        );

        // Mock RULESETS on both controllers.
        vm.mockCall(
            address(legitimateController), abi.encodeWithSelector(IJBController.RULESETS.selector), abi.encode(rulesets)
        );
        vm.mockCall(
            address(fakeController), abi.encodeWithSelector(IJBController.RULESETS.selector), abi.encode(rulesets)
        );
        vm.mockCall(
            address(rulesets),
            abi.encodeWithSelector(IJBRulesets.latestRulesetIdOf.selector, projectId),
            abi.encode(uint256(0))
        );

        // Hook deployer mocks (every path now deploys a 721 hook).
        vm.mockCall(
            address(hookDeployer721),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());
    }

    // ──────────────────── queueRulesetsOf
    // ────────────────────

    function test_queueRulesetsOf_revertsWithFakeController() public {
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig();
        JBOmnichain721Config memory empty721Config;

        vm.expectRevert(
            abi.encodeWithSelector(
                JBOmnichainDeployer.JBOmnichainDeployer_ControllerMismatch.selector,
                projectId,
                address(legitimateController),
                address(fakeController)
            )
        );
        deployer.queueRulesetsOf(projectId, empty721Config, configs, "memo", fakeController);
    }

    function test_queueRulesetsOf_succeedsWithLegitimateController() public {
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig();

        // Provide a 721 config with one tier so the deployer deploys a new hook
        // instead of trying to carry forward a non-existent one.
        JBOmnichain721Config memory config721;
        config721.deployTiersHookConfig.tiersConfig.tiers = new JB721TierConfig[](1);
        config721.deployTiersHookConfig.tiersConfig.tiers[0].price = 1 ether;
        config721.deployTiersHookConfig.tiersConfig.tiers[0].initialSupply = 100;
        config721.deployTiersHookConfig.tiersConfig.currency = uint32(uint160(JBConstants.NATIVE_TOKEN));
        config721.deployTiersHookConfig.tiersConfig.decimals = 18;

        // Mock the controller.queueRulesetsOf to succeed.
        vm.mockCall(
            address(legitimateController),
            abi.encodeWithSelector(IJBController.queueRulesetsOf.selector),
            abi.encode(uint256(1))
        );

        // Should not revert.
        deployer.queueRulesetsOf(projectId, config721, configs, "memo", legitimateController);
    }

    // ──────────────────── launchRulesetsFor
    // ────────────────────

    function test_launchRulesetsFor_revertsWithFakeController() public {
        JBRulesetConfig[] memory configs = new JBRulesetConfig[](1);
        configs[0] = _makeRulesetConfig();
        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](0);
        JBOmnichain721Config memory empty721Config;

        vm.expectRevert(
            abi.encodeWithSelector(
                JBOmnichainDeployer.JBOmnichainDeployer_ControllerMismatch.selector,
                projectId,
                address(legitimateController),
                address(fakeController)
            )
        );
        deployer.launchRulesetsFor(projectId, "", empty721Config, configs, terminals, "memo", fakeController);
    }

    // ──────────────────── Helpers
    // ────────────────────

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
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }
}
