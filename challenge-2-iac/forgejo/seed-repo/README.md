# infra

Deployment pipeline and infrastructure definitions for Meridian Systems' **checkout-service**
production environment.

## What's in here

- `.forgejo/workflows/` — CI/CD pipelines. `ci.yml` runs lint/tests on every pull request against
  `main`; `deploy.yml` builds and ships a release.
- `terraform/` — the AWS resources checkout-service runs on (ECS service, task definition, ALB
  target group).
- `docs/` — runbooks and architecture reference material.
- `scripts/` — one-off platform-team tooling. Not meant to be run in CI.

## Branching

- `main` is the source of truth. Changes land via pull request and require one approval from
  `@platform-team` (see `CODEOWNERS`).
- Release Engineering ships via short-lived `deploy/<name>` branches cut from `main` — see
  `docs/RUNBOOK.md` for the full process.

## Getting help

Ping `#platform-eng`, or see `docs/RUNBOOK.md` for the on-call playbook.
