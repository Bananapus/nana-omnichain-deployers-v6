# Omnichain Deployers Risk Register

This file covers the risks in the deployer layer that launches Juicebox projects across chains while composing 721 hooks, suckers, and optional custom data hooks.

## How To Use This File

- Read `Priority risks` first. They capture the highest-blast-radius deployment and cash-out assumptions.
- Treat `Invariants to verify` as required checks for any new omnichain deployment flow.

## Priority Risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Registry-trusted sucker bypass | This deployer gives suckers privileged cash-out behavior based on registry answers. A bad registry entry can affect many projects. | Registry allowlists, deployment verification, and explicit registry scrutiny. |
| P1 | Cross-chain deployment drift | Omnichain assumptions fail if chain-specific wiring, peers, or composed hooks do not match. | Deterministic deploy ordering, parity checks, and post-deploy peer verification. |
| P1 | Data-hook composition mistakes | The deployer wraps or forwards custom data hooks. A bad composition can alter pay or cash-out semantics unexpectedly. | Integration tests and careful forwarding review. |

## 1. Trust Assumptions

- **Trusted forwarder is trusted.**
- **Sucker registry answers are trusted.**
- **Controller trust matters.**
- **Extra data hooks are trusted code.**

## 2. Economic Risks

- **Sucker cashout bypass exists for registered suckers.**
- **Extra data hooks can manipulate weight or cash-out behavior.**
- **721 hook amount splitting can zero out project amount in edge cases.**
- **Cross-chain sender dependence affects deterministic sucker salts.**

## 3. Access Control

- **Wildcard `MAP_SUCKER_TOKEN` permission is broad.**
- **`launchRulesetsFor` requires combined permissions.**
- **`launchProjectFor` is intentionally permissionless for new projects.**

## 4. DoS Vectors

- **Ruleset ID collision can block queueing.**
- **External hook reverts can block pay or cash-out flows.**
- **721 hook deployment revert blocks launch.**
- **Non-safe NFT transfers can still strand assets.**

## 5. Reentrancy Surface

- **`launchProjectFor` makes several external calls in sequence.**
- **`beforePayRecordedWith` delegates to external hooks.**
- **`beforeCashOutRecordedWith` delegates to external hooks.**
- **There is no `ReentrancyGuard`.** The deployer relies on being effectively stateless during pay and cash-out operations.

## 6. Integration Risks

- **Hook config is keyed by predicted ruleset ID.**
- **Carried-forward 721 hook behavior on queue depends on prior ruleset state.**
- **ERC721Receiver restrictions are narrow but non-safe transfers can still strand assets.**
- **Empty simplified launch config reverts.**

## 7. Invariants To Verify

- launched projects point at the intended controller
- stored 721 hook config exists for every ruleset created through this deployer
- sucker cashouts always get the intended zero-tax path
- self-reference prevention holds after setup
- the project NFT ends owned by the intended owner

## 8. Accepted Behaviors

### 8.1 Controller validation is skipped during initial launch

Pre-launch controller validation is impossible because the project does not yet exist. The accepted safeguard is the post-launch project ID match check.

### 8.2 Registered suckers receive 0% cashout tax

This is intentional and shares the same trust boundary as the sucker registry.
