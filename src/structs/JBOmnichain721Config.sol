// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";

/// @notice Configuration for deploying a 721 tiers hook alongside omnichain rulesets.
/// @param deployTiersHookConfig Configuration which dictates the behavior of the 721 tiers hook being deployed.
/// @param useDataHookForCashOut Whether the 721 hook should handle cash outs (via beforeCashOutRecordedWith).
/// @param salt A salt to use for the deterministic 721 hook deployment. Combined with `msg.sender` internally, so
/// cross-chain deterministic addresses require the same sender on each chain.
struct JBOmnichain721Config {
    JBDeploy721TiersHookConfig deployTiersHookConfig;
    bool useDataHookForCashOut;
    bytes32 salt;
}
