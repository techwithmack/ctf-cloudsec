# Solution Walkthrough — Challenge 2: The Shadow Pipeline Overlord

## Required Tooling

- `git`
- A web browser (or `curl`) to view the Forgejo web UI/Actions job logs
- No AWS credentials or CLI are required by the player at any point

## 1. Log In and Enumerate

Navigate to the team's Forgejo URL (`https://<team_id>.challenge2.aikidoctf.com`) and log in with
the provided `player` credentials. The account has Write access to exactly one repository:
`<org>/infra`.

Clone it:

```bash
git clone https://player:<password>@<team_id>.challenge2.aikidoctf.com/team-<team_id>/infra.git
cd infra
```

Inspect `.forgejo/workflows/deploy.yml` on `main` — it triggers on push to `deploy/**`, requests
an OIDC ID token (`enable-openid-connect: true`), exchanges it for an AWS role, and reads a secret.
The role ARN and secret ID are referenced as `${{ secrets.* }}` — not visible to the player
directly, but the workflow's *behavior* is fully visible.

## 2. Discover the Branch Protection Gap

A Write-level collaborator (the player's actual access level) cannot view **Settings → Branches**
or call `GET /api/v1/repos/<org>/infra/branch_protections` — both require Admin permission on the
repo, which the player does not have. The gap has to be discovered empirically, by testing what
the server actually allows:

```bash
git commit --allow-empty -m "test"
git push origin main
# rejected: "Not allowed to push to protected branch main"

git checkout -b deploy/pwn
git push origin deploy/pwn
# succeeds - deploy/* is not covered by any protection rule
```

## 3. Craft the Malicious Pipeline Run

Modify the workflow on your `deploy/pwn` branch so the job's output actually reveals something
useful — the stock workflow already prints the flag secret to its own log, so simply pushing the
existing (unmodified) workflow content on a `deploy/*` branch is enough to trigger a real run.
(A more adversarial variant might redirect output elsewhere, or read additional resources — the
point being demonstrated is that *any* content on this branch runs with the pipeline's privilege.)

```bash
git push origin deploy/pwn
```

## 4. Read the Job Log

Forgejo schedules the run on the team's CI runner. Watch it under the repo's **Actions** tab (or
`GET /api/v1/repos/<org>/infra/actions/tasks` via the API). The job:

1. Requests an OIDC ID token from Forgejo (`ACTIONS_ID_TOKEN_REQUEST_URL`/`_TOKEN`)
2. Exchanges it via `sts:AssumeRoleWithWebIdentity` — permitted, because the ref
   (`refs/heads/deploy/pwn`) matches the trust policy's `refs/heads/deploy/*` condition
3. Calls `aws secretsmanager get-secret-value` for the flag secret and prints it

Since the player triggered this run themselves, they can view its full log output directly in the
Forgejo Actions UI — no separate exfiltration channel is needed.

## 5. Flag Retrieval

Read the flag (`FLAG-{32 hex}`) from the job's log output and submit it.

## Known Unintended Solve Paths

- **Guessing the branch protection gap without enumeration.** A player who assumes "the pattern
  the workflow triggers on is probably unprotected" and jumps straight to pushing a `deploy/*`
  branch without checking `Settings → Branches` first will still solve it — this is a minor
  shortcut, not a break, since it still requires understanding *why* that branch matters.

## Reset Procedures

Each team's Forgejo instance persists its data on an EFS volume, so restarting the ECS task alone
does **not** reset anything (branch pushes, the runner registration, etc. survive). To fully reset
a team:

```bash
cd challenge-2-iac
terraform destroy -var="team_id=<team_id>" -var="zone_name=aikidoctf.com" -var="ctf_domain=challenge2.aikidoctf.com"
terraform apply   -var="team_id=<team_id>" -var="zone_name=aikidoctf.com" -var="ctf_domain=challenge2.aikidoctf.com"
```

- `aws_secretsmanager_secret.flag` has `recovery_window_in_days = 0`, so destroy fully removes the
  old flag immediately (no 7-30 day recovery window blocking a same-name recreate).
- A fresh `apply` generates a new flag, new Forgejo admin/player passwords, and a fresh EFS volume
  — the old team's git history, runner registration, and flag are all gone.

## Stability & Rate Limiting Concerns

- One CI runner (EC2) and one Forgejo task (Fargate) per team — sufficient for one team's single
  in-flight pipeline run, not designed for concurrent runs at scale.
- The EC2 runner depends on the Forgejo task having already published its registration token to
  SSM Parameter Store; the runner's own boot script retries for up to ~10 minutes before giving up.
  If a team reports the repo shows no runner as available, check whether the Forgejo task's
  `bootstrap.sh` completed (CloudWatch logs for the `forgejo` container) before assuming the EC2
  runner itself is broken.
- No additional rate limiting is configured; a single team's Forgejo instance/runner is not
  expected to see load beyond one player's manual pushes and job triggers.
