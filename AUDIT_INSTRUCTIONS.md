# Audit Instructions

This repo launches projects that are immediately composed with 721 hooks and sucker deployments. Audit it as a privileged deployer and runtime data-hook participant.

## Audit Objective

Find issues that:
- launch projects with incorrect rulesets, terminals, or hook ownership
- grant cash-out or mint privileges to non-suckers
- mis-scale weight or tax behavior during omnichain-specific data-hook flows
- leave deployed hook or sucker ownership in the wrong hands
- create inconsistent behavior between local-only and omnichain project launches

## Scope

In scope:
- `src/JBOmnichainDeployer.sol`
- `src/interfaces/`
- `src/structs/`
- deployment scripts in `script/`

Key dependencies:
- `nana-core-v6`
- `nana-721-hook-v6`
- `nana-suckers-v6`

## Start Here

1. `src/JBOmnichainDeployer.sol`
2. `script/Deploy.s.sol`
3. `script/helpers/DeployersDeploymentLib.sol`

## Security Model

`JBOmnichainDeployer` is a launch surface that can:
- create a new Juicebox project
- deploy and configure a 721 hook
- configure rulesets and terminals
- deploy suckers and register them for the project
- participate in pay or cash-out accounting as a data hook where needed

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Launch caller | Supply desired project configuration | Should receive exactly the requested state |
| Omnichain deployer | Create hooks, projects, and sucker composition | Must relinquish setup authority after launch |
| Sucker registry | Grant omnichain-specific privileges | Must not bless arbitrary contracts |

## Integration Assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| `nana-core-v6` | Launch and ruleset surfaces are authentic | Deployed economics drift from requested config |
| `nana-721-hook-v6` | Hook ownership and tier setup complete correctly | Collection state or authority is wrong |
| `nana-suckers-v6` | Registry identifies genuine peers | Fee or mint exemptions widen incorrectly |

## Critical Invariants

1. Launch configuration is faithful
The deployed project must end up with the exact hook, ruleset, and ownership configuration the caller requested.

2. Sucker privileges stay restricted
Zero-tax or mint-permission behavior intended for legitimate suckers must not be reachable by arbitrary contracts or stale registry entries.

3. Weight and accounting scaling are correct
If the deployer proxies or modifies hook outputs, the resulting project token issuance and reclaim math must still match intended economics.

4. Ownership transfer is complete
Deployer-created hooks and helper contracts must not retain silent control after initialization.

## Attack Surfaces

- malformed launch configuration
- hook and sucker ownership transfer
- registry-based privilege spoofing
- reentrancy around launch and initialization
- local-only launches versus omnichain launches with optional components disabled

## Verification

- `npm install`
- `forge build`
- `forge test`
