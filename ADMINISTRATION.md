# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Omnichain project launch, ruleset queuing, runtime wrapper config, and sucker deployment integration |
| Control posture | Mixed deployer/wrapper control plus project-local delegated authority |
| Highest-risk actions | Queuing rulesets with bad wrapper config, launching with the wrong controller assumptions, and misconfigured sucker deployment |
| Recovery posture | Some config can be superseded with new rulesets; wrong immutable dependencies require replacement infra |

## Purpose

`nana-omnichain-deployers-v6` combines deployment authority with runtime wrapper authority. The critical admin question is not just who can launch or queue rulesets, but also who controls the wrapped hook composition and registered sucker behavior afterward.

## Control Model

- `JBOmnichainDeployer` is both deployer and live data-hook wrapper.
- Project-local authority flows through project ownership and `JBPermissions`.
- `SUCKER_REGISTRY` holds structural `MAP_SUCKER_TOKEN` authority granted to the deployer.
- Sucker deployment requires project-local `DEPLOY_SUCKERS` permission.
- Hook composition data is stored by ruleset and then used at runtime.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Project owner | `JBProjects.ownerOf(projectId)` | Per project | Can delegate through `JBPermissions` |
| Project operator | `JBPermissions` grant | Per project | Often `DEPLOY_SUCKERS`, `QUEUE_RULESETS`, `LAUNCH_RULESETS`, `SET_TERMINALS` |
| `JBOmnichainDeployer` | Immutable singleton | Global | Launch helper and runtime wrapper |
| `SUCKER_REGISTRY` | Immutable dependency | Global | Receives wildcard `MAP_SUCKER_TOKEN` from the deployer |

## Privileged Surfaces

| Contract | Function | Who Can Call | Effect |
| --- | --- | --- | --- |
| `JBOmnichainDeployer` | `deploySuckersFor(...)` | Project owner or `DEPLOY_SUCKERS` delegate | Extends an existing project with suckers |
| `JBOmnichainDeployer` | `launchProjectFor(...)` | Anyone | Launches a new omnichain-shaped project |
| `JBOmnichainDeployer` | `launchRulesetsFor(...)` | Project owner or relevant delegates | Launches rulesets for an existing project |
| `JBOmnichainDeployer` | `queueRulesetsOf(...)` | Project owner or `QUEUE_RULESETS` delegate | Queues rulesets and stores runtime wrapper config |

## Immutable And One-Way

- Constructor dependencies are immutable.
- Ruleset-keyed hook configuration becomes the runtime source of truth once stored.
- Deterministic sucker deployment assumptions depend on stable salts and deployer config.
- The deployer's wildcard grant to `SUCKER_REGISTRY` is structural.

## Operational Notes

- Review launch and runtime-wrapper behavior together for every admin change.
- Validate controller matching on existing-project flows before launch or queue operations.
- Treat hook-order changes as runtime behavior changes, not just deployment metadata changes.
- Arrange token-mapping authority for the registry before using the end-to-end sucker deployment path.

## Machine Notes

- Do not treat this repo as deployment-only; queued wrapper config is a live runtime input.
- Inspect `src/JBOmnichainDeployer.sol` alongside project rulesets before assuming current behavior.
- If directory/controller state and stored wrapper config diverge, stop and resolve the mismatch before further admin actions.

## Recovery

- If a ruleset was queued with bad wrapper config, recover through new rulesets if the project still has the necessary authority.
- If the wrong deterministic deployment assumptions or constructor dependencies were used, recover with replacement infra.

## Admin Boundaries

- The deployer cannot bypass project-local permission checks on existing-project launch, queue, or sucker deployment paths.
- It cannot mutate constructor immutables after deployment.
- It does not own core treasury accounting or project ownership semantics outside the flows it wraps.

## Source Map

- `src/JBOmnichainDeployer.sol`
- `src/interfaces/IJBOmnichainDeployer.sol`
- `src/structs/`
- `test/`
