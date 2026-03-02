# nana-omnichain-deployers-v5

Deploy Juicebox projects with cross-chain suckers and optional 721 tiers hooks in a single transaction. Acts as a data hook wrapper to allow tax-free cash outs from suckers.

## Architecture

| Contract | Description |
|----------|-------------|
| `JBOmnichainDeployer` | Deploys projects, rulesets, and suckers. Wraps the project's real data hook to intercept cash outs from suckers (tax-free) and grant suckers mint permission. |

### Supporting Types

| Type | Description |
|------|-------------|
| `JBDeployerHookConfig` | Per-ruleset config storing the real data hook and its pay/cash-out usage flags. |
| `JBSuckerDeploymentConfig` | Array of `JBSuckerDeployerConfig` plus a `bytes32` salt for deterministic cross-chain addresses. |
| `IJBOmnichainDeployer` | Interface for all deployer entry points. |

### How It Works

`JBOmnichainDeployer` temporarily holds the project NFT during deployment, inserts itself as the data hook on all rulesets via `_setup()`, stores the real data hook in `_dataHookOf`, then transfers ownership to the specified owner. As the data hook it:

1. **Pay** -- Forwards `beforePayRecordedWith` to the real data hook (if set).
2. **Cash out** -- If the holder is a registered sucker (`SUCKER_REGISTRY.isSuckerOf`), returns 0% tax rate. Otherwise forwards to the real data hook.
3. **Mint permission** -- Returns `true` for registered suckers, otherwise forwards to the real data hook.

## Install

```bash
npm install
```

## Develop

| Command | Description |
|---------|-------------|
| `forge build` | Compile contracts |
| `forge test` | Run tests |
| `npm run deploy:mainnets` | Propose mainnet deployment via Sphinx |
| `npm run deploy:testnets` | Propose testnet deployment via Sphinx |
