# Changelog

## 0.0.57 — Adopt per-context oracle-free cross-chain surplus

- Raised `@bananapus/suckers-v6` `^0.0.67 → ^0.0.69` to adopt the per-context cross-chain surplus API.
- `JBOmnichainDeployer.beforeCashOutRecordedWith` now calls `SUCKER_REGISTRY.totalRemoteSurplusOf(projectId, currency,
  decimals)` (renamed from `remoteSurplusOf`, with `currency` and `decimals` swapped); `remoteTotalSupplyOf` is
  unchanged.
- `JBOmnichainDeployer.peerChainAdjustedAccountsOf` now takes only `projectId` and returns `(uint256 supply,
  JBSourceContext[] contexts)`. The forwarder re-encodes the staticcall to the stored extra data hook for the new
  one-argument signature and decodes the per-context array return; a malformed or absent return still contributes
  nothing rather than reverting the snapshot.

## 0.0.56 — Raise dependency floors; document conventions in STYLE_GUIDE

- Raise dependency floors to the latest published versions: `@bananapus/core-v6` `^0.0.78`,
  `@bananapus/permission-ids-v6` `^0.0.28`, `@bananapus/ownable-v6` `^0.0.34`, `@bananapus/721-hook-v6` `^0.0.65`,
  `@bananapus/suckers-v6` `^0.0.67`, `@bananapus/buyback-hook-v6` `^0.0.66`,
  `@bananapus/address-registry-v6` `^0.0.32`. The build is clean and all 185 non-fork tests pass; no `src/` change.
- Document the existing NatSpec, comment, and lint conventions in `STYLE_GUIDE.md`: expand the NatSpec section to
  spell out required tags per member, add a Comments section describing inline-comment intent and timeless phrasing,
  and clarify the linting expectations.

## 0.0.54 — Bump buyback-hook-v6 to ^0.0.64

- `@bananapus/buyback-hook-v6` (devDependency): `^0.0.58 → ^0.0.64`. Spans the cash-out `skip` encoding
  (`(uint256, bool)`, 0.0.62), the metadata purpose rename `"quote"`/`"cashOutMinReclaimed"` → `"pay"`/`"cashOut"`
  (0.0.63), and the gas-only constructor-immutable-ID refactor (0.0.64).
- The buyback hook is only used by fork tests here (`JBOmnichainDeployer` delegates to a generic extra data hook and
  never builds buyback-targeted metadata), so this is a test-dependency refresh with no `src/` change. The buyback
  constructor signature is unchanged across this span, so the existing `setChainSpecificConstants` wiring in
  `OmnichainForkTestBase` still applies. 185 non-fork tests pass; build is clean.

## 0.0.43 — Bump v6 deps to nana-core-v6 0.0.53 cohort

- `@bananapus/core-v6`: `^0.0.48 → ^0.0.53` ([PR #145](https://github.com/Bananapus/nana-core-v6/pull/145) — drops `via_ir` requirement on `JBCashOutHookSpecsLib`; new `pauseCrossProjectFeeFreeInflows` ruleset metadata flag for cross-project cashout opt-out).
- `@bananapus/721-hook-v6`: `^0.0.47 → ^0.0.50`.
- `@bananapus/suckers-v6`: `^0.0.37 → ^0.0.46`.
- `@bananapus/buyback-hook-v6`: `^0.0.39 → ^0.0.46`.
- `@bananapus/permission-ids-v6`: `^0.0.23 → ^0.0.25` (new `SET_SUCKER_PEER` permission referenced by suckers 0.0.46).
- `JBBuybackHook` constructor signature changed in 0.0.45 (V4 PoolManager + Hooks moved to a one-shot setter). Updated `OmnichainForkTestBase` to construct then call `setChainSpecificConstants`.
- All `JBRulesetMetadata` test literals patched to include `pauseCrossProjectFeeFreeInflows: false`. `JBBeforeCashOutRecordedContext` literals are unchanged (no new fields).

## v6 carry-forward hook fix

- **Carry-forward hook selection improved.** `queueRulesetsOf` now checks `latestQueuedOf(projectId)` before falling back to `currentOf(projectId)` when carrying forward a 721 hook. Previously it only read `currentOf`, which could miss a recently queued (and approved) ruleset's hook config. The source ruleset must have approval status `Approved` or `Empty` and a stored hook config in the deployer.
- The `useDataHookForCashOut` flag is preserved from whichever source ruleset is selected during carry-forward.

## Scope

This file describes the verified change from `nana-omnichain-deployers-v5` to the current `nana-omnichain-deployers-v6` repo.

## Current v6 surface

- `JBOmnichainDeployer`
- `IJBOmnichainDeployer`
- `JBDeployerHookConfig`
- `JBOmnichain721Config`
- `JBTiered721HookConfig`

## Summary

- The deployer now assumes a 721 hook is part of the standard deployment path instead of a special-case path.
- Hook composition is more explicit. The current repo separates 721-hook behavior from extra data-hook behavior and combines them deliberately.
- The v6 test suite includes dedicated coverage for ownership transfer, controller validation, empty ruleset edge cases, hook composition, and invariants that were not present in the small v5 tree.
- The repo moved to the v6 Solidity and dependency baseline.

## Verified deltas

- `launch721ProjectFor(...)`, `launch721RulesetsFor(...)`, and `queue721RulesetsOf(...)` no longer define the public API shape.
- Their role is covered by overloaded `launchProjectFor(...)`, `launchRulesetsFor(...)`, and `queueRulesetsOf(...)` entry points that accept `JBOmnichain721Config`.
- `extraDataHookOf(...)` and `tiered721HookOf(...)` replace the older single `dataHookOf(...)` view model.
- The overloaded launch and queue functions now return the `IJB721TiersHook` they deploy or carry forward.

## Breaking ABI changes

- The 721-specific launch and queue entry points were removed from the public API shape.
- `dataHookOf(...)` was replaced by `extraDataHookOf(...)` plus `tiered721HookOf(...)`.
- `launchProjectFor(...)`, `launchRulesetsFor(...)`, and `queueRulesetsOf(...)` now have overloads that return the hook.
- `JBOmnichain721Config` replaces the old direct 721 deploy config entrypoint model.

## Indexer impact

- Hook composition is now split across two tracked hook sources instead of one.
- Launch and queue flows should expect a 721 hook in the returned state and in the deployer's stored per-ruleset data.

## Migration notes

- Update any code that expected separate "with 721" and "without 721" deployment paths to behave like v5.
- Re-check ownership assumptions after hook deployment. The current repo is stricter and more explicit about that flow.
- If you decode launch or queue inputs, use the current v6 structs instead of v5 layouts.

## ABI appendix

- Removed public API shape
  - `launch721ProjectFor(...)`
  - `launch721RulesetsFor(...)`
  - `queue721RulesetsOf(...)`
- Replaced with overload families
  - `launchProjectFor(...)`
  - `launchRulesetsFor(...)`
  - `queueRulesetsOf(...)`
- Replaced hook lookup model
  - `dataHookOf(...)` -> `extraDataHookOf(...)` + `tiered721HookOf(...)`
- New migration-sensitive structs
  - `JBOmnichain721Config`
  - `JBTiered721HookConfig`
