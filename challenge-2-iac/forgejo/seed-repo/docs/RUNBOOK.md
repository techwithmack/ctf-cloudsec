# On-Call Runbook — checkout-service

## Shipping a release

1. Open a PR against `main`. Requires one approval (see `CODEOWNERS`).
2. Once merged, cut a release branch from `main`: `deploy/<version>` (e.g. `deploy/2026.06.02-1`).
3. Pushing that branch triggers `deploy.yml`, which builds, pushes, and rolls the ECS service.
4. Watch the run under **Actions**. To roll back, push a `deploy/*` branch at the previous good
   commit.

## Hotfixes

Same process, just skip the wait: branch from `main`, cherry-pick the fix, push as
`deploy/hotfix-<ticket>`. Release Engineering owns sign-off on hotfix runs, but note the pipeline
itself doesn't gate on that sign-off — it triggers immediately on push, same as any other
`deploy/*` branch.

## Common issues

- **Pipeline stuck in "queued":** check the self-hosted runner is online (Settings → Actions →
  Runners). Page `#platform-eng` if it's been down more than 10 minutes.
- **Deploy secret errors:** `deploy.yml` reads `AWS_DEPLOY_ROLE_ARN` / `FLAG_SECRET_ID` /
  `AWS_REGION` from repo Action secrets — if these are missing, re-run
  `scripts/register-pipeline-secrets.sh` (platform team only).
