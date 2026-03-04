// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

struct JBDeployerHookConfig {
    bool useDataHookForPay;
    bool useDataHookForCashOut;
    IJBRulesetDataHook dataHook;
}
