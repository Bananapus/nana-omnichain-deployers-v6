// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBDeployerHookConfig} from "../structs/JBDeployerHookConfig.sol";
import {JBOmnichain721Config} from "../structs/JBOmnichain721Config.sol";
import {JBSuckerDeploymentConfig} from "../structs/JBSuckerDeploymentConfig.sol";

/// @notice Deploys Juicebox projects with omnichain sucker support.
interface IJBOmnichainDeployer {
    /// @notice Get the extra data hook for a project and ruleset.
    /// @param projectId The ID of the project to get the extra data hook for.
    /// @param rulesetId The ID of the ruleset to get the extra data hook for.
    /// @return hook The extra data hook configured for the project/ruleset.
    function extraDataHookOf(
        uint256 projectId,
        uint256 rulesetId
    )
        external
        view
        returns (JBDeployerHookConfig memory hook);

    /// @notice Get the tiered 721 hook config for a project and ruleset.
    /// @param projectId The ID of the project to get the 721 hook for.
    /// @param rulesetId The ID of the ruleset to get the 721 hook for.
    /// @return hook The 721 tiers hook.
    /// @return useDataHookForCashOut Whether the 721 hook is used for cash outs.
    function tiered721HookOf(
        uint256 projectId,
        uint256 rulesetId
    )
        external
        view
        returns (IJB721TiersHook hook, bool useDataHookForCashOut);

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

    /// @notice Creates a project, optionally with a 721 tiers hook attached, and with suckers.
    /// @dev If `deploy721Config.deployTiersHookConfig.tiersConfig.tiers.length > 0`, a 721 hook is deployed.
    /// @param owner The address to set as the owner of the project.
    /// @param projectUri The project's metadata URI.
    /// @param deploy721Config The 721 hook deployment config. Pass a zero-initialized struct for non-721 projects.
    /// @param rulesetConfigurations The rulesets to queue. Custom data hooks are read from each ruleset's metadata.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project.
    /// @param controller The controller to use for launching the project.
    /// @return projectId The ID of the newly launched project.
    /// @return hook The 721 tiers hook that was deployed for the project (`address(0)` if none).
    /// @return suckers The addresses of the deployed suckers.
    function launchProjectFor(
        address owner,
        string calldata projectUri,
        JBOmnichain721Config calldata deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        IJBController controller
    )
        external
        returns (uint256 projectId, IJB721TiersHook hook, address[] memory suckers);

    /// @notice Launches new rulesets for a project, optionally with a 721 tiers hook attached.
    /// @dev If `deploy721Config.deployTiersHookConfig.tiersConfig.tiers.length > 0`, a 721 hook is deployed.
    /// @param projectId The ID of the project to launch the rulesets for.
    /// @param deploy721Config The 721 hook deployment config. Pass a zero-initialized struct for non-721 rulesets.
    /// @param rulesetConfigurations The rulesets to launch. Custom data hooks are read from each ruleset's metadata.
    /// @param terminalConfigurations The terminals to set up for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @param controller The controller to use for launching the rulesets.
    /// @return rulesetId The ID of the newly launched rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project (`address(0)` if none).
    function launchRulesetsFor(
        uint256 projectId,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        returns (uint256 rulesetId, IJB721TiersHook hook);

    /// @notice Queues new rulesets for a project, optionally with a 721 tiers hook attached.
    /// @dev If `deploy721Config.deployTiersHookConfig.tiersConfig.tiers.length > 0`, a 721 hook is deployed.
    /// @param projectId The ID of the project to queue the rulesets for.
    /// @param deploy721Config The 721 hook deployment config. Pass a zero-initialized struct for non-721 rulesets.
    /// @param rulesetConfigurations The rulesets to queue. Custom data hooks are read from each ruleset's metadata.
    /// @param memo A memo to pass along to the emitted event.
    /// @param controller The controller to use for queuing the rulesets.
    /// @return rulesetId The ID of the newly queued rulesets.
    /// @return hook The 721 tiers hook that was deployed for the project (`address(0)` if none).
    function queueRulesetsOf(
        uint256 projectId,
        JBOmnichain721Config memory deploy721Config,
        JBRulesetConfig[] memory rulesetConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        returns (uint256 rulesetId, IJB721TiersHook hook);
}
