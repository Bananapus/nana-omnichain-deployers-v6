# Juicebox Omnichain Deployers

`@bananapus/omnichain-deployers-v6` launches Juicebox projects with cross-chain suckers and a 721 hook already wired in. It is the package you use when the default project shape should be omnichain from day one.

Docs: <https://docs.juicebox.money>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)

## Overview

The deployer wraps multiple launch concerns into one surface:

- deploy or carry forward a tiered 721 hook
- install itself as the project's data-hook wrapper
- compose the 721 hook with an optional extra custom hook
- grant tax-free and mint-safe behavior to project suckers
- deploy suckers deterministically across chains

The wrapper exists so suckers can bridge without being blocked by project-specific cash-out tax logic while the project still keeps its own data hooks.

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
