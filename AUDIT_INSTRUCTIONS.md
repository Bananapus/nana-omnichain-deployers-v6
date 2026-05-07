# Audit Instructions

Audit this repo as an orchestration layer that composes 721 hooks, suckers, and optional extra data hooks.

## Audit Objective

Find issues that:

- launch the wrong project shape
- miscompose hooks or wrapper behavior
- grant privileged sucker behavior to the wrong addresses
- create cross-chain drift or bad deterministic assumptions

## Scope

In scope:

- `src/JBOmnichainDeployer.sol`
- related tests under `test/`

## Start Here

1. `src/JBOmnichainDeployer.sol`

## Verification

- `npm install`
- `forge build --deny notes`
- `forge test --deny notes --fail-fast --summary --detailed --skip "*/script/**"`
