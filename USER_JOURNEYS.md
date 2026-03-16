# nana-omnichain-deployers-v6 -- User Journeys

## Journey 1: Deploy an Omnichain Project

### Actor
Any address (no permission required).

### Entry Point
```solidity
JBOmnichainDeployer.launchProjectFor(
    address owner,
    string calldata projectUri,
    JBOmnichain721Config calldata deploy721Config,    // or omit for default
    JBRulesetConfig[] memory rulesetConfigurations,
    JBTerminalConfig[] calldata terminalConfigurations,
    string calldata memo,
    JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
    IJBController controller
) external returns (uint256 projectId, IJB721TiersHook hook, address[] memory suckers)
```

There is a simplified overload that omits `deploy721Config` and derives a default (empty tiers, `baseCurrency` from first ruleset, 18 decimals).

### Parameters

| Parameter | Notes |
|-----------|-------|
| `owner` | Final recipient of the project NFT. Not the caller. |
| `projectUri` | Metadata URI (IPFS hash, etc). |
| `deploy721Config.deployTiersHookConfig` | Tier definitions, currency, name, symbol. Empty tiers array is valid -- a 721 hook is still deployed. |
| `deploy721Config.useDataHookForCashOut` | Whether the 721 hook handles cash-outs. Set `false` for fungible-only projects (721 hook reverts on fungible cash-outs). |
| `deploy721Config.salt` | For CREATE2 deterministic hook deployment. `bytes32(0)` disables determinism. Combined with `_msgSender()` internally. |
| `rulesetConfigurations` | Array of ruleset configs. Each can specify a custom `metadata.dataHook` (e.g. buyback hook). The deployer strips this and replaces it with itself. |
| `rulesetConfigurations[i].metadata.dataHook` | Custom hook address (buyback, etc). Stored in `_extraDataHookOf`. Set `address(0)` for none. Must NOT be `address(deployer)`. |
| `rulesetConfigurations[i].metadata.useDataHookForPay` | Stored alongside the custom hook. Determines if custom hook is called on payments. |
| `rulesetConfigurations[i].metadata.useDataHookForCashOut` | Stored alongside the custom hook. Determines if custom hook is called on cash-outs. |
| `terminalConfigurations` | Terminal + accounting contexts. At least one terminal with native token context for ETH projects. |
| `suckerDeploymentConfiguration.salt` | `bytes32(0)` to skip sucker deployment. Non-zero triggers `SUCKER_REGISTRY.deploySuckersFor`. |
| `suckerDeploymentConfiguration.deployerConfigurations` | Array of `JBSuckerDeployerConfig` -- bridge-specific configs for each target chain. |
| `controller` | The JBController to use. Not validated (project doesn't exist yet). Must be a legitimate controller that is `isAllowedToSetFirstController` in the directory. |

### State Changes

1. **721 hook deployed** via `HOOK_DEPLOYER.deployHookFor()`. The deployer is the initial owner.
2. **Hook mappings stored**: For each ruleset `i`:
   - `_tiered721HookOf[projectId][block.timestamp + i]` = 721 hook + cashout flag.
   - `_extraDataHookOf[projectId][block.timestamp + i]` = custom hook + flags (if specified).
3. **Ruleset metadata rewritten**: Every ruleset's `dataHook` becomes `address(deployer)`, `useDataHookForPay` and `useDataHookForCashOut` forced to `true`.
4. **Project created**: `controller.launchProjectFor()` mints the project NFT to the deployer.
5. **721 hook ownership transferred**: `JBOwnable(hook).transferOwnershipToProject(projectId)`.
6. **Suckers deployed** (if salt non-zero): `SUCKER_REGISTRY.deploySuckersFor()`.
7. **Project NFT transferred**: `PROJECTS.transferFrom(deployer, owner, projectId)`.

### Edge Cases

- **Simplified overload with zero rulesets**: Will revert because `_default721Config` accesses `rulesetConfigurations[0]` -- array index out of bounds.
- **Custom hook set to `address(this)`**: Reverts with `JBOmnichainDeployer_InvalidHook`.
- **Controller returns wrong project ID**: Reverts with `JBOmnichainDeployer_ProjectIdMismatch`. This can happen if another project is created in the same transaction before this call.
- **721 hook deployment with `salt == bytes32(0)`**: Deploys non-deterministically. Cross-chain address matching will fail.
- **Multiple rulesets**: Ruleset IDs are `block.timestamp`, `block.timestamp + 1`, etc. Each gets its own hook mapping entry. If the block timestamp is very large, `block.timestamp + i` could theoretically overflow (practically impossible with Solidity 0.8 checks).

---

## Journey 2: Launch Rulesets for an Existing Project

### Actor
Project owner or address with `QUEUE_RULESETS` + `SET_TERMINALS` permission.

### Entry Point
```solidity
JBOmnichainDeployer.launchRulesetsFor(
    uint256 projectId,
    JBOmnichain721Config memory deploy721Config,    // or omit for default
    JBRulesetConfig[] memory rulesetConfigurations,
    JBTerminalConfig[] calldata terminalConfigurations,
    string calldata memo,
    IJBController controller
) external returns (uint256 rulesetId, IJB721TiersHook hook)
```

### Parameters

Same as `launchProjectFor` except: no `owner`, no `suckerDeploymentConfiguration`, no `projectUri`. The `controller` IS validated against the directory.

### State Changes

1. **Permission checks**: `QUEUE_RULESETS` and `SET_TERMINALS` required.
2. **Controller validation**: `controller.DIRECTORY().controllerOf(projectId) == controller`. Reverts with `ControllerMismatch` if not.
3. **New 721 hook deployed**: Always deploys a new hook (no carry-forward option).
4. **Hook ownership transferred immediately**: Unlike `launchProjectFor`, the project already exists so ownership can be transferred right away.
5. **Hook mappings stored**: Same `_setup721` pattern.
6. **Rulesets launched**: `controller.launchRulesetsFor()`.

### Edge Cases

- **No ruleset ID prediction guard**: Unlike `queueRulesetsOf`, there is no check for `latestRulesetId >= block.timestamp`. If another ruleset operation happened in the same block, the predicted IDs may be wrong and the stored hooks will be keyed incorrectly.
- **Controller mismatch**: Reverts immediately before any state changes.
- **Insufficient permissions**: Reverts on the first failed permission check. Note: both `QUEUE_RULESETS` AND `SET_TERMINALS` are required -- having only one is not enough.

---

## Journey 3: Queue Rulesets for an Existing Project

### Actor
Project owner or address with `QUEUE_RULESETS` permission.

### Entry Point
```solidity
JBOmnichainDeployer.queueRulesetsOf(
    uint256 projectId,
    JBOmnichain721Config memory deploy721Config,    // or omit for default
    JBRulesetConfig[] memory rulesetConfigurations,
    string calldata memo,
    IJBController controller
) external returns (uint256 rulesetId, IJB721TiersHook hook)
```

### Parameters

Same as `launchRulesetsFor` but without `terminalConfigurations`. Only requires `QUEUE_RULESETS` (not `SET_TERMINALS`).

### State Changes

1. **Permission check**: `QUEUE_RULESETS` required.
2. **Controller validation**: Same as `launchRulesetsFor`.
3. **Ruleset ID prediction guard**:
   ```solidity
   uint256 latestRulesetId = controller.RULESETS().latestRulesetIdOf(projectId);
   if (latestRulesetId >= block.timestamp) revert JBOmnichainDeployer_RulesetIdsUnpredictable();
   ```
4. **721 hook**: If `deploy721Config.deployTiersHookConfig.tiersConfig.tiers.length > 0`, deploys new hook and transfers ownership. Otherwise, carries forward: `hook = _tiered721HookOf[projectId][latestRulesetId].hook`.
5. **Hook mappings stored**: Same `_setup721` pattern.
6. **Rulesets queued**: `controller.queueRulesetsOf()`.

### Edge Cases

- **Same-block queue**: Reverts with `JBOmnichainDeployer_RulesetIdsUnpredictable`. This happens if:
  - The project was launched in the same block.
  - Another `queueRulesetsOf` was called in the same block (via deployer or directly on controller).
  - Multiple rulesets were launched causing `latestRulesetId = block.timestamp + N` where `N >= 0`.
- **Carry-forward with no previous hook**: If `_tiered721HookOf[projectId][latestRulesetId]` was never set (project created outside the deployer), `hook` will be `address(0)`. The new rulesets will have a zero-address 721 hook stored, which means `beforePayRecordedWith` will skip the 721 path entirely.
- **Carry-forward with stale hook**: If the project owner previously queued rulesets with a different 721 hook via the deployer, the carry-forward uses the hook from the LATEST ruleset, not the currently active one. Verify `latestRulesetIdOf` returns the most recently queued (not necessarily active) ruleset.
- **Simplified overload**: The default config has 0 tiers, so the hook is always carried forward.

---

## Journey 4: Deploy Suckers for an Existing Project

### Actor
Project owner or address with `DEPLOY_SUCKERS` permission.

### Entry Point
```solidity
JBOmnichainDeployer.deploySuckersFor(
    uint256 projectId,
    JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration
) external returns (address[] memory suckers)
```

### Parameters

| Parameter | Notes |
|-----------|-------|
| `projectId` | Must be an existing project. |
| `suckerDeploymentConfiguration.salt` | Combined with `_msgSender()` for deterministic deployment. |
| `suckerDeploymentConfiguration.deployerConfigurations` | Bridge-specific sucker configs. |

### State Changes

1. **Permission check**: `DEPLOY_SUCKERS` required from project owner.
2. **Suckers deployed**: `SUCKER_REGISTRY.deploySuckersFor()` with salted hash.

### Edge Cases

- **Salt includes `_msgSender()`**: The same salt from different senders produces different sucker addresses. For cross-chain deterministic addresses, the same sender must deploy on each chain.
- **Empty deployerConfigurations**: Behavior depends on the sucker registry implementation.
- **Re-deployment with same salt**: Will revert at the CREATE2 level (address collision).

---

## Journey 5: Payment Through the Data Hook Proxy

### Actor
Any payer (this is a view function called by the terminal, not directly by users).

### Entry Point
Called by `JBMultiTerminal` during `pay()`:
```solidity
JBOmnichainDeployer.beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
    external view returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
```

### Flow

1. **721 hook check**: Load `_tiered721HookOf[context.projectId][context.rulesetId]`. If non-zero, call its `beforePayRecordedWith(context)`. Extract the first spec as the 721 split amount.
2. **Compute project amount**: `projectAmount = context.amount.value - totalSplitAmount` (floored at 0).
3. **Custom hook check**: Load `_extraDataHookOf[context.projectId][context.rulesetId]`. If non-zero and `useDataHookForPay == true`, call its `beforePayRecordedWith` with `amount.value = projectAmount`.
4. **Weight resolution**:
   - Custom hook called: `weight` from custom hook, then scaled by `projectAmount / context.amount.value`.
   - Custom hook not called: `weight = context.weight`, then scaled.
   - If `projectAmount == 0`: `weight = 0` regardless.
5. **Spec merging**: 721 spec (if any) first, then custom hook specs.

### Edge Cases

- **No hooks stored for this ruleset**: Returns `(context.weight, [])`. This happens when the project wasn't created through the deployer, or the ruleset ID doesn't match any stored mapping.
- **721 hook returns empty specs**: `hasTiered721Spec = false`, `totalSplitAmount = 0`. Custom hook sees full amount.
- **721 hook returns multiple specs**: Only `tiered721HookSpecs[0]` is used. The 721 hook contract always returns exactly one spec (itself), so this is not a practical concern.
- **Custom hook returns weight=0**: After scaling, `weight = 0`. This is the buyback hook's "swap path" -- it returns `weight = 0` when routing through the AMM.
- **Full split (721 takes entire payment)**: `projectAmount = 0`, custom hook sees `amount.value = 0`, `weight = 0`. All funds go to the 721 hook.
- **Overflow in mulDiv**: PRB math's `mulDiv` handles `type(uint256).max` correctly. Tested explicitly.

---

## Journey 6: Cash-Out Through the Data Hook Proxy

### Actor
Any token holder (view function called by terminal during `cashOutTokensOf`).

### Entry Point
Called by `JBMultiTerminal` during `cashOutTokensOf()`:
```solidity
JBOmnichainDeployer.beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
    external view returns (uint256 cashOutTaxRate, uint256 cashOutCount, uint256 totalSupply, JBCashOutHookSpecification[] memory)
```

### Flow (priority chain -- first match wins)

1. **Sucker check**: `SUCKER_REGISTRY.isSuckerOf(context.projectId, context.holder)`. If true: return `(0, context.cashOutCount, context.totalSupply, [])`. Sucker gets full pro-rata reclaim, 0% tax.
2. **721 hook**: If stored and `useDataHookForCashOut == true`, forward entirely to `tiered721Config.hook.beforeCashOutRecordedWith(context)`. Whatever the 721 hook returns is the final answer.
3. **Custom hook**: If stored and `useDataHookForCashOut == true`, forward entirely to `extraHook.dataHook.beforeCashOutRecordedWith(context)`.
4. **Fallback**: Return `(context.cashOutTaxRate, context.cashOutCount, context.totalSupply, [])`.

### Edge Cases

- **Sucker with reverting 721 hook**: The sucker check is first, so the 721 hook is never called. The sucker always gets 0% tax even if the 721 hook would revert.
- **Non-sucker with 721 `useDataHookForCashOut = true`**: The 721 hook is called. For fungible cash-outs, the 721 hook typically reverts with `JB721Hook_UnexpectedTokenCashedOut()`. This revert propagates -- the non-sucker cannot cash out fungible tokens. Set `useDataHookForCashOut = false` in the `deploy721Config` to avoid this.
- **Both 721 and custom hooks have `useDataHookForCashOut = true`**: Only the 721 hook is consulted. The custom hook is never reached for cash-outs when the 721 hook is configured.
- **Neither hook has `useDataHookForCashOut = true`**: Falls through to the original values. The ruleset's `cashOutTaxRate` applies as normal.

---

## Journey 7: Mint Permission Check

### Actor
Called by `JBController` during token minting.

### Entry Point
```solidity
JBOmnichainDeployer.hasMintPermissionFor(uint256 projectId, JBRuleset memory ruleset, address addr)
    external view returns (bool)
```

### Flow

1. **Sucker check**: If `SUCKER_REGISTRY.isSuckerOf(projectId, addr)` returns true, return `true`.
2. **Custom hook check**: If `_extraDataHookOf[projectId][ruleset.id]` exists, delegate to its `hasMintPermissionFor`. If it returns true, return `true`.
3. **721 hook is NOT checked**: The 721 hook does not grant mint permission through this path.
4. **Default**: Return `false`.

### Edge Cases

- **No stored hooks for this ruleset**: Only the sucker check applies. Non-suckers cannot mint.
- **Custom hook reverts**: The revert propagates. Mint permission check fails.
- **Sucker registered after project launch**: If the sucker registry is updated to include a new sucker, that address immediately gets mint permission for all omnichain projects (no per-project opt-in beyond the registry).

---

## Journey 8: Adversarial -- Reverting Custom Hook

### Scenario
A project is launched with a custom data hook that always reverts.

### Impact on Payments
`beforePayRecordedWith` calls the custom hook. If the custom hook reverts, the entire payment transaction reverts. The project cannot receive payments.

**Mitigation**: The project owner can queue new rulesets without the reverting hook (set `metadata.dataHook = address(0)` in new rulesets).

### Impact on Cash-Outs
If the custom hook has `useDataHookForCashOut = true` and the 721 hook does not handle cash-outs:
- Suckers: Unaffected. The sucker check returns before the hook is consulted.
- Non-suckers: Cash-outs revert. Tokens are locked until new rulesets are queued.

If the 721 hook has `useDataHookForCashOut = true`: The 721 hook is consulted first. If IT reverts, cash-outs fail regardless of the custom hook.

### Impact on Mint Permission
If the custom hook reverts on `hasMintPermissionFor`, the call propagates the revert. Suckers are unaffected (checked first). Non-suckers cannot get mint permission.

---

## Journey 9: Adversarial -- Rapid Ruleset Queueing

### Scenario
An attacker or automated system attempts to queue rulesets multiple times in the same block.

### Via the Deployer
The first call to `queueRulesetsOf` succeeds. The second call in the same block finds `latestRulesetId >= block.timestamp` and reverts with `JBOmnichainDeployer_RulesetIdsUnpredictable`.

### Via Controller Then Deployer (same block)
If rulesets are queued directly on the controller first (bypassing the deployer), then the deployer's `queueRulesetsOf` is called in the same block: the deployer detects the conflict and reverts.

### Via Deployer Then Controller
The deployer queues rulesets (storing hooks at `block.timestamp + i`). Then the controller queues more rulesets in the same tx. The controller's new rulesets get IDs starting from where the deployer left off. These new rulesets have `dataHook = address(deployer)` (from the deployer's `_setup721`), but the deployer has no hook mappings for these IDs (they were queued by the controller, not the deployer). Payments/cash-outs through these rulesets will hit the deployer's data hook proxy but find no stored hooks, returning default values (original weight, no 721 integration, no sucker bypass for cash-outs).

### Cross-Chain Timing
If the same `queueRulesetsOf` call is executed on two chains in different blocks, the stored hook mappings will be keyed to different `block.timestamp` values. This is expected -- ruleset IDs are chain-specific.

---

## Journey 10: Adversarial -- Fake Controller

### Scenario
An attacker provides a malicious controller address to `queueRulesetsOf` or `launchRulesetsFor`.

### Outcome
The `_validateController` function checks:
```solidity
address(controller.DIRECTORY().controllerOf(projectId)) != address(controller)
```

If the attacker's controller returns a different directory, or the directory returns a different controller, the check fails and the call reverts with `JBOmnichainDeployer_ControllerMismatch`.

A sophisticated attacker could deploy a controller that returns a directory where `controllerOf(projectId)` returns the attacker's controller. However, this would require the project to actually be using the attacker's controller in the canonical directory, which would mean the project is already compromised.

For `launchProjectFor`: There is no controller validation because the project doesn't exist yet. A malicious controller could:
1. Return a fake project ID -- caught by `ProjectIdMismatch`.
2. Mint the project NFT but configure it maliciously -- the deployer transfers ownership to the intended `owner`, who can reconfigure.
3. Not mint the project NFT at all -- the `PROJECTS.transferFrom` at the end would revert.

---

## Journey 11: Hook Ownership Lifecycle

### During `launchProjectFor`
1. `HOOK_DEPLOYER.deployHookFor()` -- hook is owned by `JBOmnichainDeployer`.
2. `controller.launchProjectFor(address(this), ...)` -- project NFT minted to deployer.
3. `JBOwnable(hook).transferOwnershipToProject(projectId)` -- hook now owned by project.
4. `PROJECTS.transferFrom(deployer, owner, projectId)` -- project (and transitively hook ownership) transferred to intended owner.

**Failure scenario**: If `controller.launchProjectFor` reverts, the 721 hook exists but the entire transaction reverts atomically. The hook bytecode is deployed but the tx effects are rolled back, so the hook is effectively orphaned at the EVM level (no state changes persist).

### During `queueRulesetsOf` (new tiers)
1. `_deploy721Hook()` -- hook owned by deployer.
2. `JBOwnable(hook).transferOwnershipToProject(projectId)` -- immediately transferred.

### During `queueRulesetsOf` (carry-forward)
No new hook deployment. The existing hook's ownership is unchanged.

---

## Journey 12: Default 721 Config Derivation

### Entry Point
Any simplified overload that omits `JBOmnichain721Config`.

### Logic
```solidity
function _default721Config(JBRulesetConfig[] memory rulesetConfigurations)
    internal pure returns (JBOmnichain721Config memory config)
{
    config.deployTiersHookConfig.tiersConfig.currency = rulesetConfigurations[0].metadata.baseCurrency;
    config.deployTiersHookConfig.tiersConfig.decimals = 18;
}
```

- Currency from first ruleset's `baseCurrency`.
- 18 decimals hardcoded.
- Empty tiers array (0 tiers).
- `useDataHookForCashOut = false` (default).
- `salt = bytes32(0)` (non-deterministic deployment).

### Edge Cases

- **Empty rulesets array**: Reverts with array index out of bounds on `rulesetConfigurations[0]`.
- **Non-18-decimal token**: The 721 hook will use 18 decimals regardless. This affects tier pricing if the project's accounting context uses a different precision.
