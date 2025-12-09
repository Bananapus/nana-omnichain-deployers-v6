// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IJB721TiersHook} from "@bananapus/721-hook-v5/src/interfaces/IJB721TiersHook.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v5/src/structs/JBDeploy721TiersHookConfig.sol";
import {JBLaunchProjectConfig} from "@bananapus/721-hook-v5/src/structs/JBLaunchProjectConfig.sol";
import {JBLaunchRulesetsConfig} from "@bananapus/721-hook-v5/src/structs/JBLaunchRulesetsConfig.sol";
import {JBQueueRulesetsConfig} from "@bananapus/721-hook-v5/src/structs/JBQueueRulesetsConfig.sol";
import {IJBController} from "@bananapus/core-v5/src/interfaces/IJBController.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v5/src/interfaces/IJBRulesetDataHook.sol";
import {JBRulesetConfig} from "@bananapus/core-v5/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v5/src/structs/JBTerminalConfig.sol";
import {JBDeployerHookConfig} from "../structs/JBDeployerHookConfig.sol";
import {JBSuckerDeploymentConfig} from "../structs/JBSuckerDeploymentConfig.sol";

interface IJBOmnichainDeployer {
    function dataHookOf(
        uint256 projectId,
        uint256 rulesetId
    )
        external
        view
        returns (bool useDataHookForPay, bool useDataHookForCashout, IJBRulesetDataHook dataHook);

    function deploySuckersFor(
        uint256 projectId,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        returns (address[] memory suckers);

    function launchProjectFor(
        address owner,
        string calldata projectUri,
        JBRulesetConfig[] calldata rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string calldata memo,
        JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        IJBController controller
    )
        external
        returns (uint256 projectId, address[] memory suckers);

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

    function launchRulesetsFor(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        JBTerminalConfig[] memory terminalConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        returns (uint256 rulesetId);

    function launch721RulesetsFor(
        uint256 projectId,
        JBDeploy721TiersHookConfig memory deployTiersHookConfig,
        JBLaunchRulesetsConfig calldata launchRulesetsConfig,
        IJBController controller,
        bytes32 salt
    )
        external
        returns (uint256 rulesetId, IJB721TiersHook hook);

    function queueRulesetsOf(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        string calldata memo,
        IJBController controller
    )
        external
        returns (uint256 rulesetId);

    function queue721RulesetsOf(
        uint256 projectId,
        JBDeploy721TiersHookConfig memory deployTiersHookConfig,
        JBQueueRulesetsConfig memory queueRulesetsConfig,
        IJBController controller,
        bytes32 salt
    )
        external
        returns (uint256 rulesetId, IJB721TiersHook hook);
}
