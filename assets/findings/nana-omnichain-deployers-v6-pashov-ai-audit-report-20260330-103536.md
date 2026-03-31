# 🔐 Security Review — nana-omnichain-deployers-v6

---

## Scope

|                                  |                                                                                                                                                                                                             |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Mode**                         | ALL / default                                                                                                                                                                                               |
| **Files reviewed**               | `script/Deploy.s.sol` · `script/helpers/DeployersDeploymentLib.sol` · `src/JBOmnichainDeployer.sol`<br>`src/structs/JBDeployerHookConfig.sol` · `src/structs/JBOmnichain721Config.sol` · `src/structs/JBSuckerDeploymentConfig.sol`<br>`src/structs/JBTiered721HookConfig.sol` |
| **Confidence threshold (1-100)** | 75                                                                                                                                                                                                          |

---

## Findings

None.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| - | - | None |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Reflexive controller validation overstates what it proves** — `JBOmnichainDeployer._validateController` — Code smells: validation is anchored to `controller.DIRECTORY()` supplied by the same controller being checked, rather than to an immutable trusted directory — This did not survive to a finding because the path does not update the canonical project rulesets or directory, so I could not complete a live exploit that changes real terminal execution. It is still worth tightening or clarifying because the current comment implies stronger authenticity guarantees than the code actually enforces.
- **`launchRulesetsFor` semantics depend on upstream “first launch only” behavior** — `JBOmnichainDeployer._launchRulesetsFor` — Code smells: the wrapper presents a generic launch entrypoint, but upstream `JBController.launchRulesetsFor` reverts once a project already has rulesets — I did not confirm a security impact, but the API/documentation boundary is easy to misuse and should remain regression-tested so integrations do not assume it can relaunch arbitrary existing projects.
- **Pay-hook composition assumes the 721 hook preserves its current return-shape invariants** — `JBOmnichainDeployer.beforePayRecordedWith` — Code smells: only `tiered721HookSpecs[0]` is consumed and `projectAmount` is clamped to zero if the returned split amount exceeds the payment amount — I could not prove an exploitable path in the current dependency set because the bundled 721 hook maintains the expected single-spec invariant. This remains a dependency-sensitive integration trail if the upstream hook contract or interface expectations ever change.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
