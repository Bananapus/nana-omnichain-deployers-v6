# nana-omnichain-deployers-v6 Changelog (v5 -> v6)

This document describes all changes between `nana-omnichain-deployers` (v5) and `nana-omnichain-deployers-v6` (v6).

## Summary

- **Every project gets a 721 hook**: All projects launched through the omnichain deployer now receive a 721 hook (even without tiers), unifying the deployment model.
- **Dual-hook architecture**: Separate tracking of 721 hooks (`_tiered721HookOf`) and extra data hooks (`_extraDataHookOf`) enables composing both in `beforePayRecordedWith` with proportional weight scaling.
- **v5 ownership bug fixed**: `queue721RulesetsOf` in v5 deployed 721 hooks but never transferred ownership to the project — v6 properly calls `transferOwnershipToProject` on all paths.
- **Function consolidation**: `launch721ProjectFor`, `launch721RulesetsFor`, and `queue721RulesetsOf` merged into overloads of their non-721 counterparts using `JBOmnichain721Config`.
- **New safety checks**: Controller validation, ruleset ID collision protection, and explicit reverts replace `assert()`.

---

## 1. Breaking Changes

### 1.1 `launchProjectFor` signature completely reworked

**v5** had two separate entry points for launching projects: `launchProjectFor` (without 721 hook) and `launch721ProjectFor` (with 721 hook). v6 merges these into two overloads of `launchProjectFor`:

- **v5 `launchProjectFor`**: Accepted raw `JBRulesetConfig[]` and returned `(uint256 projectId, address[] suckers)`. No 721 hook was deployed.
- **v5 `launch721ProjectFor`**: Accepted `JBDeploy721TiersHookConfig`, `JBLaunchProjectConfig`, and a `bytes32 salt`. Returned `(uint256 projectId, IJB721TiersHook hook, address[] suckers)`.
- **v6 `launchProjectFor` (with 721 config)**: Accepts `JBOmnichain721Config`, `JBRulesetConfig[]`, `JBTerminalConfig[]`, `string memo`, `JBSuckerDeploymentConfig`, `IJBController`. Returns `(uint256 projectId, IJB721TiersHook hook, address[] suckers)`.
- **v6 `launchProjectFor` (default 721)**: Same parameters as v5's `launchProjectFor` but now also deploys a default empty-tier 721 hook. Returns `(uint256 projectId, IJB721TiersHook hook, address[] suckers)` -- note the added `IJB721TiersHook hook` return value.

Every project launched through v6 now gets a 721 hook, even if no tiers are configured. Projects that previously launched without a 721 hook via v5's `launchProjectFor` will now receive a default empty-tier 721 hook.

### 1.2 `launch721ProjectFor` removed

Replaced by the `launchProjectFor(... JBOmnichain721Config ...)` overload described above.

### 1.3 `launchRulesetsFor` signature reworked

**v5** had two entry points: `launchRulesetsFor` (without 721 hook) and `launch721RulesetsFor` (with 721 hook).

- **v5 `launchRulesetsFor`**: Accepted `JBRulesetConfig[]`, `JBTerminalConfig[]`, `string memo`, `IJBController`. No 721 hook deployed.
- **v5 `launch721RulesetsFor`**: Accepted `JBDeploy721TiersHookConfig`, `JBLaunchRulesetsConfig`, `IJBController`, `bytes32 salt`. Deployed a 721 hook.
- **v6 `launchRulesetsFor` (with 721 config)**: Accepts `JBOmnichain721Config`, `JBRulesetConfig[]`, `JBTerminalConfig[]`, `string memo`, `IJBController`. Returns `(uint256 rulesetId, IJB721TiersHook hook)`.
- **v6 `launchRulesetsFor` (default 721)**: Accepts `JBRulesetConfig[]`, `JBTerminalConfig[]`, `string memo`, `IJBController`. Returns `(uint256 rulesetId, IJB721TiersHook hook)`.

Both v6 overloads now return `IJB721TiersHook hook` alongside `rulesetId`.

v6 also uses the newly separated `LAUNCH_RULESETS` permission for `_launchRulesetsFor`. In v5, both `launchRulesetsFor` and `queueRulesetsOf` shared the same `QUEUE_RULESETS` permission ID. v6 splits these into two distinct permission IDs (`LAUNCH_RULESETS` and `QUEUE_RULESETS`), so `_launchRulesetsFor` now correctly requires `LAUNCH_RULESETS` since it calls `controller.launchRulesetsFor` (which sets terminals).

### 1.4 `launch721RulesetsFor` removed

Replaced by the `launchRulesetsFor(... JBOmnichain721Config ...)` overload described above.

### 1.5 `queueRulesetsOf` signature reworked

**v5** had two entry points: `queueRulesetsOf` (without 721 hook) and `queue721RulesetsOf` (with 721 hook).

- **v5 `queueRulesetsOf`**: Accepted `JBRulesetConfig[]`, `string memo`, `IJBController`. No 721 hook. Returned `uint256 rulesetId`.
- **v5 `queue721RulesetsOf`**: Accepted `JBDeploy721TiersHookConfig`, `JBQueueRulesetsConfig`, `IJBController`, `bytes32 salt`. Returned `(uint256 rulesetId, IJB721TiersHook hook)`.
- **v6 `queueRulesetsOf` (with 721 config)**: Accepts `JBOmnichain721Config`, `JBRulesetConfig[]`, `string memo`, `IJBController`. Returns `(uint256 rulesetId, IJB721TiersHook hook)`.
- **v6 `queueRulesetsOf` (default 721)**: Accepts `JBRulesetConfig[]`, `string memo`, `IJBController`. Returns `(uint256 rulesetId, IJB721TiersHook hook)`.

Both v6 overloads now return `IJB721TiersHook hook` alongside `rulesetId`.

v6 also fixes v5's `queue721RulesetsOf` which deployed the 721 hook but never called `JBOwnable(hook).transferOwnershipToProject(projectId)`, leaving the hook owned by the deployer contract rather than the project. In v6, all paths that deploy a 721 hook — including `_queueRulesetsOf` — properly transfer hook ownership to the project.

> **⚠️ This was a v5 bug**: Any project that used v5's `queue721RulesetsOf` to deploy a 721 hook has that hook owned by the deployer contract, not the project. Projects affected should manually transfer hook ownership.

### 1.6 `queue721RulesetsOf` removed

Replaced by the `queueRulesetsOf(... JBOmnichain721Config ...)` overload described above.

### 1.7 `dataHookOf` view replaced by `extraDataHookOf` and `tiered721HookOf`

**v5** had a single `dataHookOf(uint256 projectId, uint256 rulesetId)` view returning `(bool useDataHookForPay, bool useDataHookForCashout, IJBRulesetDataHook dataHook)`.

**v6** replaces this with two separate views:
- `extraDataHookOf(uint256 projectId, uint256 rulesetId)` returns `JBDeployerHookConfig memory hook` -- the non-721 data hook (e.g., buyback hook).
- `tiered721HookOf(uint256 projectId, uint256 rulesetId)` returns `(IJB721TiersHook hook, bool useDataHookForCashOut)` -- the 721 tiers hook.

### 1.8 `JBDeployerHookConfig` field order changed

**v5**: `{ bool useDataHookForPay, bool useDataHookForCashOut, IJBRulesetDataHook dataHook }`
**v6**: `{ IJBRulesetDataHook dataHook, bool useDataHookForPay, bool useDataHookForCashOut }`

The `dataHook` field moved from last to first. This changes ABI encoding and is a breaking change for any code constructing this struct positionally.

### 1.9 Solidity version bumped

**v5**: `pragma solidity 0.8.23`
**v6**: `pragma solidity 0.8.28`

### 1.10 721 hook config types replaced

**v5** used `JBDeploy721TiersHookConfig`, `JBLaunchProjectConfig`, `JBLaunchRulesetsConfig`, `JBQueueRulesetsConfig`, and `JBPayDataHookRulesetConfig` from `@bananapus/721-hook-v5`.

**v6** removes `JBLaunchProjectConfig`, `JBLaunchRulesetsConfig`, `JBQueueRulesetsConfig`, and `JBPayDataHookRulesetConfig` — the deployer now accepts standard `JBRulesetConfig[]` directly instead of those 721-specific config wrappers. `JBDeploy721TiersHookConfig` is still used but is now wrapped inside the new `JBOmnichain721Config` struct (see Section 5) rather than passed as a standalone parameter.

---

## 2. New Features

### 2.1 Default empty-tier 721 hook deployment

v6 introduces overloads of `launchProjectFor`, `launchRulesetsFor`, and `queueRulesetsOf` that accept standard `JBRulesetConfig[]` without any 721 configuration. These overloads automatically deploy a default empty-tier 721 hook using `_default721Config()`, which derives `currency` from the first ruleset's `baseCurrency` and sets `decimals = 18`. This ensures every project deployed through the omnichain deployer has a 721 hook, even if no tiers are configured.

### 2.2 721 hook carry-forward on queue

When queueing rulesets via `queueRulesetsOf`, if `deploy721Config.deployTiersHookConfig.tiersConfig.tiers.length == 0`, the 721 hook from the latest ruleset is carried forward instead of deploying a new one. This avoids unnecessary hook deployments when tiers haven't changed. If no previous hook exists (project was not launched through this deployer), the call reverts with `JBOmnichainDeployer_InvalidHook`.

### 2.3 Controller validation

v6 adds `_validateController()` which checks that the provided `IJBController` matches the project's controller registered in the directory. This is called by `_launchRulesetsFor` and `_queueRulesetsOf`. v5 had no such validation.

### 2.4 Ruleset ID collision protection

v6 adds a check in `_queueRulesetsOf` that reverts with `JBOmnichainDeployer_RulesetIdsUnpredictable()` if the project's `latestRulesetIdOf >= block.timestamp`, which would mean rulesets were already queued in the same block, making the `block.timestamp + i` ruleset ID prediction unreliable.

### 2.5 Dual-hook architecture (721 + extra data hook)

v5 stored a single `_dataHookOf` per project/ruleset. v6 introduces a dual-hook system:
- `_tiered721HookOf`: Stores the 721 tiers hook per project/ruleset (new).
- `_extraDataHookOf`: Stores any additional data hook (e.g., buyback hook) per project/ruleset (renamed from `_dataHookOf`).

The `beforePayRecordedWith` function now merges results from both hooks: the 721 hook contributes pay hook specifications (tier splits), while the extra data hook contributes weight adjustments. Weight is scaled using `mulDiv` to account for the portion of payment going to 721 tier splits vs. the project treasury.

### 2.6 `useDataHookForPay` forced to `true`

v5's `_setup` only forced `useDataHookForCashOut = true` on the wrapping metadata. v6's `_setup721` forces both `useDataHookForPay = true` and `useDataHookForCashOut = true`, ensuring all payments are routed through the deployer's `beforePayRecordedWith` wrapper.

### 2.7 `IERC165` support added to `supportsInterface`

v6 adds `interfaceId == type(IERC165).interfaceId` to the `supportsInterface` check, which was missing in v5.

### 2.8 Weight scaling with `mulDiv`

v6 imports `mulDiv` from `@prb/math` to scale the data hook's weight proportionally when 721 tier splits consume part of the payment amount. This prevents double-counting: tokens are only minted for the portion of the payment that enters the project treasury (after tier splits).

---

## 3. Event Changes

No events are defined directly in this contract or its interface in either v5 or v6. All events are emitted by downstream contracts (controller, sucker registry, etc.).

---

## 4. Error Changes

### 4.1 New errors in v6

| Error | Description |
|---|---|
| `JBOmnichainDeployer_ControllerMismatch()` | Thrown when the provided controller does not match the project's controller in the directory. |
| `JBOmnichainDeployer_ProjectIdMismatch()` | Thrown when the project ID returned by the controller does not match the expected project ID. Replaces the v5 `assert()` pattern. |
| `JBOmnichainDeployer_RulesetIdsUnpredictable()` | Thrown when queueing rulesets in the same block as a previous queue, making `block.timestamp + i` predictions unreliable. |
| `JBOmnichainDeployer_UnexpectedNFTReceived()` | Thrown in `onERC721Received` when the NFT is not from `JBProjects`. Replaces the bare `revert()` in v5. |

### 4.2 Retained errors

| Error | Notes |
|---|---|
| `JBOmnichainDeployer_InvalidHook()` | Expanded. Also thrown when `queueRulesetsOf` tries to carry forward a null hook (no tiers provided and no previous hook deployed through this contract). |

### 4.3 Removed patterns

- v5 used `assert()` for the project ID sanity check in `launchProjectFor` and `launch721ProjectFor`. v6 replaces this with an explicit `if (...) revert JBOmnichainDeployer_ProjectIdMismatch()`.
- v5 used bare `revert()` in `onERC721Received`. v6 uses `revert JBOmnichainDeployer_UnexpectedNFTReceived()`.

---

## 5. Struct Changes

### 5.1 New: `JBOmnichain721Config`

```solidity
struct JBOmnichain721Config {
    JBDeploy721TiersHookConfig deployTiersHookConfig;
    bool useDataHookForCashOut;
    bytes32 salt;
}
```

Bundles the 721 hook deployment config, cash-out flag, and deterministic deployment salt into a single struct. This replaces the separate `JBDeploy721TiersHookConfig` + `bytes32 salt` parameters used in v5. It also adds a `useDataHookForCashOut` flag that was not configurable in v5 (previously derived from the 721-specific metadata).

### 5.2 New: `JBTiered721HookConfig`

```solidity
struct JBTiered721HookConfig {
    IJB721TiersHook hook;
    bool useDataHookForCashOut;
}
```

Internal storage struct for tracking the 721 hook and its cash-out behavior per project/ruleset. This is new in v6 -- v5 did not separately track the 721 hook.

### 5.3 Modified: `JBDeployerHookConfig`

**v5:**
```solidity
struct JBDeployerHookConfig {
    bool useDataHookForPay;
    bool useDataHookForCashOut;
    IJBRulesetDataHook dataHook;
}
```

**v6:**
```solidity
struct JBDeployerHookConfig {
    IJBRulesetDataHook dataHook;
    bool useDataHookForPay;
    bool useDataHookForCashOut;
}
```

Field order changed: `dataHook` moved from third to first position. No fields added or removed.

### 5.4 Unchanged: `JBSuckerDeploymentConfig`

The struct is unchanged. Only the import path changed from `@bananapus/suckers-v5` to `@bananapus/suckers-v6`.

### 5.5 Removed 721-hook-specific config types

v5 relied on the following structs from `@bananapus/721-hook-v5`, which are no longer used by the deployer in v6:
- `JBLaunchProjectConfig`
- `JBLaunchRulesetsConfig`
- `JBQueueRulesetsConfig`
- `JBPayDataHookRulesetConfig`
- `JBPayDataHookRulesetMetadata`

v6 uses standard `JBRulesetConfig[]` directly, combined with `JBOmnichain721Config` for 721-specific settings.

---

## 6. Implementation Changes (Non-Interface)

### 6.1 Internal storage split

v5 had a single mapping:
```solidity
mapping(uint256 => mapping(uint256 => JBDeployerHookConfig)) internal _dataHookOf;
```

v6 splits this into two:
```solidity
mapping(uint256 => mapping(uint256 => JBDeployerHookConfig)) internal _extraDataHookOf;
mapping(uint256 => mapping(uint256 => JBTiered721HookConfig)) internal _tiered721HookOf;
```

### 6.2 `_setup` replaced by `_setup721`

v5's `_setup` stored the caller-provided data hook and replaced it with `address(this)`, forcing `useDataHookForCashOut = true`.

v6's `_setup721` does the same but additionally:
- Stores the 721 hook in `_tiered721HookOf` per ruleset.
- Stores the caller's original data hook (if any) in `_extraDataHookOf`.
- Forces both `useDataHookForPay = true` and `useDataHookForCashOut = true` on the wrapping metadata.

### 6.3 `_from721Config` removed

v5 had an internal `_from721Config` function that converted `JBPayDataHookRulesetConfig[]` to `JBRulesetConfig[]`, manually mapping each field from the 721-specific metadata struct to the standard `JBRulesetMetadata`. This entire conversion layer is removed in v6 because the deployer now accepts standard `JBRulesetConfig[]` directly.

### 6.4 `beforePayRecordedWith` rewritten

**v5**: Simply forwarded the call to the stored data hook (if any) and returned the original values otherwise.

**v6**: Implements a multi-hook composition:
1. Calls the 721 hook's `beforePayRecordedWith` to get tier split specs and total split amount.
2. Computes `projectAmount = context.amount.value - totalSplitAmount`.
3. Calls the extra data hook (if any) with a modified context where `amount.value = projectAmount`.
4. Scales the extra hook's weight using `mulDiv(weight, projectAmount, context.amount.value)` to prevent minting tokens for amounts going to tier splits.
5. Merges hook specifications from both hooks (721 specs first, then extra data hook specs).

### 6.5 `beforeCashOutRecordedWith` updated for dual hooks

**v5**: Checked for sucker (tax-free), then forwarded to the single data hook.

**v6**: Composes both hooks sequentially:
1. Sucker check (tax-free, unchanged).
2. 721 hook (if configured and `useDataHookForCashOut` is true) — updates cash out parameters.
3. Extra data hook (if configured and `useDataHookForCashOut` is true) — called with the already-updated values from the 721 hook.
4. Both hooks' specifications are merged (721 first, then extra).
5. Falls back to original context values if neither hook has the flag set.

### 6.6 `hasMintPermissionFor` simplified

**v5**: Checked sucker, then forwarded to the data hook.

**v6**: Checks sucker, then only checks the extra data hook (not the 721 hook, since "the 721 hook doesn't grant mint permission" per the code comment).

### 6.7 `assert()` replaced with explicit reverts

v5 used `assert(projectId == controller.launchProjectFor(...))`. v6 replaces this with `if (projectId != ...) revert JBOmnichainDeployer_ProjectIdMismatch()`, which provides a named error and does not consume all gas on failure.

### 6.8 Public functions refactored into internal implementations

v6 extracts the core logic into internal functions with a leading underscore:
- `_launchProjectFor` (shared by both `launchProjectFor` overloads)
- `_launchRulesetsFor` (shared by both `launchRulesetsFor` overloads)
- `_queueRulesetsOf` (shared by both `queueRulesetsOf` overloads)
- `_deploy721Hook` (extracts 721 hook deployment logic)
- `_default721Config` (generates default empty-tier 721 config)

v5 had all logic inline in the external functions.

### 6.9 `_validateController` added

New internal function that checks `controller.DIRECTORY().controllerOf(projectId) == controller`. Called from `_launchRulesetsFor` and `_queueRulesetsOf` but not from `_launchProjectFor` (since the project doesn't exist yet at validation time).

### 6.10 `onERC721Received` improved error

v5: `if (msg.sender != address(PROJECTS)) revert();`
v6: `if (msg.sender != address(PROJECTS)) revert JBOmnichainDeployer_UnexpectedNFTReceived();`

---

## 7. Migration Table

| v5 Function/View | v6 Equivalent | Notes |
|---|---|---|
| `launchProjectFor(owner, projectUri, rulesetConfigs, terminalConfigs, memo, suckerConfig, controller)` | `launchProjectFor(owner, projectUri, rulesetConfigs, terminalConfigs, memo, suckerConfig, controller)` | Same parameters but now also deploys a default 721 hook. Return type adds `IJB721TiersHook hook`. |
| `launch721ProjectFor(owner, deployTiersHookConfig, launchProjectConfig, salt, suckerConfig, controller)` | `launchProjectFor(owner, projectUri, deploy721Config, rulesetConfigs, terminalConfigs, memo, suckerConfig, controller)` | 721 config bundled into `JBOmnichain721Config`. Standard `JBRulesetConfig[]` replaces `JBLaunchProjectConfig`. |
| `launchRulesetsFor(projectId, rulesetConfigs, terminalConfigs, memo, controller)` | `launchRulesetsFor(projectId, rulesetConfigs, terminalConfigs, memo, controller)` | Return type adds `IJB721TiersHook hook`. Controller validation added. |
| `launch721RulesetsFor(projectId, deployTiersHookConfig, launchRulesetsConfig, controller, salt)` | `launchRulesetsFor(projectId, deploy721Config, rulesetConfigs, terminalConfigs, memo, controller)` | 721 config bundled into `JBOmnichain721Config`. Standard `JBRulesetConfig[]` replaces `JBLaunchRulesetsConfig`. |
| `queueRulesetsOf(projectId, rulesetConfigs, memo, controller)` | `queueRulesetsOf(projectId, rulesetConfigs, memo, controller)` | Return type adds `IJB721TiersHook hook`. Controller validation and ruleset ID collision check added. |
| `queue721RulesetsOf(projectId, deployTiersHookConfig, queueRulesetsConfig, controller, salt)` | `queueRulesetsOf(projectId, deploy721Config, rulesetConfigs, memo, controller)` | 721 config bundled into `JBOmnichain721Config`. Standard `JBRulesetConfig[]` replaces `JBQueueRulesetsConfig`. |
| `dataHookOf(projectId, rulesetId)` | `extraDataHookOf(projectId, rulesetId)` + `tiered721HookOf(projectId, rulesetId)` | Split into two views. `extraDataHookOf` returns `JBDeployerHookConfig memory`. `tiered721HookOf` returns `(IJB721TiersHook, bool)`. |
| `deploySuckersFor(projectId, suckerConfig)` | `deploySuckersFor(projectId, suckerConfig)` | Unchanged. |

> **Cross-repo impact**: Uses `LAUNCH_RULESETS` from `nana-permission-ids-v6` (split from `QUEUE_RULESETS`). The dual-hook composition pattern in `beforePayRecordedWith` uses `mulDiv` from `@prb/math` to scale weight proportionally — `revnet-core-v6` implements a similar pattern for its buyback hook + 721 hook composition.
