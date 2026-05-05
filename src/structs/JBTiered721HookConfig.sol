// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";

/// @notice Stored configuration for a project's tiered 721 hook within a specific ruleset.
/// @param hook The tiered 721 hook contract used for NFT minting on payments.
/// @param useDataHookForCashOut Whether the 721 hook should participate in cash-out tax calculations and NFT
/// redemptions.
struct JBTiered721HookConfig {
    IJB721TiersHook hook;
    bool useDataHookForCashOut;
}
