// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {JBLaunchProjectConfig} from "@bananapus/721-hook-v6/src/structs/JBLaunchProjectConfig.sol";
import {JBLaunchRulesetsConfig} from "@bananapus/721-hook-v6/src/structs/JBLaunchRulesetsConfig.sol";
import {JBQueueRulesetsConfig} from "@bananapus/721-hook-v6/src/structs/JBQueueRulesetsConfig.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBDeployerHookConfig} from "../structs/JBDeployerHookConfig.sol";
import {JBSuckerDeploymentConfig} from "../structs/JBSuckerDeploymentConfig.sol";

interface IJBOmnichainDeployer {
    /// @notice Get the data hook for a project and ruleset.
    /// @param projectId The ID of the project to get the data hook for.
    /// @param rulesetId The ID of the ruleset to get the data hook for.
    /// @return useDataHookForPay Whether the data hook is used for pay.
    /// @return useDataHookForCashOut Whether the data hook is used for cash out.
    /// @return dataHook The data hook.
    function dataHookOf(
        uint256 projectId,
        uint256 rulesetId
    )
        external
        view
        returns (bool useDataHookForPay, bool useDataHookForCashOut, IJBRulesetDataHook dataHook);

    /// @notice Deploy new suckers for an existing project.
    /// @param projectId The ID of the project to deploy suckers for.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project.
    /// @return suckers The addresses of the deployed suckers.
    function deploySuckersFor(
        uint256 projectId,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        returns (address[] memory suckers);

    /// @notice Creates a project with suckers.
    /// @param owner The project's owner. The project ERC-721 will be minted to this address.
    /// @param projectUri The project's metadata URI.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project. Suckers facilitate cross-chain
    /// token transfers between peer projects on different networks.
    /// @param controller The controller to use for launching the project.
    /// @return projectId The project's ID.
    /// @return suckers The addresses of the deployed suckers.
    function launchProjectFor(
        address owner,
        string calldata projectUri,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        IJBController controller
    )
        external
        returns (uint256 projectId, address[] memory suckers);

    /// @notice Launches a new project with a 721 tiers hook attached, and with suckers.
    /// @param owner The address to set as the owner of the project.
    /// @param deployTiersHookConfig Configuration which dictates the behavior of the 721 tiers hook.
    /// @param launchProjectConfig Configuration which dictates the behavior of the project.
    /// @param salt A salt to use for the deterministic deployment.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project. Suckers facilitate cross-chain
    /// token transfers between peer projects on different networks.
    /// @param controller The controller to use for launching the project.
    /// @return projectId The ID of the newly launched project.
    /// @return hook The 721 tiers hook that was deployed for the project.
    /// @return suckers The addresses of the deployed suckers.
    function launch721ProjectFor(
        address owner,
        JBDeploy721TiersHookConfig calldata deployTiersHookConfig,
        JBLaunchProjectConfig calldata launchProjectConfig,
        bytes32 salt,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        IJBController controller
    )
        external
        returns (uint256 projectId, IJB721TiersHook hook, address[] memory suckers);

    /// @notice Launches new rulesets for a project, using this contract as the data hook.
    /// @param projectId The ID of the project to launch the rulesets for.
    /// @param rulesetConfigurations The rulesets to launch.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param controller The controller to use for launching the rulesets.
    /// @return rulesetId The ID of the newly launched rulesets.
    function launchRulesetsFor(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        returns (uint256 rulesetId);

    /// @notice Launches new rulesets for a project with a 721 tiers hook attached.
    /// @param projectId The ID of the project to launch the rulesets for.
    /// @param deployTiersHookConfig Configuration which dictates the behavior of the 721 tiers hook.
    /// @param launchRulesetsConfig Configuration which dictates the behavior of the rulesets.
    /// @param controller The controller to use for launching the rulesets.
    /// @param salt A salt to use for the deterministic deployment.
    /// @return rulesetId The ID of the newly launched rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function launch721RulesetsFor(
        uint256 projectId,
        JBDeploy721TiersHookConfig memory deployTiersHookConfig,
        JBLaunchRulesetsConfig calldata launchRulesetsConfig,
        IJBController controller,
        bytes32 salt
    )
        external
        returns (uint256 rulesetId, IJB721TiersHook hook);

    /// @notice Queues new rulesets for a project, using this contract as the data hook.
    /// @param projectId The ID of the project to queue the rulesets for.
    /// @param rulesetConfigurations The rulesets to queue.
    /// @param memo A memo to pass along to the emitted event.
    /// @param controller The controller to use for queuing the rulesets.
    /// @return rulesetId The ID of the newly queued rulesets.
    function queueRulesetsOf(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        returns (uint256 rulesetId);

    /// @notice Queues new rulesets for a project with a 721 tiers hook attached.
    /// @param projectId The ID of the project to queue the rulesets for.
    /// @param deployTiersHookConfig Configuration which dictates the behavior of the 721 tiers hook.
    /// @param queueRulesetsConfig Configuration which dictates the behavior of the rulesets.
    /// @param controller The controller to use for queuing the rulesets.
    /// @param salt A salt to use for the deterministic deployment.
    /// @return rulesetId The ID of the newly queued rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project.
    function queue721RulesetsOf(
        uint256 projectId,
        JBDeploy721TiersHookConfig memory deployTiersHookConfig,
        JBQueueRulesetsConfig calldata queueRulesetsConfig,
        IJBController controller,
        bytes32 salt
    )
        external
        returns (uint256 rulesetId, IJB721TiersHook hook);
}
