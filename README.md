# Juicebox Omnichain Deployers

`@bananapus/omnichain-deployers-v6` launches Juicebox projects with cross-chain suckers and a 721 hook already wired in. It is the package you use when the default project shape should be omnichain from day one.

## Documentation

- [INVARIANTS.md](./INVARIANTS.md) — runtime guarantees enforced by `JBOmnichainDeployer`, per-function caller / effect / invariant inventory, and cross-cutting invariants.
- [ARCHITECTURE.md](./ARCHITECTURE.md) — system overview, trust boundaries, and source map.
- [ADMINISTRATION.md](./ADMINISTRATION.md) — control posture, recovery posture, and admin boundaries.
- [RISKS.md](./RISKS.md) — risk register with priority levels, trust assumptions, and accepted behaviors.
- [USER_JOURNEYS.md](./USER_JOURNEYS.md) — primary actor flows for launching omnichain projects and adding suckers later.
- [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md) — audit objective, scope, and verification commands.
- [SKILLS.md](./SKILLS.md) — orientation for AI agents and contributors working on this repo.
- [STYLE_GUIDE.md](./STYLE_GUIDE.md) — Solidity and repo conventions across the Juicebox V6 ecosystem.
- [CHANGELOG.md](./CHANGELOG.md) — version-to-version changes and migration notes.

## Overview

The deployer wraps multiple launch concerns into one surface:

- deploy or carry forward a tiered 721 hook
- install itself as the project's data-hook wrapper
- compose the 721 hook with an optional extra custom hook
- wrap sucker flows so project-specific cash-out taxation and mint-permission logic can be handled safely
- deploy suckers deterministically across chains

The wrapper exists so sucker-triggered flows can be exempted from project-specific cash-out taxation and related mint-gating logic where needed while the project still keeps its own inner data hooks.

Use this repo when the default project shape is "Juicebox project plus 721 hook plus cross-chain bridge." Do not use it when a project is single-chain or does not need the wrapper semantics around suckers.

## Key contract

| Contract | Role |
| --- | --- |
| `JBOmnichainDeployer` | Launches projects and rulesets, manages per-ruleset hook composition, and deploys suckers with deterministic salts. |

## Mental model

This repo owns orchestration plus runtime wrapping:

1. launch a project with a known omnichain-capable shape
2. remember which hook composition belongs to which ruleset
3. special-case sucker behavior so bridge flows are not broken by project-specific logic

## Read these files first

1. `src/JBOmnichainDeployer.sol`
2. `nana-suckers-v6/src/JBSucker.sol`
3. `nana-721-hook-v6/src/JB721TiersHook.sol`
4. the extra hook repo, if the deployment composes one

## Integration traps

- this repo wraps hooks and bridge flows together, so ownership and hook-order assumptions matter as much as deployment salt
- ruleset ID prediction is a real implementation dependency
- the deployer can carry forward an existing 721 hook shape, so stale hook assumptions can leak across deployments
- bridge-safe wrapper behavior is part of the runtime trust model

## Where state lives

- orchestration and wrapper logic: `JBOmnichainDeployer`
- bridge runtime state: `nana-suckers-v6`
- 721 tier state: `nana-721-hook-v6`
- extra hook behavior: the additional repo composed into the deployment

## Install

```bash
npm install @bananapus/omnichain-deployers-v6
```

## Development

```bash
npm install
forge build --deny notes
forge test --deny notes --fail-fast --summary --detailed --skip "*/script/**"
```

Useful scripts:

- `npm run deploy:mainnets`
- `npm run deploy:testnets`

## Deployment notes

This repo assumes the 721 hook, address registry, buyback hook, suckers, ownable, and core packages are already available. Matching salts from the same sender keep sucker addresses deterministic across chains.

## Repository layout

```text
src/
  JBOmnichainDeployer.sol
  interfaces/
  structs/
test/
  unit, attack, invariant, fork, review, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks and notes

- ruleset ID prediction is part of the implementation strategy
- hook composition order matters because the 721 hook runs before any extra custom hook
- default empty-tier 721 config is convenient, but teams should still decide explicitly whether the hook participates in cash-out behavior
- deterministic salts only help with cross-chain address alignment when sender and configuration match exactly

## For AI agents

- Describe this repo as an orchestration and wrapper layer, not as the source of sucker or 721 runtime behavior.
- Start with `JBOmnichainDeployer`, then inspect the sibling repo that owns the behavior being questioned.
