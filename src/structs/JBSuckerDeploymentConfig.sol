// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

/// @notice Configuration for deploying a project's suckers in one call: the per-peer deployer configs plus the salt
/// that seeds deterministic addresses.
/// @custom:member deployerConfigurations Sucker deployer configs and token mappings for peer chains.
/// @custom:member salt The salt combined with `_msgSender()` to create deterministic sucker addresses.
struct JBSuckerDeploymentConfig {
    JBSuckerDeployerConfig[] deployerConfigurations;
    bytes32 salt;
}
