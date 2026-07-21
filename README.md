# Cloud Village CTF — Sponsor Challenges (Aikido Security)

Two sponsor-hosted cloud security challenges built for the DEFCON Cloud Village CTF. Both are
"Sponsor Hosted" (Aikido owns and operates the infrastructure), deployed on AWS in `us-west-2`
(`us-east-1` is off-limits per the sponsor requirements), and use strict per-team resource
isolation so that one team's actions can never affect another's.

| | Challenge 1: The Flawed Blueprint | Challenge 2: The Shadow Pipeline Overlord |
|---|---|---|
| Category | Cloud Infrastructure / Storage | CI/CD / IAM / Containers |
| Difficulty | Low | High |
| Points | 100 | 450 |
| Solve time | 20 min | 75 min |
| Directory | repo root (`main.tf`, `app/`, `docs/`) | `challenge-2-iac/` |
| Concept | Public S3 bucket policy leaks a forgotten backup file | Unprotected `deploy/*` branch lets a low-privileged CI user trigger a privileged OIDC-federated pipeline job |

Both challenges' full deliverable sets (description, hints, learning objectives, architecture
diagram, walkthrough, metadata) already exist on disk — this README ties them together and
explains the mechanics that make per-team isolation actually hold up. It doesn't replace the
per-challenge docs; treat this as the map.

---

## Conformance to the sponsor requirements

Cross-checked against `instructions/Requirements - Sponsor's CTF Challenges (1).pdf`:

| Requirement | How it's met |
|---|---|
| Hosting model | Both "Sponsor Hosted" — Aikido owns and operates the Terraform-managed AWS infrastructure end to end. |
| Region restriction | `aws_region` defaults to `us-west-2` in both stacks; `us-east-1` never appears anywhere in the Terraform. |
| Flag format | Both generate `FLAG-${random_id.flag_hex.hex}` with `byte_length = 16` → exactly 32 hex chars, matching `FLAG-{32hexadecimal/alphanumeric}`. |
| Multi-tenancy / player isolation | `player_isolation: true` in both `metadata.yaml`; enforced structurally via the `team_id`-per-stack pattern (see below), not just declared. |
| Realistic attack path, no zero-day, no guessing | Challenge 1: enumerate → find a genuinely public bucket → read a file. Challenge 2: a real branch-protection gap under a real (correctly-configured) OIDC trust policy — no fuzzing, no brute force. |
| IaC required (Terraform, Dockerfiles, container images) | Both present: root/`challenge-2-iac` Terraform, `app/Dockerfile` / `challenge-2-iac/forgejo/Dockerfile`, images pushed to per-challenge ECR repos. |
| Required deliverables (description, entry point, IaC, Dockerfiles, images, architecture diagram, walkthrough, hints, learning objectives, YAML metadata) | All present per challenge under `docs/` and `challenge-2-iac/docs/` respectively — see the file maps below. |
| Hints: progressive, don't reveal the flag, pre-written | 3 hints per challenge, each escalating without stating the flag (`docs/hints.md`, `challenge-2-iac/docs/hints.md`). |
| YAML metadata fields (name, category, difficulty, points, entrypoint, flag_format, estimated_solve_time, expected_steps, tags, player_isolation, deployment_type, hint_count) | Both `metadata.yaml` files carry every field, including `expected_steps` (3 and 4 respectively). |
| Walkthrough must cover enumeration, commands, outputs, solve path, flag retrieval, tooling, unintended paths, reset procedure, rate-limiting | Covered in both `docs/walkthrough.md` files — including reset (`terraform destroy && apply` re-rolls the flag) and known operational caveats (Challenge 1's public-IP staleness on task restart; Challenge 2's shared-state-file caveat when scaling to multiple teams). |
| Legal/safety restrictions | No outbound attacks on third parties, no crypto mining, no cross-team blast radius — the deploy role in Challenge 2 is scoped to read exactly one Secrets Manager secret, nothing account-wide. |

One naming note worth flagging: the CI/CD challenge is called "Challenge 3" in this repo's
`CLAUDE.md` planning notes, but every deliverable that actually ships it (`metadata.yaml`,
`docs/challenge-description.md`, the directory name `challenge-2-iac/`) calls it **Challenge 2**.
This README follows what's actually on disk and in the metadata.

---

## The isolation mechanism (how it actually works)

Both challenges use the same two-tier pattern to satisfy "safe multi-tenant operation": a small
set of resources that must exist exactly once, shared read-only by every team, and a much larger
set of resources that get created fresh, per team, from a Terraform stack parameterized entirely
by a `team_id` variable.

### The rule: name everything with `team_id`, create nothing shared

Every resource that a team's stack *creates* — S3 bucket, ECS cluster/service/task, IAM role,
security group, EFS volume, Secrets Manager secret, IAM OIDC provider, EC2 instance — has
`team_id` baked into its name (e.g. `aikido-ctf-blueprint-backup-${var.team_id}`,
`shadow-pipeline-deploy-${var.team_id}`). Two teams running `terraform apply -var="team_id=<x>"`
independently therefore never collide on a resource name, never share an IAM role, and never share
a data path. Tearing down one team (`terraform destroy -var="team_id=<x>"`) only touches that
team's suffixed resources.

### The exception: resources that must exist exactly once

A small number of things genuinely cannot be created per-team without every team's apply racing to
create the same object twice (a container image repo, a domain's DNS zone, a load balancer). Both
challenges solve this the same way — provision that shared piece **once, out-of-band**, and have
every per-team stack reference it as a **read-only data source**, never as a `resource`:

- **Challenge 1:** one shared ECR repo (`aikido-ctf-flawed-blueprint`), built and pushed once (see
  `app/README.md`), looked up via `data "aws_ecr_repository"`. The same container image runs for
  every team — it's generic, and gets team-specific behavior purely from environment variables
  (`TEAM_ID`, `TARGET_BUCKET_URL`) injected by that team's ECS task definition.
- **Challenge 2:** a whole shared "bootstrap" stack (`challenge-2-iac/bootstrap/`), applied once
  for the entire event, before any team's stack: the Route53 zone for the CTF domain, a wildcard
  ACM cert (`*.<ctf_domain>`), one shared ALB with an HTTPS listener, and the shared ECR repo for
  the Forgejo image. Every per-team apply (`challenge-2-iac/main.tf`) looks all four up read-only
  (`data "aws_lb"`, `data "aws_route53_zone"`, `data "aws_ecr_repository"`, etc.) and adds only its
  own host-header listener rule (`<team_id>.<ctf_domain>` → that team's target group) and DNS
  record — teams are distinguished by ALB routing rule, not by separate load balancers.

This is exactly the same reasoning in both challenges, stated explicitly in the Terraform
comments: a per-team-applied stack can safely *reference* a shared object, but if it tried to
*create* that object as a `resource`, every team after the first would fail with "already exists."

### What "isolated" actually buys a team, concretely

- **Challenge 1:** each team gets its own bucket, its own Fargate task, its own IAM execution role,
  its own security group. A team can misconfigure or even delete its own bucket without touching
  any other team's.
- **Challenge 2:** each team gets its own Forgejo instance (own SQLite DB on its own EFS volume, own
  org/repo/player account), its own EC2 CI runner, its own IAM OIDC provider, and its own deploy
  role. Critically, the OIDC trust policy's `sub` condition is scoped to that team's own
  `repo:team-<id>/infra:ref:refs/heads/deploy/*` — so even if a team fully compromises its own
  deploy role, the trust policy structurally cannot be satisfied by a token from a *different*
  team's Forgejo issuer (a different OIDC provider ARN, a different `sub` claim). One team pwning
  its own pipeline has no path to another team's flag.
- **Per-team secrets never cross teams:** Challenge 2's flag lives in a per-team Secrets Manager
  secret (`shadow-pipeline-flag-${team_id}`), and the runner registration token lives in a per-team
  SSM parameter path (`/ctf/challenge2/${team_id}/runner-token`) — both name-scoped the same way as
  every other resource.
- **Concurrent operation:** because isolation is structural (distinct AWS resources, not shared
  mutable state), many teams can run simultaneously without contention — satisfying the sponsor's
  "concurrent users + operational stability under load" requirement.

### The one operational sharp edge: Terraform state

Both challenges' per-team Terraform runs against a **single local state file** in their directory
(`main.tf` at repo root; `challenge-2-iac/main.tf`). The isolation of the *AWS resources* is solid
regardless, but running two teams' `terraform apply` from the same local state file at the same
time will conflict with each other at the Terraform level (lock contention / stale state), even
though the actual infrastructure they produce is safely separated. Both `DEPLOYMENT.md`-equivalent
docs call this out and recommend a `terraform workspace` per team, or a distinct state key (e.g. an
S3 backend with `-backend-config="key=team-<id>/terraform.tfstate"`) once scaling past one or two
teams at once.

---

## Challenge 1: The Flawed Blueprint

**Scenario:** Aikido's platform team pushed a "quick backup" of production config to cloud storage
during a migration and never cleaned it up. An internal developer portal still references the
forgotten bucket.

**Vulnerability:** `aws_s3_bucket_public_access_block.allow_public` disables all four
public-access-block protections, and `aws_s3_bucket_policy.public_read_policy` then attaches a
policy granting `Principal: "*"` read (`s3:GetObject`) and list (`s3:ListBucket`) access — a bucket
anyone on the internet can enumerate and read, no AWS credentials required anywhere in the solve
path.

**Attack chain:**
1. Player is handed `http://<team-public-ip>/`.
2. Viewing the page's HTML source reveals an HTML comment: `<!-- TODO: remove before prod - forgotten backup bucket still wired up here: {TARGET_BUCKET_URL} -->`.
3. `aws s3 ls s3://aikido-ctf-blueprint-backup-<team_id> --no-sign-request` — lists `prod_backup_config.toml`.
4. `aws s3 cp s3://.../prod_backup_config.toml . --no-sign-request` — downloads it.
5. The file contains decoy DB credentials plus `[system_canary] flag_token = "FLAG-<32hex>"`.

**File map:**

| File | Role |
|---|---|
| `variables.tf` | `aws_region` (fixed `us-west-2`), `team_id` |
| `main.tf` | Bucket + policy (the vuln), flag generation, ECS/Fargate entry-point hosting, public-IP fetch workaround |
| `app/app.py`, `app/Dockerfile` | Entry-point Flask app leaking the bucket URL; built once, pushed to the shared ECR repo |
| `app/README.md` | One-time ECR bootstrap instructions |
| `metadata.yaml` | Submission metadata |
| `docs/challenge-description.md` | Player-facing scenario/objective |
| `docs/learning-objectives.md` | Public bucket policies, access blocks, IaC scanning |
| `docs/architecture-diagram.md` | Mermaid diagram of the flow above |
| `docs/walkthrough.md` | Full solve path, exact commands, reset procedure |
| `docs/hints.md` | 3 progressive hints |
| `challenge1.md` (gitignored) | Internal technical explainer of the mechanics — not a submission deliverable |

---

## Challenge 2: The Shadow Pipeline Overlord

**Scenario:** Aikido's platform team runs a self-hosted Forgejo instance. Players start with a
low-privileged `player` account holding **Write** access to exactly one repo (`infra`), which holds
a deploy pipeline that assumes an AWS IAM role via OIDC — no static AWS credentials exist anywhere
in the CI system.

**Vulnerability:** `forgejo/bootstrap.sh` applies branch protection to `main` only; `deploy/*` is
deliberately left unprotected. The deploy workflow (`deploy-workflow.yml`) triggers on any push to
`deploy/**` and, once running, exchanges a Forgejo-issued OIDC token for AWS credentials via
`sts:AssumeRoleWithWebIdentity`. The IAM trust policy itself is correctly scoped (`sub` matches
`repo:team-<id>/infra:ref:refs/heads/deploy/*`) — the bug is entirely in Forgejo's branch
protection completeness, not in AWS IAM. A player with Write access can push a branch matching that
pattern, get the deploy workflow to run with their commit, and read the flag straight out of the
job's log output (the workflow prints the Secrets Manager value to stdout as its "deployment sync"
step).

**Attack chain:**
1. Log in as `player` (given credentials) to the team's Forgejo instance.
2. Push directly to a branch matching `deploy/*` (e.g. `deploy/pwn`) — `main` is protected, `deploy/*` is not.
3. The push triggers `deploy-workflow.yml` on the team's dedicated EC2 CI runner.
4. The job requests an OIDC ID token from Forgejo and calls `sts assume-role-with-web-identity` against the team's `deploy-<team_id>` role.
5. The job calls `secretsmanager get-secret-value` for `shadow-pipeline-flag-<team_id>` and prints it.
6. Player reads the flag from the job's log in the Actions tab.

**File map:**

| File | Role |
|---|---|
| `bootstrap/main.tf`, `bootstrap/variables.tf` | Shared, event-wide: Route53 zone, wildcard ACM cert, shared ALB, shared ECR repo — applied once |
| `variables.tf` | `aws_region`, `team_id`, `ctf_domain`, `runner_instance_type` |
| `main.tf` | Per-team stack: Forgejo (ECS Fargate + EFS), CI runner (EC2), IAM OIDC provider + deploy role (correctly scoped), the flag secret, ALB host-header routing |
| `forgejo/Dockerfile`, `forgejo/bootstrap.sh` | Custom Forgejo image; bootstrap script provisions org/repo/player/branch-protection/workflow/runner-token idempotently on first boot |
| `forgejo/deploy-workflow.yml` | The pre-committed pipeline the runner executes |
| `runner/user_data.sh.tftpl` | EC2 user-data that registers the runner against Forgejo using the token from SSM |
| `DEPLOYMENT.md` | Operator runbook: domain/DNS setup, bootstrap apply, per-team apply, verification steps, teardown |
| `metadata.yaml` | Submission metadata |
| `docs/challenge-description.md` | Player-facing scenario/objective |
| `docs/learning-objectives.md` | OIDC trust boundaries, branch-protection completeness, CI log exfiltration, least privilege, runner-host isolation |
| `docs/architecture-diagram.md` | Mermaid diagram of bootstrap vs. per-team resources and the full attack chain |
| `docs/walkthrough.md` | Full solve path, exact commands, reset procedure |
| `docs/hints.md` | 3 progressive hints |
