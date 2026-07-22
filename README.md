# Cloud Village CTF - Aikido 

Two sponsor-hosted cloud security challenges for the DEFCON Cloud Village CTF. Aikido owns and
operates the infrastructure end to end on AWS (`us-west-2`), with every team getting its own
isolated set of cloud resources under one shared domain, `aikidoctf.com`.

| | Challenge 1: The Flawed Blueprint | Challenge 2: The Shadow Pipeline Overlord |
|---|---|---|
| Category | Cloud Infrastructure / Storage | CI/CD / IAM / Containers |
| Difficulty | Low | High |
| Points | 100 | 450 |
| Solve time | 20 min | 75 min |
| Directory | repo root (`main.tf`, `app/`, `docs/`) | `challenge-2-iac/` |
| Player entry point | `https://<team_id>.challenge1.aikidoctf.com` | `https://<team_id>.challenge2.aikidoctf.com` |
| Concept | Public S3 bucket policy leaks a forgotten backup file | Unprotected `deploy/*` branch lets a low-privileged CI user trigger a privileged OIDC-federated pipeline job |

Both challenges' full deliverable sets (description, hints, learning objectives, architecture
diagram, walkthrough, metadata) live under `docs/` (Challenge 1) and `challenge-2-iac/docs/`
(Challenge 2). This README is the map — it explains the architecture and team model that both
challenges share, then walks through each challenge's mechanics individually. For a deeper,
resource-by-resource technical explainer of each challenge (what gets built, why, and exactly how
the flag flows from Terraform to the player), see **[challenge1.md](challenge1.md)** and
**[challenge2.md](challenge2.md)**.

One naming note: the CI/CD challenge was called "Challenge 3" in early planning notes, but
everything that actually ships it — `metadata.yaml`, the directory name `challenge-2-iac/`, the
docs — calls it **Challenge 2**. This README follows what's actually on disk.

---

## Team structure & isolation

Every team gets a fully independent copy of a challenge's infrastructure, identified by a
`team_id` (e.g. `team-01`). Nothing about one team's environment is visible to, shared with, or
destructible by another team.

### How a team's stack is built

Each challenge's Terraform is split into two layers:

- **A shared "bootstrap" stack**, applied once for the whole event, that provisions the handful of
  things that can only exist once: the Route53 zone lookup, a wildcard ACM certificate, and one
  shared Application Load Balancer (`bootstrap/` for Challenge 1, `challenge-2-iac/bootstrap/` for
  Challenge 2). It also owns the shared container image repo (ECR) for that challenge's entry-point
  image, built once and reused by every team.
- **A per-team stack**, applied once per `team_id` via a **Terraform workspace**
  (`terraform workspace new <team_id>` in the relevant directory), that creates every resource that
  team actually plays against: S3 bucket / Forgejo instance, compute, IAM roles, secrets, and its
  own ALB routing rule + DNS record. Every resource name is suffixed with `team_id`
  (e.g. `aikido-ctf-blueprint-backup-team-01`, `shadow-pipeline-deploy-team-01`), so two teams'
  stacks never collide, never share an IAM role, and never share a data path.

The per-team stack only ever *reads* the bootstrap's shared resources (as Terraform data sources) —
it never tries to create them. That's what lets many teams' stacks apply independently without
racing each other to create the same ALB or ECR repo twice.

### Routing: one domain, one subdomain per challenge, one host per team

Both challenges are published under the same registered domain, `aikidoctf.com`, rather than raw
IPs — internal portals in the real world are never bare IPs, and it avoids the instability of
Fargate tasks having no stable address of their own. Each challenge gets its own subdomain,
wildcard-certed one level down so every team's third-level host is covered:

- Challenge 1: `<team_id>.challenge1.aikidoctf.com`
- Challenge 2: `<team_id>.challenge2.aikidoctf.com`

Teams are distinguished purely by an ALB host-header routing rule pointing at that team's own
target group — not by separate load balancers. (A wildcard cert for `*.aikidoctf.com` would **not**
cover `<team_id>.challenge1.aikidoctf.com`, since that's two levels below the apex — hence one
wildcard cert per challenge subdomain, not one at the domain root.)

### What isolation actually buys a team

- **Challenge 1:** each team gets its own S3 bucket, Fargate task, IAM execution role, security
  group, and ALB routing rule. A team can misconfigure or even delete its own bucket without
  touching any other team's.
- **Challenge 2:** each team gets its own Forgejo instance (its own SQLite DB on its own EFS
  volume, its own org/repo/player account), its own EC2 CI runner, its own IAM OIDC provider, and
  its own deploy role. The OIDC trust policy's `sub` condition is scoped to that team's own
  `repo:team-<id>/infra:ref:refs/heads/deploy/*` — so even a team that fully compromises its own
  deploy role has no path to another team's flag, since the trust policy can't be satisfied by a
  token from a different team's Forgejo issuer.
- **Secrets never cross teams:** Challenge 2's flag lives in a per-team Secrets Manager secret
  (`shadow-pipeline-flag-${team_id}`), and the runner registration token lives in a per-team SSM
  parameter (`/ctf/challenge2/${team_id}/runner-token`) — both name-scoped the same way as every
  other resource.
- **Concurrent operation:** because isolation is structural (distinct AWS resources, not shared
  mutable state), many teams run simultaneously without contention.

### Managing teams

Adding a team is the same two commands in either challenge's directory:

```bash
terraform workspace new <team_id>   # or `select` if it already exists
terraform apply \
  -var="team_id=<team_id>" \
  -var="zone_name=aikidoctf.com" \
  -var="ctf_domain=challenge{1,2}.aikidoctf.com"
```

Each per-team stack has its own Terraform state (via the workspace), so applying/destroying one
team never touches another's state or resources. Grab that team's credentials and flag from the
stack's outputs — never hardcode them anywhere:

```bash
terraform output entrypoint_url
terraform output -raw qa_verification_flag     # Challenge 1 & 2
terraform output player_username                # Challenge 2 only
terraform output -raw player_password            # Challenge 2 only
```

Tearing a team down is `terraform destroy` with the same three `-var` flags — the S3 bucket
(`force_destroy = true`) and the flag secret (`recovery_window_in_days = 0`) clean up immediately,
and a fresh `apply` afterward re-rolls that team a brand-new flag.

---

## Challenge 1: The Flawed Blueprint

*Deep technical explainer: [challenge1.md](challenge1.md) — Step-by-step solve walkthrough: [docs/walkthrough.md](docs/walkthrough.md)*

**Scenario:** Meridian Systems' platform team pushed a "quick backup" of production config to cloud storage
during a migration and never cleaned it up. An internal developer portal still references the
forgotten bucket.

**Vulnerability:** `aws_s3_bucket_public_access_block.allow_public` disables all four
public-access-block protections, and `aws_s3_bucket_policy.public_read_policy` then attaches a
policy granting `Principal: "*"` read (`s3:GetObject`) and list (`s3:ListBucket`) access — a bucket
anyone on the internet can enumerate and read, no AWS credentials required anywhere in the solve
path.

**Attack chain:**
1. Player is handed `https://<team_id>.challenge1.aikidoctf.com/`.
2. Viewing the page's HTML source reveals an HTML comment: `<!-- TODO: remove before prod - forgotten backup bucket still wired up here: {TARGET_BUCKET_URL} -->`.
3. `aws s3 ls s3://aikido-ctf-blueprint-backup-<team_id> --no-sign-request` — lists `prod_backup_config.toml`.
4. `aws s3 cp s3://.../prod_backup_config.toml . --no-sign-request` — downloads it.
5. The file contains decoy DB credentials plus `[system_canary] flag_token = "FLAG-<32hex>"`.

**File map:**

| File | Role |
|---|---|
| `bootstrap/variables.tf`, `bootstrap/main.tf` | Shared, event-wide: Route53 zone lookup, wildcard ACM cert for `*.challenge1.aikidoctf.com`, shared ALB — applied once |
| `variables.tf` | `aws_region` (fixed `us-west-2`), `team_id`, `zone_name`, `ctf_domain` |
| `main.tf` | Bucket + policy (the vuln), flag generation, ECS/Fargate entry-point hosting, ALB host-header routing + DNS record |
| `app/app.py`, `app/Dockerfile` | Entry-point Flask app leaking the bucket URL; built once, pushed to the shared ECR repo |
| `app/README.md` | One-time ECR bootstrap instructions |
| `metadata.yaml` | Submission metadata |
| `docs/challenge-description.md` | Player-facing scenario/objective |
| `docs/learning-objectives.md` | Public bucket policies, access blocks, IaC scanning |
| `docs/architecture-diagram.md` | Mermaid diagram of the flow above |
| `docs/walkthrough.md` | Full solve path, exact commands, reset procedure |
| `docs/hints.md` | 3 progressive hints |

---

## Challenge 2: The Shadow Pipeline Overlord

*Deep technical explainer: [challenge2.md](challenge2.md) — Step-by-step solve walkthrough: [challenge-2-iac/docs/walkthrough.md](challenge-2-iac/docs/walkthrough.md)*

**Scenario:** Meridian Systems' platform team runs a self-hosted Forgejo instance. Players start with a
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
| `variables.tf` | `aws_region`, `team_id`, `zone_name`, `ctf_domain`, `runner_instance_type` |
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
