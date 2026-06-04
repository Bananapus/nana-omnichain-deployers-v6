# Omnichain Deployers Risk Register

This file covers the risks in the deployer layer that launches Juicebox projects across chains while composing 721 hooks, suckers, and optional custom data hooks.

## How to use this file

- Read `Priority risks` first. They capture the highest-blast-radius deployment and cash-out assumptions.
- Treat `Invariants to verify` as required checks for any new omnichain deployment flow.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Registry-trusted sucker bypass | This deployer gives suckers privileged cash-out behavior based on registry answers. A bad registry entry can affect many projects. | Registry allowlists, deployment verification, and explicit registry scrutiny. |
| P1 | Cross-chain deployment drift | Omnichain assumptions fail if chain-specific wiring, peers, or composed hooks do not match. | Deterministic deploy ordering, parity checks, and post-deploy peer verification. |
| P1 | Data-hook composition mistakes | The deployer wraps or forwards custom data hooks. A bad composition can alter pay or cash-out semantics unexpectedly. | Integration tests and careful forwarding review. |

## 1. Trust assumptions

- **Trusted forwarder is trusted.**
- **Sucker registry answers are trusted.**
- **Sucker cash-outs are bridge accounting, not ordinary global cash-outs.** They use local supply/surplus so value
  leaves a chain in proportion to funds on that chain.
- **Controller trust matters.**
- **Extra data hooks are trusted code.**

## 2. Economic risks

- **Sucker cash-out bypass exists for registered suckers.**
- **Extra data hooks can manipulate weight or cash-out behavior.**
- **721 hook amount splitting can zero out project amount in edge cases.**
- **Cross-chain sender dependence affects deterministic sucker salts.**

## 3. Access control

- **Wildcard `MAP_SUCKER_TOKEN` permission is scoped to the deployer's own account.** See [`INVARIANTS.md`](./INVARIANTS.md) Section B.4 — the constructor-time grant authorizes the registry to act *as this deployer*, but the deployer is never a project owner post hand-over so the grant has no exploitable scope.
- **Explicit sucker peers are privileged.** Existing-project deployments with non-default peers require
  `SET_SUCKER_PEER` in addition to `DEPLOY_SUCKERS`; default deterministic peering remains deploy-only.
- **`launchRulesetsFor` requires combined permissions.**
- **`launchProjectFor` is intentionally permissionless for new projects.**

## 4. DoS vectors

- **Ruleset ID collision can block queueing.**
- **External hook reverts can block pay or cash-out flows.**
- **721 hook deployment revert blocks launch.**
- **Non-safe NFT transfers can still strand assets.**

## 5. Reentrancy surface

- **`launchProjectFor` makes several external calls in sequence.**
- **`beforePayRecordedWith` delegates to external hooks.**
- **`beforeCashOutRecordedWith` delegates to external hooks.**
- **There is no `ReentrancyGuard`.** The deployer relies on being effectively stateless during pay and cash-out operations.

## 6. Integration risks

- **Hook config is keyed by predicted ruleset ID.**
- **Carried-forward 721 hook behavior on queue depends on prior ruleset state.**
- **ERC721Receiver restrictions are narrow but non-safe transfers can still strand assets.**
- **Empty simplified launch config reverts.**

## 7. Invariants to verify

- launched projects point at the intended controller
- stored 721 hook config exists for every ruleset created through this deployer
- sucker cash-outs always get the intended zero-tax path
- self-reference prevention holds after setup
- the project NFT ends owned by the intended owner

## 8. Accepted behaviors

### 8.1 Fresh launches validate the controller through the canonical directory

Pre-launch controller validation cannot require a current directory controller because the project may not have one
yet. The deployer still requires the provided controller to use the canonical `PROJECTS` registry, and after
`launchRulesetsFor` returns the canonical directory must record that controller for the project. A controller that
does not register itself fails the launch atomically.

### 8.2 Registered suckers receive 0% cash-out tax

This is intentional and shares the same trust boundary as the sucker registry.

Registered-sucker cash-outs also intentionally use the local chain's supply and surplus, regardless of whether ordinary
holder cash-outs for the project aggregate remote snapshots. This keeps bridge movement proportional to the funds
available on the source chain.

## 9. Accepted security risks

Documented risks that were reviewed and accepted.

### Configuration risks

**Unvalidated extra data hooks can brick live flows.** *(Minor)*
Extra data hooks provided by the project owner in `_setup721` configuration can fail and brick live pay/cash-out flows. Accepted because this is self-inflicted misconfiguration — only the project owner can set these hooks.

**Missing hook721 alias check enables double invocation.** *(Minor)*
If the project owner configures the 721 hook as both the primary hook and as an extra data hook, it could be invoked twice. Accepted because this is self-inflicted misconfiguration — the deployer correctly processes each hook independently.

### Hook selection

**ApprovalExpected rulesets excluded from hook carry-forward.**
When no new tiers are provided, the deployer carries forward the 721 hook from the most recent approved ruleset. Rulesets with `ApprovalExpected` status are intentionally excluded even though they may become active. Hook selection is irreversible — if the pending ruleset is later rejected by the approval hook, the deployer would otherwise lock in a hook from a ruleset that never became active. The deployer falls back to the current (already-approved) ruleset in this case.

### Cross-chain deployment

**`_msgSender()` in deployment salt breaks cross-chain determinism.** *(Minor)*
`deploySuckersFor` includes `_msgSender()` in the CREATE2 salt, which means the same deployment from different callers produces different addresses across chains. Accepted because this is intentional replay protection — prevents frontrunning of cross-chain deployments.
