// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

/// @notice Configuration for an extra data hook (e.g. a buyback hook) that the omnichain deployer delegates to
/// alongside the primary 721 hook. Stored per project per ruleset.
/// @custom:member dataHook The extra data hook contract to delegate to.
/// @custom:member useDataHookForPay Whether to call this hook's `beforePayRecordedWith` during payments.
/// @custom:member useDataHookForCashOut Whether to call this hook's `beforeCashOutRecordedWith` during cash outs.
struct JBDeployerHookConfig {
    IJBRulesetDataHook dataHook;
    bool useDataHookForPay;
    bool useDataHookForCashOut;
}
