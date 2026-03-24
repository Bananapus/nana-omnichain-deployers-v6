# Juicebox Omnichain Deployers

## Purpose

Single-transaction deployment of Juicebox projects with cross-chain suckers and 721 tiers hooks. Every project gets a 721 hook (even with 0 initial tiers), so projects can add NFT tiers later without reconfiguring. Wraps the project's data hooks to give suckers tax-free cash outs and mint permission without interfering with custom hooks. Stores the 721 hook per-ruleset in `_tiered721HookOf` and the optional custom hook per-ruleset in `_extraDataHookOf`, each with their own `useDataHookForCashOut` flag. Supports composing a 721 hook alongside a custom data hook (e.g., buyback hook) — both run on every payment.

## Contracts

| Contract | Role |
|----------|------|
| `JBOmnichainDeployer` | Deploys projects/rulesets/suckers, wraps data hooks for sucker tax exemption. Always deploys a 721 hook. Stores 721 hook per-ruleset in `_tiered721HookOf` and custom hook per-ruleset in `_extraDataHookOf`. Implements `IJBRulesetDataHook`, `IERC721Receiver`, `ERC2771Context`, `JBPermissioned`. |

## Key Functions

### Deployment

| Function | What it does |
|----------|-------------|
| `launchProjectFor(owner, projectUri, deploy721Config, rulesetConfigs, terminalConfigs, memo, suckerConfig, controller)` | Creates a new project with a 721 tiers hook, rulesets, terminals, and suckers in one tx. Always deploys a 721 hook (even with 0 tiers). Temporarily holds the project NFT. Returns `(projectId, hook, suckers)`. |
| `launchProjectFor(owner, projectUri, rulesetConfigs, terminalConfigs, memo, suckerConfig, controller)` | Simplified overload — omits `deploy721Config`, uses `_default721Config` (empty tiers, baseCurrency from first ruleset, decimals=18). |
| `launchRulesetsFor(projectId, deploy721Config, rulesetConfigs, terminalConfigs, memo, controller)` | Launches new rulesets + terminals with a new 721 tiers hook for an existing project. Requires `LAUNCH_RULESETS` + `SET_TERMINALS`. Returns `(rulesetId, hook)`. |
| `launchRulesetsFor(projectId, rulesetConfigs, terminalConfigs, memo, controller)` | Simplified overload — omits `deploy721Config`, uses `_default721Config`. |
| `queueRulesetsOf(projectId, deploy721Config, rulesetConfigs, memo, controller)` | Queues future rulesets. If tiers provided, deploys a new 721 hook. Otherwise, carries forward the 721 hook from the latest ruleset. Requires `QUEUE_RULESETS`. Reverts if rulesets were already queued in the same block. Returns `(rulesetId, hook)`. |
| `queueRulesetsOf(projectId, rulesetConfigs, memo, controller)` | Simplified overload — omits `deploy721Config`, uses `_default721Config`. With 0 tiers, always carries forward the existing hook. |
| `deploySuckersFor(projectId, suckerConfig)` | Deploys new suckers for an existing project. Requires `DEPLOY_SUCKERS`. |

### Data Hook (IJBRulesetDataHook)

| Function | What it does |
|----------|-------------|
| `beforePayRecordedWith(context)` | Calls the 721 hook first (via `_tiered721HookOf`) for its specs (including split amounts), then calls the custom hook from `_extraDataHookOf` (if `useDataHookForPay: true`) with a reduced amount context (payment minus split amount) for weight + specs. Adjusts the returned weight proportionally so the terminal only mints tokens for the amount entering the project (`weight = mulDiv(weight, amount - splitAmount, amount)`). Merges specs (721 hook specs first if any, then custom hook specs). If the 721 hook returns no specs (0 tiers), its slot is omitted from the output. |
| `beforeCashOutRecordedWith(context)` | If holder is a sucker: returns 0% tax immediately. Calls the 721 hook first (if `useDataHookForCashOut: true`), updating cash out parameters. Then calls the custom hook from `_extraDataHookOf` (if `useDataHookForCashOut: true`) with the already-updated values. Both hooks' specifications are merged (721 specs first, then custom hook specs). If the 721 hook has the flag set and reverts (e.g., fungible cashout), the revert propagates. If neither has the flag set, returns original values. Hook specifications include a `noop` field — the 721 hook always returns `noop: false` (it needs its callback), while a custom hook like the buyback hook may return `noop: true` with routing diagnostics when the protocol path wins. |
| `hasMintPermissionFor(projectId, ruleset, addr)` | Returns `true` for registered suckers, OR if the custom hook in `_extraDataHookOf` grants permission. Returns `false` only if it doesn't grant it. |

### Views

| Function | What it does |
|----------|-------------|
| `extraDataHookOf(projectId, rulesetId)` | Returns the stored `JBDeployerHookConfig` for a given project and ruleset. Contains the custom data hook (e.g., buyback hook) with its per-hook flags. Returns empty struct if none configured. |
| `tiered721HookOf(projectId, rulesetId)` | Returns the 721 tiers hook and its `useDataHookForCashOut` flag for a given project and ruleset. |
| `supportsInterface(interfaceId)` | Returns `true` for `IJBOmnichainDeployer`, `IJBRulesetDataHook`, `IERC721Receiver`, `IERC165`. |
| `onERC721Received(...)` | Accepts project NFTs from `PROJECTS` only. Reverts for any other NFT contract. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `nana-core-v6` | `IJBController`, `JBPermissioned`, `IJBProjects`, `IJBRulesetDataHook` | Launching projects, permission checks, project NFT transfers, data hook interface |
| `nana-721-hook-v6` | `IJB721TiersHookDeployer`, `JBDeploy721TiersHookConfig` | Deploying 721 tiers hooks |
| `nana-suckers-v6` | `IJBSuckerRegistry` | Deploying suckers, checking `isSuckerOf()` for tax-free cash outs |
| `nana-ownable-v6` | `JBOwnable` | Transferring 721 hook ownership to the project |
| `nana-permission-ids-v6` | `JBPermissionIds` | Permission constants |
| `@openzeppelin/contracts` | `ERC2771Context`, `IERC721Receiver` | Meta-transaction support, receiving project NFTs |
| `@prb/math` | `mulDiv` | Weight scaling for 721 tier split amounts in `beforePayRecordedWith` |

## Key Types

| Struct | Key Fields | Used In |
|--------|------------|---------|
| `JBOmnichain721Config` | `JBDeploy721TiersHookConfig deployTiersHookConfig`, `bool useDataHookForCashOut`, `bytes32 salt` | All deploy/launch/queue functions — 721 hook deployment config. |
| `JBDeployerHookConfig` | `IJBRulesetDataHook dataHook`, `bool useDataHookForPay`, `bool useDataHookForCashOut` | `_extraDataHookOf` mapping keyed by `(projectId, rulesetId)` → single custom hook config. |
| `JBTiered721HookConfig` | `IJB721TiersHook hook`, `bool useDataHookForCashOut` | `_tiered721HookOf` mapping keyed by `(projectId, rulesetId)` → per-ruleset 721 hook config. |
| `JBSuckerDeploymentConfig` | `JBSuckerDeployerConfig[] deployerConfigurations`, `bytes32 salt` | All launch and deploy functions |

## Permission IDs

| Permission | Used By |
|------------|---------|
| `DEPLOY_SUCKERS` | `deploySuckersFor` -- deploy new suckers for a project |
| `LAUNCH_RULESETS` | `launchRulesetsFor` -- launch rulesets with terminal configuration |
| `QUEUE_RULESETS` | `queueRulesetsOf` -- queue future rulesets |
| `SET_TERMINALS` | `launchRulesetsFor` -- set terminal configurations |
| `MAP_SUCKER_TOKEN` | Granted to `SUCKER_REGISTRY` at construction with `projectId=0` (all projects) |

## Errors

| Error | When |
|-------|------|
| `JBOmnichainDeployer_InvalidHook` | `_setup721()` detects the hook is `address(this)` (prevents infinite forwarding loops), OR `queueRulesetsOf` tries to carry forward a null hook (no tiers provided and no previous hook deployed through this contract) |
| `JBOmnichainDeployer_UnexpectedNFTReceived` | `onERC721Received` called by a contract other than `PROJECTS` |
| `JBOmnichainDeployer_RulesetIdsUnpredictable` | `queueRulesetsOf` called when `latestRulesetIdOf(projectId) >= block.timestamp` -- ruleset ID prediction would fail |
| `JBOmnichainDeployer_ProjectIdMismatch` | `launchProjectFor` -- the project ID returned by the controller does not match the predicted `PROJECTS.count() + 1` |
| `JBOmnichainDeployer_ControllerMismatch` | `launchRulesetsFor`/`queueRulesetsOf` -- the provided controller does not match the project's controller in `JBDirectory` |

## Events

`JBOmnichainDeployer` does not declare any custom events. All observable state changes (project creation, ruleset queuing, sucker deployment) are emitted by the underlying contracts it calls (`IJBController`, `IJBSuckerRegistry`, `IJB721TiersHookDeployer`).

## Constants

| Name | Value | Context |
|------|-------|---------|
| `PROJECTS` | Set at construction | `IJBProjects` -- mints project NFTs. Immutable. |
| `HOOK_DEPLOYER` | Set at construction | `IJB721TiersHookDeployer` -- deploys 721 tiers hooks. Immutable. |
| `SUCKER_REGISTRY` | Set at construction | `IJBSuckerRegistry` -- deploys/tracks suckers, `isSuckerOf` checks. Immutable. |
| `projectId = 0` (wildcard) | Used in constructor | `MAP_SUCKER_TOKEN` permission granted to `SUCKER_REGISTRY` with `projectId=0`, giving it token mapping rights for all projects. |
| `decimals = 18` | Used in `_default721Config` | Default decimal precision when 721 config is omitted (simplified overloads). |
| `baseCurrency` | From first ruleset | When 721 config is omitted, `baseCurrency` is read from `rulesetConfigurations[0].metadata.baseCurrency`. Reverts with `JBOmnichainDeployer_NoRulesetConfigurations` if the array is empty. |

## Gotchas

### Deployment

- `launchProjectFor` requires **no permissions** -- anyone can launch a project to any owner address.
- `queueRulesetsOf` **reverts if called in the same block** as a previous ruleset queue (whether via deployer or directly). The `launchProjectFor` function doesn't have this guard because it predicts IDs from `PROJECTS.count()`, which is always 0 for a new project.
- Ruleset IDs in `_extraDataHookOf` are keyed by `block.timestamp + i`. If the controller assigns different IDs than predicted, the stored hook configs will be orphaned and the deployer will behave as if no hooks were set (returning default values).
- Sucker deployment salts are hashed with `_msgSender()`: `keccak256(abi.encode(salt, _msgSender()))`. Cross-chain deterministic addresses require using the **same sender** on each chain. The 721 hook salt uses `keccak256(abi.encode(_msgSender(), salt))` (reversed order).
- `salt = bytes32(0)` **skips sucker deployment entirely**. Use a nonzero salt to deploy suckers.
- Hook ownership is transferred to the **project** (not the owner) via `JBOwnable.transferOwnershipToProject(projectId)`. This happens **after** the project NFT is minted.
- The deployer holds the project NFT temporarily during launch. If the controller's `launchProjectFor` reverts, the entire transaction reverts -- no stuck NFTs.
- Every project always gets a 721 hook, even with an empty tiers array. This wires up the 721 hook from the start, so tiers can be added later without reconfiguring the data hook.
- For `queueRulesetsOf`, if no new tiers are provided, the 721 hook from the **latest ruleset** is carried forward instead of deploying a new one. Looked up from `_tiered721HookOf[projectId][latestRulesetId]`.

### Data Hook Behavior

- The deployer **always forces `useDataHookForCashOut = true`** at the protocol level so it can intercept cash outs for sucker tax exemption. However, the 721 hook's `useDataHookForCashOut` flag (stored in `_tiered721HookOf`) and the custom hook's flag (stored in `_extraDataHookOf`) each control whether that hook processes cash outs. Set `useDataHookForCashOut: false` on the 721 config to skip it for fungible cashouts (it reverts with `JB721Hook_UnexpectedTokenCashedOut` otherwise).
- Suckers get an **early return** in `beforeCashOutRecordedWith` -- they bypass all stored hooks entirely. Suckers can cash out even if any hook would revert.
- If no custom hook is stored or it doesn't grant permission, `hasMintPermissionFor` returns `false` for non-suckers. Only the custom hook in `_extraDataHookOf` is checked -- the 721 hook is not consulted.
- `_setup721()` sets `metadata.dataHook = address(this)`, `metadata.useDataHookForPay = true`, and `metadata.useDataHookForCashOut = true` on every ruleset. These cannot be overridden.
- All data hook functions (`beforePayRecordedWith`, `beforeCashOutRecordedWith`, `hasMintPermissionFor`) are `view`. If the project's real hook needs to modify state in these functions, it will fail.
- Setting a hook's `dataHook` to `address(this)` (the deployer itself) reverts with `JBOmnichainDeployer_InvalidHook`. This prevents infinite forwarding loops.
- The 721 hook is stored per-ruleset in `_tiered721HookOf[projectId][rulesetId]` with its `useDataHookForCashOut` flag. The custom data hook (if any) is stored separately in `_extraDataHookOf[projectId][rulesetId]`. They are never in the same mapping.
- The `JBOmnichain721Config` parameter bundles the 721 hook deployment config, the `useDataHookForCashOut` flag, and the `salt`. Custom data hooks are read from each ruleset's `metadata.dataHook` field.

### Permissions

- The constructor grants `MAP_SUCKER_TOKEN` permission to `SUCKER_REGISTRY` with `projectId=0`, meaning the registry can map tokens for **any project** deployed through this deployer.

### Edge Cases

- `onERC721Received` only accepts NFTs from the `PROJECTS` contract. Sending any other ERC-721 to the deployer will revert.
- ERC2771 meta-transaction support allows gasless deployments via a trusted forwarder. Salt hashing uses `_msgSender()` (not `msg.sender`), so forwarder-relayed transactions use the original sender's address for deterministic sucker addresses.

## Example Integration

```solidity
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";
import {JBOmnichain721Config} from "@bananapus/omnichain-deployers-v6/src/structs/JBOmnichain721Config.sol";
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

// Configure 721 hook (even with 0 tiers, every project gets a hook).
JBOmnichain721Config memory deploy721Config = JBOmnichain721Config({
    deployTiersHookConfig: tiersHookConfig, // tier configuration (can be empty)
    useDataHookForCashOut: false,           // set true for NFT-based cashouts
    salt: bytes32("my-hook-salt")           // deterministic 721 hook address
});

// Launch in one transaction.
(uint256 projectId, IJB721TiersHook hook, address[] memory suckers) = omnichainDeployer.launchProjectFor({
    owner: msg.sender,
    projectUri: "ipfs://project-metadata",
    deploy721Config: deploy721Config,
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

// --- Queue new rulesets (carries forward existing 721 hook if no new tiers) ---

// Requires QUEUE_RULESETS permission. Must be called in a different block
// than any previous ruleset queue for this project.
// Custom data hooks are read from each ruleset's metadata.dataHook field.
JBOmnichain721Config memory queue721Config = JBOmnichain721Config({
    deployTiersHookConfig: emptyTiersConfig, // no new tiers = carry forward existing hook
    useDataHookForCashOut: false,
    salt: bytes32(0)                         // no salt needed when carrying forward
});

(uint256 rulesetId, IJB721TiersHook queuedHook) = omnichainDeployer.queueRulesetsOf({
    projectId: projectId,
    deploy721Config: queue721Config,
    rulesetConfigurations: queueConfig,
    memo: "Queue new rulesets",
    controller: controller
});
```

## Buyback Hook + 721 Hook Composition

The most complex use case: a project with NFT tiers (721 hook) AND a buyback hook, both running on every payment. The deployer composes them automatically.

```solidity
import {IJBBuybackHook} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHook.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";

// --- Key concept: the buyback hook goes in metadata.dataHook ---
// The deployer extracts it, stores it in _extraDataHookOf, and replaces
// metadata.dataHook with address(this) so it can intercept all calls.

// 1. Configure the buyback hook as the ruleset's custom data hook.
JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
rulesetConfigs[0].metadata = JBRulesetMetadata({
    // ... other metadata fields ...
    dataHook: address(buybackHook),   // <-- deployer extracts this
    useDataHookForPay: true,          // buyback hook processes payments
    useDataHookForCashOut: false      // buyback hook does NOT process cashouts
    // ...
});

// 2. Configure the 721 hook with NFT tiers.
JBOmnichain721Config memory deploy721Config = JBOmnichain721Config({
    deployTiersHookConfig: tiersHookConfig,  // your NFT tier config
    useDataHookForCashOut: false,            // false = skip 721 on fungible cashouts
    salt: bytes32("my-hook-salt")
});

// 3. Launch -- both hooks are wired up automatically.
(uint256 projectId, IJB721TiersHook hook, address[] memory suckers) =
    omnichainDeployer.launchProjectFor({
        owner: msg.sender,
        projectUri: "ipfs://metadata",
        deploy721Config: deploy721Config,
        rulesetConfigurations: rulesetConfigs,
        terminalConfigurations: terminalConfigs,
        memo: "Buyback + 721 project",
        suckerDeploymentConfiguration: suckerConfig,
        controller: controller
    });

// --- What happens on each payment: ---
// 1. beforePayRecordedWith calls the 721 hook first (tier matching, NFT minting specs)
// 2. Reduces the payment amount by the 721 split amount
// 3. Calls the buyback hook with the reduced amount (so it only buys back with leftover)
// 4. Adjusts weight proportionally: weight = mulDiv(weight, amount - splitAmount, amount)
// 5. Merges specs: 721 specs first, then buyback specs
//
// --- What happens on cashout: ---
// With useDataHookForCashOut: false on both hooks:
//   - Suckers still get 0% tax (the deployer intercepts before any hook)
//   - Regular users get standard bonding curve cashout (no hook interference)
```
