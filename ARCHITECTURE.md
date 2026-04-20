# Architecture

## Purpose

`nana-omnichain-deployers-v6` launches Juicebox projects that are ready for both tiered NFTs and cross-chain suckers from day one. It is also a live wrapper data hook that composes a 721 hook with an optional extra hook while giving registered suckers the bridge-safe path they need.

## System Overview

`JBOmnichainDeployer` is both deployer and runtime wrapper; those roles are inseparable. At launch time it can deploy a project, install itself as the ruleset data hook, deploy or carry forward the 721 hook, and optionally deploy sucker pairs with deterministic salts. At runtime it composes hook specs and grants special behavior to registered suckers so bridging does not get trapped behind project-specific cash-out policy.

## Core Invariants

- Registered suckers must be able to bridge without getting blocked by custom cash-out or mint policy.
- Hook order is intentional: the 721 hook runs first, then the optional extra hook.
- Ruleset ID prediction must stay aligned with `JBRulesets`; stored hook config keys depend on it.
- Every project launched through this repo gets a 721-hook surface, even if it starts with zero tiers.
- This wrapper always becomes the on-chain ruleset data hook and forces both pay and cash-out callbacks through itself before delegating internally.
- Extra pay hooks must see only the post-721 project amount and the 721-adjusted weight, not the raw terminal payment context.
- Queue-path carry-forward must prefer the latest approved queued ruleset over the current active ruleset when recovering hook config.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBOmnichainDeployer` | Launch, queue rulesets, compose hooks, and grant sucker-safe behavior | Deployer and runtime wrapper |
| config structs | 721 config, extra hook config, and sucker deployment config | Launch-time inputs |
| `IJBOmnichainDeployer` | External launch and inspection interface | Public surface |

## Trust Boundaries

- Accounting and project ownership transfer remain rooted in `nana-core-v6`.
- Tier behavior comes from `nana-721-hook-v6`.
- Cross-chain transport comes from `nana-suckers-v6`.
- Project-following ownership behavior comes from `nana-ownable-v6`.

## Critical Flows

### Launch

```text
caller
  -> launches a project or queues rulesets through the deployer
  -> deployer installs itself as the ruleset data hook
  -> deploys or carries forward the 721 hook
  -> optionally deploys sucker pairs with deterministic salts
  -> transfers project ownership to the intended owner
```

### Queue With Carry-Forward

```text
caller
  -> queues a new ruleset without new tiers
  -> deployer selects carry-forward hook config from the latest approved queued ruleset when present
  -> otherwise falls back to the current active ruleset
  -> preserves useDataHookForCashOut from the chosen source ruleset
```

### Runtime Wrapping

```text
runtime callback
  -> if the actor is a registered sucker, return the bridge-safe tax-free and mint-enabled path
  -> otherwise run the 721 hook first when configured
  -> pass the extra pay hook only the post-split project amount and 721-adjusted weight
  -> then run the optional extra hook
  -> merge and return the resulting specs
```

## Accounting Model

This repo does not own the treasury ledger. Its critical state is hook configuration and ruleset-keyed carry-forward data that determine how downstream accounting hooks are composed.

The wrapper also computes cross-chain cash-out context for non-sucker paths by augmenting local supply and surplus with remote sucker snapshots. Inner hooks may adjust tax rate or counts, but this repo keeps the omnichain supply/surplus view authoritative.

## Security Model

- The largest risk is silent drift between deploy-time assumptions and runtime wrapper behavior.
- Ruleset ID prediction is storage-key critical.
- The sucker exception path intentionally short-circuits normal composition and should stay easy to reason about.
- Suckers have two privileged behaviors by design: tax-free bridge cash-outs and unconditional mint permission. Those exceptions must remain tightly scoped to registry-recognized sucker addresses.
- Salt derivation includes `_msgSender()` for replay protection. Cross-chain deterministic matching therefore depends on using the same sender on each chain.
- Because this repo is both deployer and runtime hook, permission or hook-order changes can break already-launched projects, not just future launches.

## Safe Change Guide

- Review launch logic and runtime wrapper logic together.
- If hook composition changes, test payment and cash-out ordering explicitly.
- If ruleset prediction changes, test same-block and queued-ruleset edge cases.
- If sucker exceptions or mint-permission behavior change, re-check bridge flows against normal custom-hook policy.
- If salt derivation changes, re-check deterministic cross-chain deployment expectations and replay resistance together.
- If wrapper metadata behavior changes, re-check the forced `useDataHookForPay/useDataHookForCashOut` install path and the extra-hook context shaping together.
- Keep salt handling stable across chains when deterministic address expectations matter.

## Canonical Checks

- hook ordering and composition correctness:
  `test/Tiered721HookComposition.t.sol`
- carry-forward and queued-ruleset recovery behavior:
  `test/audit/CarryForwardRejectedHook.t.sol`
- wrapper invariants under adversarial sequences:
  `test/invariants/OmnichainDeployerInvariant.t.sol`

## Source Map

- `src/JBOmnichainDeployer.sol`
- `src/structs/`
- `test/Tiered721HookComposition.t.sol`
- `test/audit/CarryForwardRejectedHook.t.sol`
- `test/invariants/OmnichainDeployerInvariant.t.sol`
