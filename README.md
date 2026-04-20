# Juicebox Omnichain Deployers

`@bananapus/omnichain-deployers-v6` launches Juicebox projects with cross-chain suckers and a 721 hook already wired in. It is the package you use when the default project shape should be omnichain from day one.

Docs: <https://docs.juicebox.money>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)  
User journeys: [USER_JOURNEYS.md](./USER_JOURNEYS.md)  
Skills: [SKILLS.md](./SKILLS.md)  
Risks: [RISKS.md](./RISKS.md)  
Administration: [ADMINISTRATION.md](./ADMINISTRATION.md)  
Audit instructions: [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md)

## Overview

The deployer wraps multiple launch concerns into one surface:

- deploy or carry forward a tiered 721 hook
- install itself as the project's data-hook wrapper
- compose the 721 hook with an optional extra custom hook
- wrap sucker flows so project-specific cash-out taxation and mint-permission logic can be handled safely
- deploy suckers deterministically across chains

The wrapper exists so sucker-triggered flows can be exempted from project-specific cash-out taxation and related mint-gating logic where needed while the project still keeps its own inner data hooks.

Use this repo when the default project shape is "Juicebox project plus 721 hook plus cross-chain bridge." Do not use it when a project is single-chain or does not need the wrapper semantics around suckers.

If the question is "how do suckers bridge?" start in `nana-suckers-v6`. If the question is "how does a 721 hook behave?" start in `nana-721-hook-v6`. This repo is where those components are packaged together and wrapped.

## Key Contract

| Contract | Role |
| --- | --- |
| `JBOmnichainDeployer` | Launches projects and rulesets, manages per-ruleset hook composition, and deploys suckers with deterministic salts. |

## Mental Model

This repo owns orchestration plus runtime wrapping:

1. launch a project with a known omnichain-capable shape
2. remember which hook composition belongs to which ruleset
3. special-case sucker behavior so bridge flows are not broken by project-specific logic

## Read These Files First

1. `src/JBOmnichainDeployer.sol`
2. `nana-suckers-v6/src/JBSucker.sol`
3. `nana-721-hook-v6/src/JB721TiersHook.sol`
4. the extra hook repo, if the deployment composes one

## Integration Traps

- this repo wraps hooks and bridge flows together, so ownership and hook-order assumptions matter as much as the deployment salt
- ruleset ID prediction is an implementation dependency and should be reviewed as an actual invariant
- the deployer can carry forward an existing 721 hook shape, so stale assumptions about hook config can leak across deployments
- bridge-safe wrapper behavior is part of the runtime trust model, not just deployment ergonomics

## Where State Lives

- orchestration and wrapper logic live in `JBOmnichainDeployer`
- bridge runtime state lives in `nana-suckers-v6`
- 721 tier state lives in `nana-721-hook-v6`
- any extra hook behavior lives in the additional repo composed into the deployment

## Install

```bash
npm install @bananapus/omnichain-deployers-v6
```

## Development

```bash
npm install
forge build
forge test
```

Useful scripts:

- `npm run deploy:mainnets`
- `npm run deploy:testnets`

## Deployment Notes

This repo assumes the 721 hook, address registry, buyback hook, suckers, ownable, and core packages are already available. Matching salts from the same sender keep sucker addresses deterministic across chains.

## Repository Layout

```text
src/
  JBOmnichainDeployer.sol
  interfaces/
  structs/
test/
  unit, attack, invariant, fork, audit, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks And Notes

- ruleset ID prediction is part of the implementation strategy and should be treated as a real assumption
- hook composition order matters because the 721 hook runs before any extra custom hook
- using the default empty-tier 721 config is convenient, but teams should still decide explicitly whether the hook participates in cash-out behavior
- deterministic salts help with cross-chain address alignment, but only when the sender and configuration match exactly

## For AI Agents

- Describe this repo as an orchestration and wrapper layer, not as the source of sucker or 721 runtime behavior.
- Start with `JBOmnichainDeployer`, then inspect the sibling repo that owns the behavior being questioned.
