# Administration

Admin privileges and their scope in nana-omnichain-deployers-v6.

## Roles

| Role | How Assigned | Scope |
|------|-------------|-------|
| Project owner | Holds the project's ERC-721 (minted by `JBProjects`) | Per-project. Can delegate via `JBPermissions`. |
| Permitted operator | Granted specific permission IDs by the project owner through `JBPermissions` | Per-project, per-permission. ROOT (255) grants all. Wildcard projectId=0 grants across all projects. |
| Registered sucker | Deployed via `JBSuckerRegistry.deploySuckersFor` (requires DEPLOY_SUCKERS permission) | Per-project. Gets 0% cash-out tax and mint permission automatically. |
| JBSuckerRegistry | Set at construction, granted MAP_SUCKER_TOKEN for all projects (projectId=0 wildcard) | Protocol-wide. Maps tokens for sucker bridging. |

## Privileged Functions

### JBOmnichainDeployer

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|--------------|
| `deploySuckersFor` | Project owner or operator | `DEPLOY_SUCKERS` | Per-project | Deploys new cross-chain suckers for an existing project via the sucker registry. |
| `launch721RulesetsFor` | Project owner or operator | `QUEUE_RULESETS` + `SET_TERMINALS` | Per-project | Deploys a 721 tiers hook, launches new rulesets with terminal configuration for an existing project. |
| `launchRulesetsFor` | Project owner or operator | `QUEUE_RULESETS` + `SET_TERMINALS` | Per-project | Launches new rulesets with terminal configuration for an existing project (no 721 hook). |
| `queue721RulesetsOf` | Project owner or operator | `QUEUE_RULESETS` | Per-project | Deploys a 721 tiers hook and queues new rulesets for an existing project. |
| `queueRulesetsOf` | Project owner or operator | `QUEUE_RULESETS` | Per-project | Queues new rulesets for an existing project (no 721 hook). |

### Permissionless Functions

| Function | Who Can Call | What It Does |
|----------|-------------|--------------|
| `launchProjectFor` | Anyone | Creates a new project with suckers. The ERC-721 is minted to the specified `owner`. |
| `launch721ProjectFor` | Anyone | Creates a new project with a 721 tiers hook and suckers. The ERC-721 is minted to the specified `owner`. |
| `beforePayRecordedWith` | JBMultiTerminal (via controller) | View function: forwards pay data to the stored data hook, or passes through if none configured. |
| `beforeCashOutRecordedWith` | JBMultiTerminal (via controller) | View function: returns 0% cash-out tax for registered suckers, otherwise forwards to stored data hook. |
| `hasMintPermissionFor` | JBController | View function: returns true for registered suckers, otherwise forwards to stored data hook. |
| `dataHookOf` | Anyone | View function: returns the stored data hook config for a project/ruleset pair. |

## Deployment Administration

**Who can deploy omnichain projects:** Anyone. The `launchProjectFor` and `launch721ProjectFor` functions are permissionless. The caller specifies an `owner` address that receives the project ERC-721.

**Deployment flow:**
1. The deployer temporarily owns the project ERC-721 (minted to `address(this)`).
2. It configures rulesets, sets itself as the data hook wrapper, and optionally deploys suckers.
3. It transfers the project ERC-721 to the specified `owner`.

**Configurable parameters at deployment:**
- Ruleset configurations (duration, weight, decay, approval hooks, splits, fund access limits, metadata flags).
- Terminal configurations (which terminals accept which tokens).
- 721 tiers hook configuration (tier pricing, supply, metadata, categories).
- Sucker deployment configuration (which chains, which deployers, token mappings).
- Salt for deterministic cross-chain address matching.

## Cross-Chain Controls

| Action | Who | Mechanism |
|--------|-----|-----------|
| Deploy suckers for existing project | Project owner or DEPLOY_SUCKERS operator | `deploySuckersFor` calls `SUCKER_REGISTRY.deploySuckersFor` |
| Deploy suckers during project launch | Project deployer (anyone) | Included in `launchProjectFor` / `launch721ProjectFor` if `salt != bytes32(0)` |
| Map sucker tokens | JBSuckerRegistry | Granted MAP_SUCKER_TOKEN at construction with projectId=0 wildcard |
| Grant 0% cash-out tax to suckers | Automatic | `beforeCashOutRecordedWith` checks `SUCKER_REGISTRY.isSuckerOf` |
| Grant mint permission to suckers | Automatic | `hasMintPermissionFor` checks `SUCKER_REGISTRY.isSuckerOf` |

**Cross-chain determinism:** The salt for sucker deployment is combined with `_msgSender()` (`keccak256(abi.encode(salt, _msgSender()))`). Deploying from the same sender address with the same salt on each chain produces matching sucker addresses.

## Immutable Configuration

These values are set at deployment and cannot be changed:

| Property | Type | What It Is |
|----------|------|-----------|
| `PROJECTS` | `IJBProjects` | The ERC-721 contract for project ownership. |
| `HOOK_DEPLOYER` | `IJB721TiersHookDeployer` | The deployer for 721 tiers hooks. |
| `SUCKER_REGISTRY` | `IJBSuckerRegistry` | The registry for deploying and tracking suckers. |
| `PERMISSIONS` | `IJBPermissions` | The permissions contract (inherited from JBPermissioned). |
| Trusted forwarder | `address` | The ERC-2771 trusted forwarder for meta-transactions. |
| MAP_SUCKER_TOKEN grant | Permission | Granted to SUCKER_REGISTRY at construction for all projects (projectId=0). Cannot be revoked by this contract. |

**Data hook mappings** (`_dataHookOf[projectId][rulesetId]`) are write-once per ruleset ID. They are set during `_setup` and never updated or deleted.

## Admin Boundaries

What admins **cannot** do:

- **Cannot upgrade the deployer.** JBOmnichainDeployer has no upgrade mechanism, proxy pattern, or self-destruct.
- **Cannot change immutable references.** PROJECTS, HOOK_DEPLOYER, SUCKER_REGISTRY, PERMISSIONS, and the trusted forwarder are all immutable.
- **Cannot modify stored data hooks.** Once a ruleset's data hook config is stored in `_dataHookOf`, it cannot be changed. New rulesets can use different hooks, but existing mappings are permanent.
- **Cannot bypass permission checks.** All post-deployment admin functions require JBPermissions verification against the project owner.
- **Cannot revoke sucker privileges.** Once a sucker is registered in JBSuckerRegistry, it automatically gets 0% cash-out tax and mint permission for its project. Revocation must happen at the registry level.
- **Cannot set the deployer as its own data hook.** The `_setup` function explicitly reverts with `JBOmnichainDeployer_InvalidHook` if `metadata.dataHook == address(this)`.
- **Cannot use a controller that doesn't match the project.** `_validateController` reverts with `JBOmnichainDeployer_ControllerMismatch` if the provided controller is not the project's actual controller in the directory.
- **Cannot steal project ownership during deployment.** The deployer holds the project ERC-721 only transiently and transfers it to the specified owner in the same transaction.
- **Cannot drain funds.** The deployer never holds or manages token balances. It only orchestrates configuration.
