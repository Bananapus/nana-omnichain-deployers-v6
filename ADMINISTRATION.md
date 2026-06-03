# Administration

## At a glance

| Item | Details |
| --- | --- |
| Scope | Omnichain launch orchestration and wrapper behavior |
| Control posture | Mixed deployer logic, project permissions, and registry trust |
| Highest-risk actions | Wrong hook composition, wrong sucker wiring, and bad registry trust |
| Recovery posture | Often requires redeploying or re-launching around bad wiring |

## Purpose

This repo controls how omnichain projects are launched and wrapped, not the low-level runtime logic of suckers or 721 hooks.

## Control model

- launch paths are largely permissionless for new projects
- later ruleset changes depend on project permissions
- registry and sucker trust surfaces can widen authority if misconfigured

## Recovery

- bad launch wiring usually means a new deployment path rather than a local patch

## Admin boundaries

- this repo does not override locked runtime behavior in sibling repos

