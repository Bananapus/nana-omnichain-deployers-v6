// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

// forge-lint: disable-next-line(pascal-case-struct)
struct JBDeployerHookConfig {
    IJBRulesetDataHook dataHook;
    bool useDataHookForPay;
    bool useDataHookForCashOut;
}
