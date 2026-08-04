# Cloud Village CTF — Aikido

Two sponsor-hosted cloud security challenges for DEFCON Cloud Village. AWS `us-west-2`, one
isolated environment per team under `aikidoctf.com`.

| | Challenge 1: The Flawed Blueprint | Challenge 2: The Shadow Pipeline Overlord |
|---|---|---|
| Category | Cloud Infrastructure / Storage | CI/CD / IAM / Containers |
| Difficulty | Low | High |
| Points | 100 | 450 |
| Solve time | 20 min | 75 min |
| Directory | `challenge-1-iac/` | `challenge-2-iac/` |
| Entry point | `https://<team_id>.challenge1.aikidoctf.com` | `https://<team_id>.challenge2.aikidoctf.com` |
| Concept | Public S3 bucket leaks a forgotten backup file | Unprotected `deploy/*` branch triggers a privileged OIDC pipeline |

Full deliverables (description, hints, learning objectives, architecture diagram, walkthrough,
metadata) live under each challenge's `docs/` folder. Deep technical explainers:
[challenge1.md](challenge1.md), [challenge2.md](challenge2.md).

---

## Team isolation

Each team gets a fully isolated stack, keyed by `team_id`. Every resource (bucket/Forgejo
instance, compute, IAM roles, secrets) is name-suffixed per team, so teams never collide or affect
each other.

Both challenges share one **bootstrap stack** (applied once per event — Route53 zone, wildcard
ACM cert, shared ALB, shared container image) and a **per-team stack** (applied once per team via
a Terraform workspace) that only reads the bootstrap's resources, never creates them. Teams are
routed via ALB host-header rules (`<team_id>.challenge1.aikidoctf.com` /
`<team_id>.challenge2.aikidoctf.com`), not separate load balancers.

### Managing teams (local)

```bash
./scripts/add-team.sh <team_id>
```

Provisions (or re-applies) both challenges for that team and prints its URLs, credentials, and
flag. Safe to re-run for an existing team_id. Requires both challenges' `bootstrap/` stacks to
already be applied (once per event, not per team).

```bash
./scripts/remove-team.sh <team_id>
```

Tears a team down in both challenges and deletes its Terraform workspace. Prompts for
confirmation unless run with `--yes`. A fresh `add-team.sh` afterward gives them a new flag.

### Managing teams from GitHub Actions

Both scripts above also run as GitHub Actions workflows, so organizers can spin up (or tear down)
any number of teams' environments without a local AWS/Terraform setup.

**One-time setup** (once per event, before the first workflow run):

1. Apply the CI bootstrap stack — creates the shared Terraform state bucket/lock table and the
   IAM role the workflows assume via GitHub OIDC (no long-lived AWS keys involved):
   ```bash
   cd ci-bootstrap
   terraform init -input=false
   terraform apply -auto-approve
   terraform output provisioner_role_arn
   ```
2. Add that ARN as a repo secret named `AWS_GITHUB_OIDC_ROLE_ARN` (Settings → Secrets and
   variables → Actions).
3. Point both challenges at the new remote state bucket instead of local `.tfstate` files (one
   time; existing `default` and `team-*` workspaces migrate in place, nothing is destroyed):
   ```bash
   cd challenge-1-iac && terraform init -migrate-state
   cd ../challenge-2-iac && terraform init -migrate-state
   ```
4. Create a `destroy-approval` GitHub Environment (Settings → Environments → New environment)
   and add at least one required reviewer. The destroy workflow won't run past that gate without
   an approval, so a mistyped `team_id` can't accidentally tear down a live team mid-event.

**Provisioning teams:** Actions → *Provision team environments* → Run workflow → enter one or
more team IDs (comma and/or newline separated, e.g. `team-06, team-07, team-08`). Each team
provisions as its own parallel job in both challenges.

**Destroying teams:** Actions → *Destroy team environments* → Run workflow → same team ID input.
Waits for a reviewer to approve the `destroy-approval` environment before anything is destroyed.

Flag and player-password values are masked (`***`) in the workflow logs on purpose — these are
the CTF's actual secrets, and Actions logs may be visible to repo collaborators who aren't
supposed to see them. To read a specific team's flag for QA, pull it directly from the now-shared
remote state instead:
```bash
cd challenge-1-iac && terraform workspace select <team_id> && terraform output -raw qa_verification_flag
```

**Environments auto-expire after 1 hour.** Since provisioning is self-serve, nothing else would
otherwise tear a team down. *Reap expired team environments* runs every 5 minutes (Actions →
that workflow → Run workflow if you want to trigger a pass manually), checks each active team's
actual AWS-reported start time, and destroys anything past the limit the same way the manual
destroy workflow does — no approval gate, since enforcing the TTL unattended is the point.

**Flags are one per challenge, not one per team** — each challenge's `bootstrap/` stack generates
a single flag for the whole event; every team's per-team stack just reads it. Re-running
`add-team.sh`/the provision workflow for different teams never changes the answer.

---

## Challenge 1: The Flawed Blueprint

*[Deep dive](challenge1.md) · [Walkthrough](challenge-1-iac/docs/walkthrough.md)*

**Scenario:** Meridian Systems left a "quick backup" of production config in a public S3 bucket,
leaked via an internal developer portal.

**Attack chain:**
1. Player gets `https://<team_id>.challenge1.aikidoctf.com/`.
2. Page source contains an HTML comment leaking the bucket URL.
3. `aws s3 ls s3://aikido-ctf-blueprint-backup-<team_id> --no-sign-request`
4. `aws s3 cp s3://.../prod_backup_config.toml . --no-sign-request`
5. Flag is in `[system_canary] flag_token`.

No AWS credentials needed anywhere in the solve path.

---

## Challenge 2: The Shadow Pipeline Overlord

*[Deep dive](challenge2.md) · [Walkthrough](challenge-2-iac/docs/walkthrough.md)*

**Scenario:** Meridian Systems runs a self-hosted Forgejo instance. Players get Write access to
one repo (`infra`) whose deploy pipeline assumes an AWS IAM role via OIDC — no static credentials
anywhere in the CI system.

**Attack chain:**
1. Log in as `player`, clone `infra`.
2. `main` is branch-protected; `deploy/*` is not.
3. Push to a `deploy/*` branch — triggers the deploy pipeline on the team's CI runner.
4. The job assumes the deploy role via OIDC and prints the flag secret to its own log.
5. Player reads the flag from the job log.

The OIDC trust policy is correctly scoped — the bug is purely in branch-protection coverage, not
IAM.
