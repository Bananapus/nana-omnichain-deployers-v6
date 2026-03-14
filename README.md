# Juicebox Omnichain Deployers

Deploy Juicebox projects with cross-chain suckers and 721 tiers hooks in a single transaction. Every project gets a 721 hook (even with 0 initial tiers), so projects can add NFT tiers later without reconfiguring. Acts as a transparent data hook wrapper that gives suckers tax-free cash outs and on-demand mint permission -- without interfering with any custom data hook the project uses. Supports composing a 721 tiers hook alongside a custom data hook (e.g., a buyback hook) so both run on every payment.

[Docs](https://docs.juicebox.money) | [Discord](https://discord.gg/juicebox)

## Conceptual Overview

Launching a cross-chain Juicebox project normally takes several steps: deploy the project, configure rulesets, set up terminals, deploy suckers, and wire up a data hook that exempts suckers from cash out taxes. `JBOmnichainDeployer` collapses all of this into one transaction.

It works by inserting itself as the data hook on every ruleset it touches, storing hooks in two separate mappings: the 721 tiers hook is stored per-ruleset in `_tiered721HookOf[projectId][rulesetId]` with its own `useDataHookForCashOut` flag, and an optional custom data hook (e.g., buyback hook) is stored per-ruleset in `_extraDataHookOf[projectId][rulesetId]` with `useDataHookForPay` and `useDataHookForCashOut` flags. When the protocol calls data hook functions during payments and cash outs, the deployer:

- **Checks if the holder is a sucker** -- if so, returns 0% cash out tax and grants mint permission. This early return means suckers can always bridge tokens without interference, even if the project's hooks would revert.
- **Composes the 721 hook and custom data hook** for payments -- the 721 hook is called first (via `tiered721HookOf`) to get its specs (including split fund amounts), then the custom hook from `_extraDataHookOf` (if `useDataHookForPay: true`) is called with a reduced amount context (payment minus split amount) so it only considers the available funds. The deployer adjusts the returned weight proportionally for splits, ensuring the terminal only mints tokens for the amount that actually enters the project treasury. If the 721 hook returns no specs (0 tiers), it is skipped in the merged output.
- **Checks hooks for cash outs** -- the 721 hook is checked first (if `useDataHookForCashOut: true`), then the custom hook. The first with the flag set handles the cash out. If the 721 hook has `useDataHookForCashOut: true` and reverts (e.g., for fungible-only cashouts), that revert propagates. Set `useDataHookForCashOut: false` on the 721 config to skip it and let the custom hook handle cashouts instead.
- **Returns default values** if neither hook has the relevant flag set.

This wrapping is invisible to the project and its users. The project's hooks (buyback hook, 721 hook, etc.) work exactly as configured, and can be composed together.

### How It Works

```mermaid
sequenceDiagram
    participant Caller
    participant Deployer as JBOmnichainDeployer
    participant HookDeployer as IJB721TiersHookDeployer
    participant Controller as JBController
    participant Registry as JBSuckerRegistry
    participant Owner

    Caller->>Deployer: launchProjectFor(owner, rulesets, suckers, ...)
    Deployer->>HookDeployer: deployHookFor(projectId, ...) — deploy 721 hook
    Deployer->>Deployer: _setup721() — store hooks, insert self as data hook
    Deployer->>Controller: launchProjectFor(owner=deployer, ...)
    Controller-->>Deployer: projectId + project NFT
    Deployer->>Deployer: transferOwnershipToProject(projectId) — 721 hook ownership
    Deployer->>Registry: deploySuckersFor(projectId, salt)
    Registry-->>Deployer: sucker addresses
    Deployer->>Owner: transfer project NFT
```

During operation:

```mermaid
sequenceDiagram
    participant Terminal
    participant Deployer as JBOmnichainDeployer
    participant Registry as JBSuckerRegistry
    participant Hook as 721 / Custom Hook

    Terminal->>Deployer: beforeCashOutRecordedWith(context)
    Deployer->>Registry: isSuckerOf(projectId, holder)?
    alt Holder is a sucker
        Deployer-->>Terminal: 0% tax (early return)
    else 721 or custom hook with useDataHookForCashOut=true
        Deployer->>Hook: beforeCashOutRecordedWith(context)
        Hook-->>Deployer: taxRate, count, supply, specs
        Deployer-->>Terminal: forward hook response
    else Neither hook has useDataHookForCashOut=true
        Deployer-->>Terminal: original values (default)
    end
```

### 721 Tiers Hook Integration

Every project deployed through `JBOmnichainDeployer` gets a 721 tiers hook, even with 0 initial tiers. This lets projects add NFT tiers later without needing to reconfigure the data hook. The deployer:

1. Deploys the 721 hook via `HOOK_DEPLOYER`
2. Transfers hook ownership to the project via `JBOwnable.transferOwnershipToProject(projectId)` (after the project NFT exists)
3. Stores the 721 hook per-ruleset in `_tiered721HookOf[projectId][rulesetId]` with its `useDataHookForCashOut` flag
4. Sets itself as the data hook on each ruleset, enforcing `useDataHookForPay = true` and `useDataHookForCashOut = true`
5. Stores the optional custom hook (e.g., buyback hook) separately in `_extraDataHookOf[projectId][rulesetId]` with its own per-hook flags

For `queueRulesetsOf`, if no new tiers are provided, the 721 hook from the latest ruleset is carried forward instead of deploying a new one.

This means a project can have both a 721 hook (for NFT minting on payments) and a custom data hook (for buyback, custom weight logic, etc.) running simultaneously. During payments, both hooks' specifications are merged. During cash outs, the 721 hook is checked first (if `useDataHookForCashOut: true`), then the custom hook.

### Simplified Overloads

Each of `launchProjectFor`, `launchRulesetsFor`, and `queueRulesetsOf` has a simplified overload that omits the `deploy721Config` parameter. These use `_default721Config(rulesetConfigurations)`, which creates an empty-tier 721 config with `currency` from the first ruleset's `baseCurrency`, `decimals = 18`, `useDataHookForCashOut = false`, and no salt. For `queueRulesetsOf`, since the default config has 0 tiers, the existing 721 hook is always carried forward.

### Deterministic Cross-Chain Addresses

Sucker deployment salts are hashed with `_msgSender()` before use:

```
salt = keccak256(abi.encode(userSalt, _msgSender()))
```

This means:
- **Same sender + same salt on each chain = same sucker addresses** (deterministic via CREATE2)
- Different senders can't collide, even with the same salt
- `salt = bytes32(0)` skips sucker deployment entirely

### Ruleset ID Prediction

The deployer stores hook configs keyed by predicted ruleset IDs (`block.timestamp + i`). This works because `JBRulesets` assigns IDs as `latestId >= block.timestamp ? latestId + 1 : block.timestamp`. For new projects, `latestId` starts at 0, so the first ID is always `block.timestamp`.

The `queueRulesetsOf` function guards against prediction failures by reverting if `latestRulesetIdOf(projectId) >= block.timestamp` (i.e., rulesets were already queued in the same block).

## Architecture

| Contract | Description |
|----------|-------------|
| `JBOmnichainDeployer` | Deploys projects, rulesets, and suckers. Wraps the project's real data hook to intercept cash outs from suckers (tax-free) and grant suckers mint permission. Implements `IJBRulesetDataHook`, `IERC721Receiver`, `ERC2771Context`, `JBPermissioned`. |

### Supporting Types

| Type | Description |
|------|-------------|
| `JBOmnichain721Config` | 721 hook deployment config: `deployTiersHookConfig` (tier configuration), `useDataHookForCashOut` flag, and `salt` for deterministic deployment. Passed to all deploy/launch/queue functions. |
| `JBDeployerHookConfig` | Per-hook config with `dataHook`, `useDataHookForPay`, and `useDataHookForCashOut` flags. Stored as a single value per `(projectId, rulesetId)` in `_extraDataHookOf` for the custom data hook. |
| `JBTiered721HookConfig` | Per-ruleset 721 hook config with `hook` (the `IJB721TiersHook`) and `useDataHookForCashOut` flag. Stored per `(projectId, rulesetId)` in `_tiered721HookOf`. |
| `JBSuckerDeploymentConfig` | Wraps an array of `JBSuckerDeployerConfig` with a `bytes32` salt for deterministic cross-chain addresses. |
| `IJBOmnichainDeployer` | Interface for all deployer entry points and the `extraDataHookOf` view. |

## Install

```bash
npm install @bananapus/omnichain-deployers-v6
```

If using Forge directly:

```bash
forge install Bananapus/nana-omnichain-deployers-v6
```

Add to `remappings.txt`:
```
@bananapus/omnichain-deployers-v6/=lib/nana-omnichain-deployers-v6/
```

## Develop

| Command | Description |
|---------|-------------|
| `forge build` | Compile contracts |
| `forge test` | Run unit, integration, and attack tests |
| `forge test -vvv` | Run tests with full stack traces |
| `npm run deploy:mainnets` | Propose mainnet deployment via Sphinx |
| `npm run deploy:testnets` | Propose testnet deployment via Sphinx |

### Settings

```toml
# foundry.toml
[profile.default]
solc = '0.8.26'
evm_version = 'cancun'
optimizer_runs = 100000

[fuzz]
runs = 4096
```

## Repository Layout

```
src/
  JBOmnichainDeployer.sol               # Main contract (~817 lines)
  interfaces/
    IJBOmnichainDeployer.sol            # Public interface
  structs/
    JBDeployerHookConfig.sol            # Custom hook config (dataHook + flags)
    JBOmnichain721Config.sol            # 721 hook deployment config
    JBTiered721HookConfig.sol           # Per-ruleset 721 hook config
    JBSuckerDeploymentConfig.sol        # Sucker deployment params
test/
  JBOmnichainDeployer.t.sol             # Unit tests
  JBOmnichainDeployerGuard.t.sol        # Ruleset ID prediction tests
  OmnichainDeployerAttacks.t.sol        # Adversarial security tests
  OmnichainDeployerEdgeCases.t.sol      # Edge case tests (weight, cashout, mint)
  OmnichainDeployerReentrancy.t.sol     # Reentrancy tests
  Tiered721HookComposition.t.sol        # 721 hook + custom hook composition tests
  fork/                                 # Fork tests against mainnet
  regression/
    HookOwnershipTransfer.t.sol         # Hook ownership transfer regression
script/
  Deploy.s.sol                          # Sphinx deployment script
  helpers/
    DeployersDeploymentLib.sol          # Deployment address helper
```

## Permissions

| Permission | ID | Required For |
|------------|-----|-------------|
| `DEPLOY_SUCKERS` | `JBPermissionIds.DEPLOY_SUCKERS` | `deploySuckersFor` |
| `QUEUE_RULESETS` | `JBPermissionIds.QUEUE_RULESETS` | `launchRulesetsFor`, `queueRulesetsOf` |
| `SET_TERMINALS` | `JBPermissionIds.SET_TERMINALS` | `launchRulesetsFor` |
| `MAP_SUCKER_TOKEN` | `JBPermissionIds.MAP_SUCKER_TOKEN` | Granted to `SUCKER_REGISTRY` globally (projectId=0) at construction |

Note: `launchProjectFor` requires no permissions -- anyone can launch a project to any owner.

## Risks

- **Ruleset ID mismatch**: If `_setup721()` predictions are wrong (e.g., due to same-block queuing from another source), the stored hook configs will be keyed to the wrong rulesets. The `queueRulesetsOf` guard prevents this, but `launchProjectFor` relies on `PROJECTS.count()` being accurate at call time.
- **Reverting real hook**: If any stored hook reverts on `beforePayRecordedWith`, payments are blocked. If the 721 hook has `useDataHookForCashOut: true`, its revert for fungible cashouts propagates. Suckers are immune to this for cash outs (early return), but not for payments.
- **Hook forwarding is view-only**: The deployer's data hook functions are `view`, so any real hook that requires state changes in `beforePayRecordedWith` or `beforeCashOutRecordedWith` will fail.
- **Meta-transaction trust**: ERC2771 `_msgSender()` is used for salt hashing. A compromised trusted forwarder could impersonate senders and create suckers at unexpected addresses.
- **Ownership transfer timing**: The 721 hook's ownership is transferred to the project after the project NFT is minted. In `launchProjectFor`, the hook is deployed before the project exists, and ownership is transferred after `controller.launchProjectFor` returns. If the controller call reverts, the hook exists but is owned by the deployer (the whole transaction reverts, so this is safe).
