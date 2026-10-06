# Provisioning Team Environments — Organizer Guide

This is the operational runbook for spinning up, tearing down, and monitoring team environments
for both CTF challenges. It's written for anyone running the event day-to-day (CTF Ops/Techops),
not just whoever built the infrastructure — no Terraform experience required for the GitHub
Actions path below.

For what the challenges actually *are*, see the main [README](README.md). This doc is purely
about the mechanics of turning a `team_id` into a live environment (and back off again).

---

## How this works, in short

- One team = one isolated stack in **both** challenges, keyed by a `team_id` you choose (e.g.
  `team-06`). Nothing about a team's resources overlaps with any other team's.
- Two ways to provision: **GitHub Actions** (no AWS access needed — the recommended path for
  Ops/Techops) or **local scripts** (requires AWS credentials and Terraform installed).
- **Environments auto-expire after 1 hour.** A scheduled job checks every 5 minutes and tears down
  anything older than that. This is automatic — you don't need to remember to clean up after a
  team, but it also means a team can't be "kept alive" past an hour by leaving it running; give
  them a fresh `team_id` (or re-run provisioning for the same one) if they need more time.
- **Both challenges share one flag each** — every team sees the same answer per challenge. Flags
  are not unique per team.

---

## One-time event setup

Do this once, before the first team is provisioned. If someone already did this for the event,
skip to [Provisioning a team](#provisioning-a-team).

### 1. Each challenge's `bootstrap/` stack

Creates the shared, per-event resources every team's environment reads from (Route53 zone,
wildcard ACM cert, shared ALB, and — as of Aug 2026 — each challenge's one shared flag). Requires
AWS credentials; run once per challenge, not per team:

```bash
cd challenge-1-iac/bootstrap && terraform init && terraform apply
cd ../../challenge-2-iac/bootstrap && terraform init && terraform apply
```

### 2. `ci-bootstrap/` (only needed for the GitHub Actions path)

Creates the shared Terraform state bucket/lock table and the IAM role the workflows assume via
GitHub OIDC — no long-lived AWS keys stored anywhere in GitHub:

```bash
cd ci-bootstrap
terraform init -input=false
terraform apply -auto-approve
terraform output provisioner_role_arn
```

Then:
- Add that ARN as the repo secret `AWS_GITHUB_OIDC_ROLE_ARN` (repo **Settings → Secrets and
  variables → Actions**).
- Point both challenges at the new remote state bucket instead of local `.tfstate` files (existing
  team workspaces migrate in place — nothing is destroyed):
  ```bash
  cd challenge-1-iac && terraform init -migrate-state
  cd ../challenge-2-iac && terraform init -migrate-state
  ```
- Create a `destroy-approval` GitHub Environment (**Settings → Environments → New environment**)
  with at least one required reviewer. The destroy workflow won't run past that gate without an
  approval — this is what stops a mistyped `team_id` from taking down a live team mid-event.

Once this is done, anyone with write access to the repo can provision/destroy teams from the
Actions tab without ever touching AWS credentials directly.

---

## Provisioning a team

### Via GitHub Actions (recommended)

1. Go to the repo's **Actions** tab → **Provision team environments** → **Run workflow**.
2. Enter one or more team IDs, comma and/or newline separated (e.g. `team-06, team-07, team-08`).
3. Run it. Each team provisions as its own parallel job across both challenges, so one team's
   failure doesn't block the others.
4. Open a job's log to get that team's URLs. **Flag and password values are masked (`***`) in the
   log on purpose** — see [Reading a team's flag](#reading-a-teams-flag-or-credentials) below.

### Via local script

Requires AWS credentials and Terraform installed locally, plus both challenges' `bootstrap/`
stacks already applied:

```bash
./scripts/add-team.sh <team_id>
```

Prints the team's URL, credentials, and flag directly to your terminal (no masking — this is your
own terminal, not a shared log). Safe to re-run for an existing `team_id`: it's an idempotent
apply, not a reset — see the next section if you actually want to reset a team.

---

## Destroying a team

### Via GitHub Actions

1. **Actions** tab → **Destroy team environments** → **Run workflow** → same team ID input as
   provisioning.
2. This pauses under the `destroy-approval` environment gate — a reviewer needs to approve the run
   before anything actually gets destroyed. If it looks "stuck," that's why: someone with reviewer
   access needs to go approve it.

### Via local script

```bash
./scripts/remove-team.sh <team_id>       # prompts for confirmation
./scripts/remove-team.sh <team_id> --yes # skips the prompt (for scripting/automation)
```

Tears the team down in both challenges and deletes its Terraform workspace. A fresh
`add-team.sh`/provision run afterward gives them a brand-new environment (new passwords, new EFS
volume for Challenge 2 — but **the same flag**, since flags are shared per challenge, not
per-team).

---

## Auto-expiry (1-hour TTL)

**Reap expired team environments** runs on a schedule every 5 minutes. It doesn't rely on any
timestamp Terraform tracks — it asks AWS directly how old each team's environment actually is
(each challenge's ECS service `createdAt`) and destroys anything past 1 hour, the same way the
manual destroy workflow does. No approval gate on this one — enforcing the TTL without waiting on
a human is the entire point of it.

You can trigger a pass manually (e.g. to test it, or to force an immediate sweep): **Actions** tab
→ **Reap expired team environments** → **Run workflow**. You can optionally override the TTL in
minutes for that one run (useful for testing — e.g. set it to `1` against a throwaway team to
confirm the reaper actually catches it).

**This applies to every team workspace it finds — there's no "protected" or long-lived team
exemption.** If you provision a team you want to keep around for reference/QA purposes for longer
than an hour, you'll need to re-provision it before it gets swept, or avoid relying on the reaper
being off — it's running every 5 minutes regardless of who provisioned what.

---

## Reading a team's flag (or credentials)

Provisioning output masks flag and password values in GitHub Actions logs on purpose — Actions
logs may be visible to repo collaborators broader than "everyone who should be able to see every
team's flag." To read a specific team's actual flag or Challenge 2 player password for QA:

```bash
cd challenge-1-iac && terraform workspace select <team_id> && terraform output -raw qa_verification_flag
cd ../challenge-2-iac && terraform workspace select <team_id> && terraform output -raw qa_verification_flag
terraform output -raw player_password
```

This works against the shared remote state once `ci-bootstrap` setup is complete, no matter who
provisioned the team (locally or via Actions). Since both challenges' flags are shared per
challenge rather than per team, you only need to do this once ever per challenge, not once per
team.

---

## Troubleshooting

**Workflow fails immediately at "configure-aws-credentials."**
`AWS_GITHUB_OIDC_ROLE_ARN` isn't set, or `ci-bootstrap` hasn't been applied yet — see
[One-time event setup](#one-time-event-setup).

**`terraform init` fails / can't find remote state.**
Either `ci-bootstrap` hasn't been applied (the state bucket doesn't exist), or the
`-migrate-state` step wasn't run yet for that challenge.

**Destroy workflow just sits there.**
It's waiting on `destroy-approval` environment review — someone with reviewer access needs to
approve the run in the Actions UI.

**I ran provision twice for the same `team_id` — did that break anything?**
No. It's idempotent — Terraform only replaces resources that actually need replacing. Re-running
provisioning is the normal way to "reset" a team.

**The flag looks identical across two different teams.**
That's intentional as of Aug 2026 — the sponsor's scoring only supports one answer per challenge,
not a unique one per team. See [How this works, in short](#how-this-works-in-short).

**A team I wanted to keep got destroyed on its own after about an hour.**
Expected — see [Auto-expiry](#auto-expiry-1-hour-ttl). There's no exemption mechanism; re-provision
it if you need it to keep running.

---

## Access required

- **Provisioning/destroying via Actions:** needs write access to the repo (to trigger
  `workflow_dispatch`).
- **Approving a destroy:** needs to be listed as a required reviewer on the `destroy-approval`
  GitHub Environment (**Settings → Environments**).
- **Local scripts:** needs AWS credentials with access to the account both challenges run in, plus
  Terraform installed.
