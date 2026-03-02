# nana-omnichain-deployers-v5

Deploy Juicebox projects with cross-chain suckers and optional 721 tiers hooks in a single transaction.

## Architecture

| Contract | Description |
|---|---|
| `src/JBOmnichainDeployer.sol` | Deploys projects, rulesets, and suckers. Also acts as a data hook wrapper for tax-free sucker cash outs. |
| `src/interfaces/IJBOmnichainDeployer.sol` | Interface. |
| `src/structs/JBDeployerHookConfig.sol` | Per-ruleset data hook configuration stored by the deployer. |
| `src/structs/JBSuckerDeploymentConfig.sol` | Sucker deployer configs and a salt for deterministic cross-chain addresses. |

### How It Works

`JBOmnichainDeployer` temporarily holds the project NFT during deployment, sets itself as the data hook on all rulesets, then transfers ownership to the specified owner. As data hook, it:

1. Forwards `beforePayRecordedWith` calls to the project's real data hook.
2. Intercepts `beforeCashOutRecordedWith` -- if the holder is a registered sucker, returns a 0% tax rate. Otherwise, forwards to the real data hook.
3. Forwards `hasMintPermissionFor` -- returns `true` for registered suckers.

## Install

```bash
npm install @bananapus/omnichain-deployers
```

Or with Forge:

```bash
forge install Bananapus/nana-omnichain-deployers
```

## Develop

```bash
npm install && forge install
forge build
forge test
```
