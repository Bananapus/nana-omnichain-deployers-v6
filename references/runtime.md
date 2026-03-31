# Omnichain Deployer Runtime

## Contract Role

- [`src/JBOmnichainDeployer.sol`](../src/JBOmnichainDeployer.sol) launches projects, deploys suckers, installs a 721 hook, wraps extra hooks, and serves as the live ruleset data-hook wrapper for the projects it creates.

## Runtime Path

1. Project launch or ruleset queue stores the relevant 721 hook and optional extra hook per ruleset.
2. The deployer installs itself as the data-hook wrapper on the ruleset.
3. On pay, it calls the 721 hook first, then the optional extra hook with the adjusted amount context.
4. On cash out, it can short-circuit for suckers, otherwise it forwards into the configured hook stack in order.
5. Mint permission queries can be granted by suckers or by the configured extra hook.

## High-Risk Areas

- Ruleset ID prediction: if the predicted ID is wrong, hook config can be stored under the wrong key.
- Hook composition order: 721 logic runs before any extra hook, which affects both specs and accounting.
- Sucker exemptions: early-return cash-out behavior is intentional and should not be removed casually.
- Carry-forward logic: queueing rulesets without new tiers intentionally reuses the latest 721 hook.
- Meta-transaction sender handling: salt derivation uses `_msgSender()`, not raw `msg.sender`.

## Tests To Trust First

- [`test/Tiered721HookComposition.t.sol`](../test/Tiered721HookComposition.t.sol) for hook-composition behavior.
- [`test/JBOmnichainDeployerGuard.t.sol`](../test/JBOmnichainDeployerGuard.t.sol) and [`test/OmnichainDeployerAttacks.t.sol`](../test/OmnichainDeployerAttacks.t.sol) for safety properties.
- [`test/OmnichainDeployerReentrancy.t.sol`](../test/OmnichainDeployerReentrancy.t.sol) for wrapper security assumptions.
- [`test/OmnichainDeployerEdgeCases.t.sol`](../test/OmnichainDeployerEdgeCases.t.sol), [`test/invariants/`](../test/invariants/), and [`test/regression/`](../test/regression/) for edge behavior.
