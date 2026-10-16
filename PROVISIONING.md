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
- **Environments auto-expire after roughly 1-2 hours.** A scheduled job checks hourly and tears
  down anything past the 1-hour TTL, so a team can live up to ~2 hours worst case (expires right
  after a check, caught by the next one). This is automatic, so you don't need to remember to
  clean up after a team, but it also means a team can't be kept alive indefinitely by leaving it
  running. Give them a fresh `team_id` (or re-run provisioning for the same one) if they need more
  time. (Originally checked every 5 minutes - found on 2026-10-14 that GitHub silently throttles a
  cron that frequent on a public repo to 3-9 hour real gaps, so this moved to the hourly cadence
  GitHub actually honors reliably. See reap-teams.yml's own comment for the detail.)
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

### 3. `CTF_PLAYER_PASSWORD` repo variable (optional shared-password override; currently UNSET)

**Leave this unset to keep per-team random passwords (the DEF CON behavior, our decision as of
2026-10-16).** Full explanation, history and live verification: **[PLAYER_PASSWORDS.md](PLAYER_PASSWORDS.md)**.

Optional. A self-service bridge (Cloud Village's CTFd → GitHub Actions Lambda) dispatches
`provision-teams.yml` but never reads its logs (flag/password values are masked there on purpose),
so it has no way to receive a generated Challenge 2 password. If **Settings → Secrets and
variables → Actions → Variables → `CTF_PLAYER_PASSWORD`** is set (min 12 characters), every team's
Forgejo `player` account gets that one password, and the CTFd challenge text tells players what it
is. Unset = a per-team random password, as before (read it via
[Reading a team's flag](#reading-a-teams-flag-or-credentials)).

Because the password is shared, the team URL (`<team_id>.challenge2.aikidolabs.net`) is the only
thing separating teams, so the bridge should use unguessable `team_id`s. Change the value for each
event (it isn't a secret from players, but it shouldn't be last event's). See
**[BRIDGE_INTEGRATION.md](BRIDGE_INTEGRATION.md)** for the full bridge contract.

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

## Auto-expiry (1-hour TTL, checked hourly)

**Reap expired team environments** runs on a schedule hourly (was every 5 minutes until
2026-10-14 - GitHub silently throttles a cron that frequent on a public repo to 3-9 hour real
gaps between runs, so this moved to the cadence GitHub actually honors). It doesn't rely on any
timestamp Terraform tracks. It asks AWS directly how old each team's environment actually is
(each challenge's ECS service `createdAt`) and destroys anything past 1 hour, the same way the
manual destroy workflow does. No approval gate on this one: enforcing the TTL without waiting on a
human is the entire point. Because the check itself only runs hourly, actual lifetime is "1 hour
past expiry, caught by the next hourly check" - up to ~2 hours worst case, not a strict 60-minute
cutoff.

You can trigger a pass manually (e.g. to test it, or to force an immediate sweep): **Actions** tab
→ **Reap expired team environments** → **Run workflow**. You can optionally override the TTL in
minutes for that one run (useful for testing, e.g. set it to `1` against a throwaway team to
confirm the reaper actually catches it).

**This applies to every team workspace it finds. There's no "protected" or long-lived team
exemption.** If you provision a team you want to keep around for reference/QA purposes for longer
than an hour, re-provision it before it gets swept, or don't rely on the reaper being off. It runs
hourly regardless of who provisioned what.

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

## AWS account safety (before the event)

The account was frozen by AWS during DEF CON 34. Cause unconfirmed; Challenge 2's runner (player
code on EC2 with open egress) and Challenge 1's deliberately public bucket are the likeliest
triggers. Before BSides:

- Open a proactive AWS Support case describing the event (CTF, intentionally public S3 bucket,
  player-run code on EC2, dates) and confirm the account's contacts and billing details are
  current so a notice reaches a person.
- Set an AWS Budget with alerts well below the account's tolerance, and watch GuardDuty findings
  for the event window.
- The runner already blocks job containers from the instance metadata service (see
  `metadata_options` in `challenge-2-iac/main.tf`). Restricting its egress further is possible but
  the deploy job legitimately needs `apt` mirrors and `awscli.amazonaws.com`, so test any
  allowlist with `tests/local/challenge2.sh` and one real provision before relying on it.

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

**Every team's Challenge 2 password is the same.**
Only expected if `CTF_PLAYER_PASSWORD` is set (it should normally be unset; check
`gh variable list`). See
[CTF_PLAYER_PASSWORD](#3-ctf_player_password-repo-variable-only-for-self-service-provisioning).

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
