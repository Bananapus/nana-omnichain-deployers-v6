# Omnichain Deployer Operations

## Deployment surface

- [`src/JBOmnichainDeployer.sol`](../src/JBOmnichainDeployer.sol) is the first stop for launch, queue, and sucker-deployment behavior.
- [`script/Deploy.s.sol`](../script/Deploy.s.sol) is the deployment entry point when the question is about current wiring rather than wrapper semantics.
- [`src/structs/`](../src/structs/) defines the deploy and queue config types that often drift from memory.

## Change checklist

- If you edit launch or queue behavior, verify ruleset IDs, carry-forward behavior, and stored hook config keys together.
- If you edit salt handling, confirm deterministic-address assumptions for both suckers and 721 hooks.
- If you edit wrapper behavior, check both pay and cash-out paths, not only one.
- If you touch mint-permission logic, confirm whether the permission should come from suckers, the extra hook, or neither.

## Common failure modes

- Wrapper behavior is blamed on the composed hook, but the deployer stored the wrong hook config for the ruleset.
- A same-block queue assumption breaks predicted ruleset IDs and silently strands stored config.
- A project expects custom-hook behavior on cash-out, but the wrapper flags disable it or the sucker exemption bypasses it.
- Deterministic deployment assumptions fail because sender or salt composition changed.
- Existing-project sucker deployment is treated as a pure `DEPLOY_SUCKERS` flow even though the registry also performs token mapping, so missing `MAP_SUCKER_TOKEN` authority for the registry shows up only when the deploy path reaches `mapTokens`.

## Useful proof points

- [`test/JBOmnichainDeployer.t.sol`](../test/JBOmnichainDeployer.t.sol) for baseline deploy and queue flows.
- [`test/TestRegressionGaps.sol`](../test/TestRegressionGaps.sol) for pinned edge cases.
- [`test/Tiered721HookComposition.t.sol`](../test/Tiered721HookComposition.t.sol) when cross-repo integration behavior matters more than isolated unit logic.
