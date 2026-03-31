# Changelog

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
