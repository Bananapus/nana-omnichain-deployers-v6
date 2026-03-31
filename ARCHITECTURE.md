# Architecture

## Purpose

`nana-omnichain-deployers-v6` launches Juicebox projects that are ready for both tiered NFTs and cross-chain suckers from day one. It also acts as a wrapper data hook so it can compose a 721 hook with an optional extra data hook while granting suckers tax-free cash outs and mint permission.

## Boundaries

- `JBOmnichainDeployer` is both a deployer and a live hook wrapper. Those two roles are inseparable.
- The repo composes `nana-721-hook-v6` and `nana-suckers-v6`; it should not duplicate their internal logic.
- Project accounting still happens in the core protocol.

## Main Components

| Component | Responsibility |
| --- | --- |
| `JBOmnichainDeployer` | Project launch, ruleset queueing, hook composition, and sucker-safe cash-out policy |
| config structs | 721 hook config, extra hook config, and sucker deployment config |
| `IJBOmnichainDeployer` | Public deployer and inspection interface |

## Runtime Model

### Launch

```text
caller
  -> launch project or queue rulesets through the deployer
  -> deployer installs itself as the ruleset data hook
  -> deployer deploys or carries forward the 721 hook
  -> deployer optionally deploys sucker pairs with deterministic salts
  -> project ownership is transferred to the intended owner
```

### Pay And Cash-Out Wrapping

```text
runtime callback
  -> if the actor is a registered sucker, return the special tax-free / mint-enabled path
  -> otherwise call the 721 hook first when configured
  -> then call the extra data hook when configured
  -> merge hook specs in order and return the combined result
```

## Critical Invariants

- Suckers must be able to bridge without getting trapped behind custom cash-out policies.
- Hook order matters: the 721 hook runs first, and the extra hook receives the updated context.
- The deployer's predicted ruleset IDs must stay aligned with `JBRulesets` behavior; the storage keys depend on it.
- Every project launched through this repo gets a 721 hook surface, even if it starts with zero tiers.

## Where Complexity Lives

- This repo hides composition complexity behind a simple launch surface, which makes stale assumptions dangerous.
- Ruleset ID prediction is a subtle but central storage keying mechanism.
- The sucker exception path intentionally short-circuits normal hook composition and must stay easy to reason about.

## Dependencies

- `nana-core-v6` for project launch and hook interfaces
- `nana-721-hook-v6` for tiered NFT behavior
- `nana-suckers-v6` for cross-chain transport
- `nana-ownable-v6` for project-following hook ownership

## Safe Change Guide

- Review launch-time logic and runtime-hook logic together. This repo is easy to break by fixing only one side.
- When changing hook composition, verify both payment and cash-out ordering.
- If you touch ruleset ID prediction, test same-block and queued-ruleset edge cases explicitly.
- Keep deterministic salt handling stable across chains; address predictability is part of the feature.
- Treat "transparent wrapper" claims as something to prove continuously, not assume.
