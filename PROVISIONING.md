# Provisioning Team Environments: Organizer Guide

This is the operational runbook for spinning up, tearing down, and monitoring team environments
for both CTF challenges. Written for anyone running the event day-to-day (CTF Ops/Techops), not
just whoever built the infrastructure. No Terraform experience required for the GitHub Actions
path below.

For what the challenges actually *are*, see the main [README](README.md). This doc covers the
mechanics of turning a `team_id` into a live environment, and back off again.

---

## How this works, in short

- One team = one isolated stack in **both** challenges, keyed by a `team_id` you choose (e.g.
  `team-06`). No team's resources overlap with any other team's.
- Two ways to provision: **GitHub Actions** (no AWS access needed, the recommended path for
  Ops/Techops) or **local scripts** (requires AWS credentials and Terraform installed).
- **Environments auto-expire after 1 hour.** A scheduled job checks every 5 minutes and tears down
  anything older than that. This is automatic, so you don't need to remember to clean up after a
  team, but it also means a team can't be kept alive past an hour by leaving it running. Give them
  a fresh `team_id` (or re-run provisioning for the same one) if they need more time.
- **Both challenges share one flag each.** Every team sees the same answer per challenge. Flags
  are not unique per team.

---

## One-time event setup

Do this once, before the first team is provisioned. If someone already did this for the event,
skip to [Provisioning a team](#provisioning-a-team).

### 1. Each challenge's `bootstrap/` stack

Creates the shared, per-event resources every team's environment reads from (Route53 zone,
wildcard ACM cert, shared ALB, and, as of Aug 2026, each challenge's one shared flag). Requires
AWS credentials. Run once per challenge, not per team:

```bash
cd challenge-1-iac/bootstrap && terraform init && terraform apply
cd ../../challenge-2-iac/bootstrap && terraform init && terraform apply
```

### 2. `ci-bootstrap/` (only needed for the GitHub Actions path)

Creates the shared Terraform state bucket/lock table and the IAM role the workflows assume via
GitHub OIDC. No long-lived AWS keys stored anywhere in GitHub:

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
  team workspaces migrate in place, nothing is destroyed):
  ```bash
  cd challenge-1-iac && terraform init -migrate-state
  cd ../challenge-2-iac && terraform init -migrate-state
  ```
- Create a `destroy-approval` GitHub Environment (**Settings → Environments → New environment**)
  with at least one required reviewer. The destroy workflow won't run past that gate without an
  approval. This is what stops a mistyped `team_id` from taking down a live team mid-event.

Once this is done, anyone with write access to the repo can provision/destroy teams from the
Actions tab without touching AWS credentials directly.

### 3. `CTF_BRIDGE_WEBHOOK_URL` / `CTF_BRIDGE_WEBHOOK_SECRET` (only for self-service provisioning)

Optional. If set, `provision-teams.yml`'s "Notify bridge" step POSTs each provisioned team's URLs
and Challenge 2 credentials (never the flag) to `CTF_BRIDGE_WEBHOOK_URL` as JSON, signed with
`CTF_BRIDGE_WEBHOOK_SECRET` via `X-Signature-256: sha256=<hmac-sha256 hex>`, the same convention
GitHub uses for webhook signing. This lets an external self-service bridge (e.g. a CTFd
integration that dispatches this workflow on a player's behalf) receive results without scraping
Actions logs, which are partially masked on purpose (see `scripts/add-team.sh`). Leave both unset
to keep this workflow purely organizer-triggered. The step skips cleanly when
`CTF_BRIDGE_WEBHOOK_URL` is empty.

`CTF_BRIDGE_WEBHOOK_SECRET` is already set as of 2026-09-29. `CTF_BRIDGE_WEBHOOK_URL` is **not set
yet**. The notify step will keep skipping cleanly (silently, by design) until it is. See
**[BRIDGE_INTEGRATION.md](BRIDGE_INTEGRATION.md)** for the full contract with Cloud Village's
bridge, including the requirements around token scope and identity-to-`team_id` binding. Read that
before enabling self-service for real, not just this section.

### 4. `ORGANIZER_GITHUB_LOGINS` repo variable (organizer allowlist)

A comma-separated list of GitHub usernames allowed to manually dispatch `destroy-teams.yml` or
`reap-teams.yml` (**Settings → Secrets and variables → Actions → Variables**). Any other actor
attempting a manual dispatch of either, including a self-service bridge's token (which only needs
"Actions: write" to dispatch *any* workflow in this repo, not just `provision-teams.yml`), is
rejected before any AWS credentials are touched. Currently set to `techwithmack` only.

**This is deliberately not "every repo collaborator."** `maxdotdotg` is a repo collaborator (Write
access, needed so its PAT can dispatch `provision-teams.yml` at all) but is Jayesh/Cloud Village's
self-service bridge identity: exactly the actor this allowlist exists to keep out of destroy/reap.
Having repo access and being an organizer trusted to manually destroy teams are two different
things. Don't collapse them back into one list when updating this later.

The scheduled reaper run (cron) is never affected by this. It has no "actor" to check and must
never be blocked. Update this variable if the *organizer* roster changes, not the collaborator
roster. No code change needed.

---

## Provisioning a team

### Via GitHub Actions (recommended)

1. Go to the repo's **Actions** tab → **Provision team environments** → **Run workflow**.
2. Enter one or more team IDs, comma and/or newline separated (e.g. `team-06, team-07, team-08`).
3. Run it. Each team provisions as its own parallel job across both challenges, so one team's
   failure doesn't block the others.
4. Open a job's log to get that team's URLs. **Flag and password values are masked (`***`) in the
   log on purpose.** See [Reading a team's flag](#reading-a-teams-flag-or-credentials) below.

### Via local script

Requires AWS credentials and Terraform installed locally, plus both challenges' `bootstrap/`
stacks already applied:

```bash
./scripts/add-team.sh <team_id>
```

Prints the team's URL, credentials, and flag directly to your terminal (no masking, since this is
your own terminal, not a shared log). Safe to re-run for an existing `team_id`: it's an idempotent
apply, not a reset. See the next section if you actually want to reset a team.

---

## Destroying a team

### Via GitHub Actions

1. **Actions** tab → **Destroy team environments** → **Run workflow** → same team ID input as
   provisioning.
2. This pauses under the `destroy-approval` environment gate. A reviewer needs to approve the run
   before anything actually gets destroyed. If it looks "stuck," that's why: someone with reviewer
   access needs to approve it.

### Via local script

```bash
./scripts/remove-team.sh <team_id>       # prompts for confirmation
./scripts/remove-team.sh <team_id> --yes # skips the prompt (for scripting/automation)
```

Tears the team down in both challenges and deletes its Terraform workspace. A fresh
`add-team.sh`/provision run afterward gives them a brand-new environment (new passwords, new EFS
volume for Challenge 2, but **the same flag**, since flags are shared per challenge, not per-team).

---

## Auto-expiry (1-hour TTL)

**Reap expired team environments** runs on a schedule every 5 minutes. It doesn't rely on any
timestamp Terraform tracks. It asks AWS directly how old each team's environment actually is
(each challenge's ECS service `createdAt`) and destroys anything past 1 hour, the same way the
manual destroy workflow does. No approval gate on this one: enforcing the TTL without waiting on a
human is the entire point.

You can trigger a pass manually (e.g. to test it, or to force an immediate sweep): **Actions** tab
→ **Reap expired team environments** → **Run workflow**. You can optionally override the TTL in
minutes for that one run (useful for testing, e.g. set it to `1` against a throwaway team to
confirm the reaper actually catches it).

**This applies to every team workspace it finds. There's no "protected" or long-lived team
exemption.** If you provision a team you want to keep around for reference/QA purposes for longer
than an hour, re-provision it before it gets swept, or don't rely on the reaper being off. It runs
every 5 minutes regardless of who provisioned what.

---

## Reading a team's flag (or credentials)

Provisioning output masks flag and password values in GitHub Actions logs on purpose. Actions
logs may be visible to repo collaborators broader than everyone who should see every team's flag.
To read a specific team's actual flag or Challenge 2 player password for QA:

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
`AWS_GITHUB_OIDC_ROLE_ARN` isn't set, or `ci-bootstrap` hasn't been applied yet. See
[One-time event setup](#one-time-event-setup).

**`terraform init` fails / can't find remote state.**
Either `ci-bootstrap` hasn't been applied (the state bucket doesn't exist), or the
`-migrate-state` step wasn't run yet for that challenge.

**Destroy workflow just sits there.**
It's waiting on `destroy-approval` environment review. Someone with reviewer access needs to
approve the run in the Actions UI.

**Destroy or reap workflow fails instantly with "Manual dispatch of this workflow is restricted
to organizers."**
The account that dispatched it isn't on the `ORGANIZER_GITHUB_LOGINS` repo variable. This is
intentional; see [ORGANIZER_GITHUB_LOGINS](#4-organizer_github_logins-repo-variable-organizer-allowlist)
above. Add the account to that variable if it should be able to trigger these, or use one of the
accounts already listed there.

**Provision workflow fails instantly with "Refusing to provision N teams in one dispatch."**
More than 20 `team_ids` were sent in a single dispatch. This is a deliberate cap (see
`provision-teams.yml`'s `prepare` job). Split into multiple dispatches, or ask Mackenzie to raise
the cap if a legitimate use case needs it regularly.

**A team's Challenge 2 password came back identical after re-requesting through the bridge.**
Expected, and important for anyone building on top of self-service to know. See
[BRIDGE_INTEGRATION.md](BRIDGE_INTEGRATION.md#2-identity-to-team_id-binding--this-is-the-important-one).
Re-provisioning an existing `team_id` is a plain Terraform re-apply, not a reset. It doesn't
rotate `random_password.player`.

**I ran provision twice for the same `team_id`. Did that break anything?**
No. It's idempotent: Terraform only replaces resources that actually need replacing. Re-running
provisioning is the normal way to reset a team.

**The flag looks identical across two different teams.**
Intentional as of Aug 2026: the sponsor's scoring only supports one answer per challenge, not a
unique one per team. See [How this works, in short](#how-this-works-in-short).

**A team I wanted to keep got destroyed on its own after about an hour.**
Expected. See [Auto-expiry](#auto-expiry-1-hour-ttl). There's no exemption mechanism; re-provision
it if you need it to keep running.

---

## Access required

- **Provisioning/destroying via Actions:** needs write access to the repo (to trigger
  `workflow_dispatch`).
- **Manually dispatching destroy or reap:** additionally needs to be on the
  `ORGANIZER_GITHUB_LOGINS` repo variable. See
  [ORGANIZER_GITHUB_LOGINS](#4-organizer_github_logins-repo-variable-organizer-allowlist) above.
  Repo admins can still push directly to `main` past branch protection in an emergency
  (`enforce_admins: false`), but this allowlist applies regardless of admin status.
- **Approving a destroy:** needs to be listed as a required reviewer on the `destroy-approval`
  GitHub Environment (**Settings → Environments**).
- **Merging to `main`:** needs one approving review from another collaborator (branch protection,
  added 2026-09-29). Repo admins can bypass in an emergency, non-admins cannot.
- **Local scripts:** needs AWS credentials with access to the account both challenges run in, plus
  Terraform installed.
