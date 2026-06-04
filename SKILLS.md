# Juicebox Omnichain Deployers

## Use this file for

- Use this file when the task involves omnichain project launch, sucker deployment, or wrapped 721-hook composition.
- Start here, then decide whether the issue is in launch orchestration, hook composition, or bridge-specific runtime behavior.

## Read this next

| If you need... | Open this next |
|---|---|
| Repo overview and architecture | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Runtime guarantees + per-function inventory | [`INVARIANTS.md`](./INVARIANTS.md) |
| Main deployer | [`src/JBOmnichainDeployer.sol`](./src/JBOmnichainDeployer.sol) |
| Bridge runtime | [`../nana-suckers-v6/src/JBSucker.sol`](../nana-suckers-v6/src/JBSucker.sol) |
| 721 hook runtime | [`../nana-721-hook-v6/src/JB721TiersHook.sol`](../nana-721-hook-v6/src/JB721TiersHook.sol) |

## Purpose

Orchestration and wrapper layer for launching projects with suckers and a 721 hook already wired in.

## Working rules

- Start in [`src/JBOmnichainDeployer.sol`](./src/JBOmnichainDeployer.sol).
- Treat ruleset ID prediction as a real implementation dependency.
- Keep wrapper behavior and the underlying 721 or sucker behavior separate in your reasoning.
