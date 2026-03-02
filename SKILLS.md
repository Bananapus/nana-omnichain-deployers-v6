# nana-omnichain-deployers-v5 — AI Reference

## Purpose

Convenience contract for deploying Juicebox projects with cross-chain suckers (and optionally 721 tiers hooks) in a single transaction. Also wraps the project's data hook to allow tax-free cash outs from suckers.

## Contracts

### JBOmnichainDeployer (src/JBOmnichainDeployer.sol)
Implements `IJBOmnichainDeployer`, `IJBRulesetDataHook`, `IERC721Receiver`, `ERC2771Context`, `JBPermissioned`.

**Immutable state:**
- `IJBProjects public PROJECTS`
- `IJB721TiersHookDeployer public HOOK_DEPLOYER`
- `IJBSuckerRegistry public SUCKER_REGISTRY`

**Storage:**
- `mapping(uint256 projectId => mapping(uint256 rulesetId => JBDeployerHookConfig)) internal _dataHookOf`

**Constructor** grants `MAP_SUCKER_TOKEN` permission to `SUCKER_REGISTRY` for all projects (projectId=0 wildcard).

## Entry Points

### Project Launch
```solidity
function launchProjectFor(
    address owner, string calldata projectUri,
    JBRulesetConfig[] memory rulesetConfigurations,
    JBTerminalConfig[] calldata terminalConfigurations,
    string calldata memo,
    JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
    IJBController controller
) external returns (uint256 projectId, address[] memory suckers)

function launch721ProjectFor(
    address owner,
    JBDeploy721TiersHookConfig calldata deployTiersHookConfig,
    JBLaunchProjectConfig calldata launchProjectConfig,
    bytes32 salt,
    JBSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
    IJBController controller
) external returns (uint256 projectId, IJB721TiersHook hook, address[] memory suckers)
```

### Rulesets
```solidity
function launchRulesetsFor(uint256 projectId, JBRulesetConfig[] calldata, JBTerminalConfig[] calldata, string calldata memo, IJBController controller) external returns (uint256)
function launch721RulesetsFor(uint256 projectId, JBDeploy721TiersHookConfig memory, JBLaunchRulesetsConfig calldata, IJBController controller, bytes32 salt) external returns (uint256, IJB721TiersHook)
function queueRulesetsOf(uint256 projectId, JBRulesetConfig[] calldata, string calldata memo, IJBController controller) external returns (uint256)
function queue721RulesetsOf(uint256 projectId, JBDeploy721TiersHookConfig memory, JBQueueRulesetsConfig calldata, IJBController controller, bytes32 salt) external returns (uint256, IJB721TiersHook)
```

### Suckers
```solidity
function deploySuckersFor(uint256 projectId, JBSuckerDeploymentConfig calldata) external returns (address[] memory)
```
Requires `DEPLOY_SUCKERS` permission.

### Data Hook Forwarding
```solidity
function beforePayRecordedWith(JBBeforePayRecordedContext calldata) external view returns (uint256, JBPayHookSpecification[] memory)
function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata) external view returns (uint256, uint256, uint256, JBCashOutHookSpecification[] memory)
function hasMintPermissionFor(uint256 projectId, JBRuleset memory, address addr) external view returns (bool)
```

## Integration Points

- **JBController**: Called to `launchProjectFor`, `launchRulesetsFor`, `queueRulesetsOf`.
- **JBSuckerRegistry**: Used to deploy suckers and check `isSuckerOf` for tax-free cash outs.
- **IJB721TiersHookDeployer**: Deploys 721 tiers hooks for projects.
- **JBPermissions**: Permission checks for `DEPLOY_SUCKERS`, `QUEUE_RULESETS`, `SET_TERMINALS`.
- **JBProjects**: Temporarily receives project NFT during launch, then transfers to owner.

## Key Patterns

- **Data hook wrapping**: The deployer inserts itself as the data hook on all rulesets via `_setup()`. The real data hook is stored in `_dataHookOf` and calls are forwarded. This enables sucker-specific logic (tax-free cash outs, mint permission) without modifying the real data hook.
- **Ruleset ID keying**: Data hooks are stored keyed by `block.timestamp + i` (matching ruleset IDs assigned during launch).
- **Sucker tax exemption**: `beforeCashOutRecordedWith` returns `cashOutTaxRate = 0` when `SUCKER_REGISTRY.isSuckerOf(projectId, holder)` is true.
- **Salt hashing**: Sucker deployment salts are hashed with `_msgSender()` to prevent cross-deployer address collisions.
- **Self-referencing guard**: `_setup()` reverts if any ruleset's data hook is already set to `address(this)` to prevent infinite forwarding loops.
