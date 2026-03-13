# nana-omnichain-deployers-v6 — Risks

## Trust Assumptions

1. **JBOmnichainDeployer as Data Hook** — Acts as data hook for all projects it deploys. A bug in the deployer affects every omnichain project's cash-out behavior.
2. **Sucker Registry** — Trusts JBSuckerRegistry to correctly track registered suckers. The deployer grants 0% cash-out tax to any address the registry identifies as a sucker.
3. **Project Owner** — Can queue new rulesets, deploy additional suckers, and manage project configuration through the deployer.
4. **Core Protocol** — Relies on JBController, JBDirectory, and JBMultiTerminal for correct operation.
5. **Bridge Infrastructure** — Inherits all sucker trust assumptions (bridge liveness, remote peer authentication).

## Known Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| Sucker privilege abuse | Any registered sucker gets 0% cashout tax | Sucker registration requires DEPLOY_SUCKERS permission |
| Data hook centralization | Deployer is the data hook for all omnichain projects | Simple pass-through logic minimizes attack surface. The 721 hook (in `_tiered721HookOf`) and custom hook (in `_extraDataHookOf`) each have their own `useDataHookForCashOut` flag — set to `false` on the 721 config to skip it for fungible cashouts. Suckers always get the early return regardless of hook configuration. |
| Controller mismatch | Reverts if provided controller doesn't match project's actual controller | Explicit validation via `JBOmnichainDeployer_ControllerMismatch` |
| Invalid self-hook | Reverts if someone tries to set deployer as hook for deployer itself | `JBOmnichainDeployer_InvalidHook` check in `_setup721()` |
| Ownership transfer timing | 721 hook is deployed before project exists in `launchProjectFor` | Ownership transfer deferred until after `controller.launchProjectFor` returns; if controller reverts, entire tx reverts |
| Ruleset ID prediction | `_setup721()` stores hooks keyed by predicted `block.timestamp + i` | `queueRulesetsOf` guards with `latestRulesetIdOf >= block.timestamp` check; `launchProjectFor` predicts from `PROJECTS.count()` |
| Carry-forward stale hook | `queueRulesetsOf` with 0 tiers carries forward from latest ruleset | Only carries forward from `_tiered721HookOf[projectId][latestRulesetId]` — if no hook stored for latest ruleset, returns zero-address hook |

## Privileged Roles

| Role | Capabilities | Scope |
|------|-------------|-------|
| Project owner | Queue rulesets, deploy suckers, manage configuration | Per-project |
| Registered suckers | 0% cash-out tax on token bridging | Per-project |
| JBSuckerRegistry | Determines which addresses are valid suckers | Protocol-wide |

## Reentrancy Considerations

| Function | Protection | Risk |
|----------|-----------|------|
| `launchProjectFor` | Ownership transferred after all setup complete | LOW |
| `beforeCashOutRecordedWith` | View-like function, returns data only | NONE |
| `beforePayRecordedWith` | View-like function, returns data only | NONE |
