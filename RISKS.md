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
| Data hook centralization | Deployer is the data hook for all omnichain projects | Simple pass-through logic minimizes attack surface. Users can set `useDataHookForCashOut: false` to bypass all hook processing for cashouts (721 + custom), reducing the attack surface to sucker-check only. |
| Controller mismatch | Reverts if provided controller doesn't match project's actual controller | Explicit validation via `JBOmnichainDeployer_ControllerMismatch` |
| Invalid self-hook | Reverts if someone tries to set deployer as hook for deployer itself | `JBOmnichainDeployer_InvalidHook` check |
| Ownership transfer | Project ownership transferred during deployment | Ownership returned to caller after setup |

## Privileged Roles

| Role | Capabilities | Scope |
|------|-------------|-------|
| Project owner | Queue rulesets, deploy suckers, manage configuration | Per-project |
| Registered suckers | 0% cash-out tax on token bridging | Per-project |
| JBSuckerRegistry | Determines which addresses are valid suckers | Protocol-wide |

## Reentrancy Considerations

| Function | Protection | Risk |
|----------|-----------|------|
| `deployProjectFor` | Ownership transferred after all setup complete | LOW |
| `beforeCashOutRecordedWith` | View-like function, returns data only | NONE |
| `beforePayRecordedWith` | View-like function, returns data only | NONE |
