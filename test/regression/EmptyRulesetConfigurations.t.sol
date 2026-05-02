// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesets} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookProjectDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBOmnichainDeployer} from "../../src/JBOmnichainDeployer.sol";
import {JBSuckerDeploymentConfig} from "../../src/structs/JBSuckerDeploymentConfig.sol";

/// @title EmptyRulesetConfigurations
/// @notice Regression test: simplified overloads must revert with a descriptive error
///         when given an empty `rulesetConfigurations` array, instead of an opaque Panic(0x32).
contract EmptyRulesetConfigurations is Test {
    JBOmnichainDeployer deployer;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJB721TiersHookDeployer hookDeployer721 = IJB721TiersHookDeployer(makeAddr("hookDeployer"));

    IJBController controller = IJBController(makeAddr("controller"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBRulesets rulesets = IJBRulesets(makeAddr("rulesets"));

    function setUp() public {
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );
        deployer =
            new JBOmnichainDeployer(suckerRegistry, hookDeployer721, permissions, projects, directory, address(0));

        // Controller validation mocks — the deployer uses its immutable DIRECTORY.
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.controllerOf.selector),
            abi.encode(IERC165(address(controller)))
        );
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.RULESETS.selector), abi.encode(rulesets));
        vm.mockCall(
            address(rulesets), abi.encodeWithSelector(IJBRulesets.latestRulesetIdOf.selector), abi.encode(uint256(0))
        );
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );
    }

    /// @notice launchProjectFor with empty rulesetConfigurations reverts with descriptive error.
    function test_launchProjectFor_revertsOnEmptyRulesets() public {
        JBRulesetConfig[] memory empty = new JBRulesetConfig[](0);
        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](0);
        JBSuckerDeploymentConfig memory suckerConfig;

        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_NoRulesetConfigurations.selector);
        deployer.launchProjectFor(address(this), "uri", empty, terminals, "memo", suckerConfig, controller);
    }

    /// @notice queueRulesetsOf with empty rulesetConfigurations reverts with descriptive error.
    function test_queueRulesetsOf_revertsOnEmptyRulesets() public {
        JBRulesetConfig[] memory empty = new JBRulesetConfig[](0);

        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_NoRulesetConfigurations.selector);
        deployer.queueRulesetsOf(1, empty, "memo", controller);
    }

    /// @notice launchRulesetsFor with empty rulesetConfigurations reverts with descriptive error.
    function test_launchRulesetsFor_revertsOnEmptyRulesets() public {
        JBRulesetConfig[] memory empty = new JBRulesetConfig[](0);
        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](0);

        vm.expectRevert(JBOmnichainDeployer.JBOmnichainDeployer_NoRulesetConfigurations.selector);
        deployer.launchRulesetsFor(1, "", empty, terminals, "memo", controller);
    }
}
