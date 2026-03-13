// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";

struct JBTiered721HookConfig {
    IJB721TiersHook hook;
    bool useDataHookForCashOut;
}
