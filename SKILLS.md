# nana-omnichain-deployers-v6

## Purpose

Single-transaction deployment of Juicebox projects with cross-chain suckers and optional 721 tiers hooks. Wraps the project's data hook to give suckers tax-free cash outs and mint permission without interfering with custom hooks.

## Contracts

| Contract | Role |
|----------|------|
| `JBOmnichainDeployer` | Deploys projects/rulesets/suckers, wraps data hooks for sucker tax exemption. Implements `IJBRulesetDataHook`, `IERC721Receiver`, `ERC2771Context`, `JBPermissioned`. |

## Key Functions

### Deployment

| Function | What it does |
|----------|-------------|
| `launchProjectFor(owner, projectUri, rulesetConfigs, terminalConfigs, memo, suckerConfig, controller)` | Creates a new project with rulesets, terminals, and suckers in one tx. Temporarily holds the project NFT. Returns `(projectId, suckers)`. |
| `launch721ProjectFor(owner, deployTiersHookConfig, launchProjectConfig, salt, suckerConfig, controller)` | Same as above but also deploys a 721 tiers hook and transfers its ownership to the project. Returns `(projectId, hook, suckers)`. |
| `launchRulesetsFor(projectId, rulesetConfigs, terminalConfigs, memo, controller)` | Launches new rulesets + terminals for an existing project. Requires `QUEUE_RULESETS` + `SET_TERMINALS`. |
| `launch721RulesetsFor(projectId, deployTiersHookConfig, launchRulesetsConfig, controller, salt)` | Launches rulesets with a new 721 tiers hook. Requires `QUEUE_RULESETS` + `SET_TERMINALS`. |
| `queueRulesetsOf(projectId, rulesetConfigs, memo, controller)` | Queues future rulesets. Requires `QUEUE_RULESETS`. Reverts if rulesets were already queued in the same block. |
| `queue721RulesetsOf(projectId, deployTiersHookConfig, queueRulesetsConfig, controller, salt)` | Queues rulesets with a new 721 tiers hook. Same same-block guard. |
| `deploySuckersFor(projectId, suckerConfig)` | Deploys new suckers for an existing project. Requires `DEPLOY_SUCKERS`. |

### Data Hook (IJBRulesetDataHook)

| Function | What it does |
|----------|-------------|
| `beforePayRecordedWith(context)` | Forwards to the stored real data hook if set and `useDataHookForPay` is true. Otherwise returns the original weight. |
| `beforeCashOutRecordedWith(context)` | If holder is a sucker: returns 0% tax immediately (never calls real hook). Otherwise forwards to the real hook, or returns original values if none set. |
| `hasMintPermissionFor(projectId, ruleset, addr)` | Returns `true` for registered suckers. Otherwise forwards to real hook, or returns `false` if none set. |

### Views

| Function | What it does |
|----------|-------------|
| `dataHookOf(projectId, rulesetId)` | Returns the stored `(useDataHookForPay, useDataHookForCashOut, dataHook)` for a given project and ruleset. |
| `supportsInterface(interfaceId)` | Returns `true` for `IJBOmnichainDeployer`, `IJBRulesetDataHook`, `IERC721Receiver`, `IERC165`. |
| `onERC721Received(...)` | Accepts project NFTs from `PROJECTS` only. Reverts for any other NFT contract. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `nana-core-v6` | `IJBController`, `JBPermissioned`, `IJBProjects`, `IJBRulesetDataHook` | Launching projects, permission checks, project NFT transfers, data hook interface |
| `nana-721-hook-v6` | `IJB721TiersHookDeployer`, `JBDeploy721TiersHookConfig`, `JBLaunchProjectConfig`, `JBPayDataHookRulesetConfig` | Deploying 721 tiers hooks, converting 721 configs to standard configs |
| `nana-suckers-v6` | `IJBSuckerRegistry` | Deploying suckers, checking `isSuckerOf()` for tax-free cash outs |
| `nana-ownable-v6` | `JBOwnable` | Transferring 721 hook ownership to the project |
| `nana-permission-ids-v6` | `JBPermissionIds` | Permission constants |
| `@openzeppelin/contracts` | `ERC2771Context`, `IERC721Receiver` | Meta-transaction support, receiving project NFTs |

## Key Types

| Struct | Key Fields | Used In |
|--------|------------|---------|
| `JBDeployerHookConfig` | `bool useDataHookForPay`, `bool useDataHookForCashOut`, `IJBRulesetDataHook dataHook` | `_dataHookOf` mapping keyed by `(projectId, rulesetId)` |
| `JBSuckerDeploymentConfig` | `JBSuckerDeployerConfig[] deployerConfigurations`, `bytes32 salt` | All launch and deploy functions |

## Permission IDs

| Permission | Used By |
|------------|---------|
| `DEPLOY_SUCKERS` | `deploySuckersFor` -- deploy new suckers for a project |
| `QUEUE_RULESETS` | `launchRulesetsFor`, `launch721RulesetsFor`, `queueRulesetsOf`, `queue721RulesetsOf` -- modify project rulesets |
| `SET_TERMINALS` | `launchRulesetsFor`, `launch721RulesetsFor` -- set terminal configurations |
| `MAP_SUCKER_TOKEN` | Granted to `SUCKER_REGISTRY` at construction with `projectId=0` (all projects) |

## Errors

| Error | When |
|-------|------|
| `JBOmnichainDeployer_InvalidHook` | `_setup()` detects `rulesetConfig.metadata.dataHook == address(this)` -- prevents infinite forwarding loops |
| `JBOmnichainDeployer_UnexpectedNFTReceived` | `onERC721Received` called by a contract other than `PROJECTS` |
| `JBOmnichainDeployer_RulesetIdsUnpredictable` | `queueRulesetsOf`/`queue721RulesetsOf` called when `latestRulesetIdOf(projectId) >= block.timestamp` -- ruleset ID prediction would fail |

## Gotchas

1. `launchProjectFor` and `launch721ProjectFor` require **no permissions** -- anyone can launch a project to any owner address.
2. `queueRulesetsOf` and `queue721RulesetsOf` **revert if called in the same block** as a previous ruleset queue (whether via deployer or directly). The `launch*` functions don't have this guard because they predict IDs from `PROJECTS.count()`, which is always 0 for a new project.
3. Ruleset IDs in `_dataHookOf` are keyed by `block.timestamp + i`. If the controller assigns different IDs than predicted, the stored hook config will be orphaned and the deployer will behave as if no hook was set (returning default values).
4. Sucker deployment salts are hashed with `_msgSender()`: `keccak256(abi.encode(salt, _msgSender()))`. Cross-chain deterministic addresses require using the **same sender** on each chain. For `launch721ProjectFor`, the 721 hook salt uses `keccak256(abi.encode(_msgSender(), salt))` (reversed order).
5. `salt = bytes32(0)` **skips sucker deployment entirely**. Use a nonzero salt to deploy suckers.
6. The deployer **always forces `useDataHookForCashOut = true`** on every ruleset it touches, even if the original config had it as `false`. This is required so the deployer can intercept cash outs to check for suckers.
7. Suckers get an **early return** in `beforeCashOutRecordedWith` -- they bypass the real data hook entirely. This means suckers can cash out even if the real hook would revert.
8. If no real data hook is stored (or `address(0)`), `hasMintPermissionFor` returns `false` for non-suckers. It does **not** return the default `true`.
9. 721 ruleset config conversion enforces `useDataHookForPay = true` and `allowSetCustomToken = false`. These cannot be overridden.
10. Hook ownership is transferred to the **project** (not the owner) via `JBOwnable.transferOwnershipToProject(projectId)`. The project owner controls the hook through project ownership.
11. The deployer holds the project NFT temporarily during launch. If the controller's `launchProjectFor` reverts, the entire transaction reverts -- no stuck NFTs.
12. The constructor grants `MAP_SUCKER_TOKEN` permission to `SUCKER_REGISTRY` with `projectId=0`, meaning the registry can map tokens for **any project** deployed through this deployer.
13. All data hook functions (`beforePayRecordedWith`, `beforeCashOutRecordedWith`, `hasMintPermissionFor`) are `view`. If the project's real hook needs to modify state in these functions, it will fail.
14. Setting a ruleset's `dataHook` to `address(this)` (the deployer itself) reverts with `JBOmnichainDeployer_InvalidHook`. This prevents infinite forwarding loops.
15. `onERC721Received` only accepts NFTs from the `PROJECTS` contract. Sending any other ERC-721 to the deployer will revert.
16. ERC2771 meta-transaction support allows gasless deployments via a trusted forwarder. Salt hashing uses `_msgSender()` (not `msg.sender`), so forwarder-relayed transactions use the original sender's address for deterministic sucker addresses.

## Example Integration

```solidity
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";
import {JBSuckerDeploymentConfig} from "@bananapus/omnichain-deployers-v6/src/structs/JBSuckerDeploymentConfig.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

// --- Launch a project with suckers ---

// Configure sucker deployment (use a nonzero salt to deploy suckers).
JBSuckerDeploymentConfig memory suckerConfig = JBSuckerDeploymentConfig({
    deployerConfigurations: suckerDeployerConfigs, // per-chain sucker configs
    salt: bytes32("my-project-salt")               // deterministic addresses
});

// Launch in one transaction.
(uint256 projectId, address[] memory suckers) = omnichainDeployer.launchProjectFor({
    owner: msg.sender,
    projectUri: "ipfs://project-metadata",
    rulesetConfigurations: rulesetConfigs,
    terminalConfigurations: terminalConfigs,
    memo: "Launching omnichain project",
    suckerDeploymentConfiguration: suckerConfig,
    controller: controller
});

// --- Add suckers to an existing project ---

// Requires DEPLOY_SUCKERS permission on the project.
address[] memory newSuckers = omnichainDeployer.deploySuckersFor({
    projectId: projectId,
    suckerDeploymentConfiguration: suckerConfig
});

// --- Queue new rulesets with a 721 hook ---

// Requires QUEUE_RULESETS permission. Must be called in a different block
// than any previous ruleset queue for this project.
(uint256 rulesetId, IJB721TiersHook hook) = omnichainDeployer.queue721RulesetsOf({
    projectId: projectId,
    deployTiersHookConfig: tiersHookConfig,
    queueRulesetsConfig: queueConfig,
    controller: controller,
    salt: bytes32("my-hook-salt")
});
```
