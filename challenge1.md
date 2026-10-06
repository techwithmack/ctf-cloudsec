# Challenge 1: The Flawed Blueprint — How It Actually Works

This is the internal technical explainer for how the challenge is built and how the flag flows
from Terraform to the player. For the player-facing writeup, hints, and grading metadata, see
`challenge-1-iac/docs/`. This file is about the mechanics underneath.

## The one-sentence version

Terraform stands up a small "internal developer portal" web app per team, whose only job is to
leak the name of an S3 bucket in an HTML comment; that bucket has a public-read policy attached to
it, so anyone who finds the bucket name can pull down a file containing the flag — no AWS
credentials required anywhere in the solve path.

## Per-team isolation model

Every resource name in `challenge-1-iac/main.tf` is suffixed with `var.team_id` (e.g.
`aikido-ctf-blueprint-backup-${var.team_id}`, `aikido-ctf-cluster-${var.team_id}`). That means this
whole `main.tf` is a **template applied once per team**, via its own Terraform workspace:

```bash
cd challenge-1-iac
terraform workspace new team007   # or `select` if it already exists
terraform apply \
  -var="team_id=team007" \
  -var="zone_name=aikidoctf.com" \
  -var="ctf_domain=challenge1.aikidoctf.com"
```

Each invocation creates a fully independent set of resources for that team — its own bucket, its
own ECS cluster/service/task, its own IAM role, its own security group, its own ALB routing rule
and DNS record. Teams cannot see or affect each other's resources; the only things shared across
all teams are read-only lookups against the event-wide `challenge-1-iac/bootstrap/` stack (the
ALB, the ACM cert, the Route53 zone) and the container **image** sitting in ECR — none of which
any team's stack ever creates itself.

## What gets built, and why

### 1. The vulnerable S3 bucket (`aws_s3_bucket.leaky_bucket`)

- `aws_s3_bucket_public_access_block.allow_public` explicitly disables all four public-access-block
  protections (`block_public_acls`, `block_public_policy`, `ignore_public_acls`,
  `restrict_public_buckets`). This step exists purely so the next resource is even allowed to take
  effect — by default S3 blocks a policy like the one below.
- `aws_s3_bucket_policy.public_read_policy` then attaches a policy with `Principal: "*"` and
  `Action: s3:GetObject`/`s3:ListBucket`, i.e. anyone on the internet can list and read any object
  in the bucket without signing their request. This is **the actual vulnerability** the challenge
  is testing — everything else in the stack exists only to get a player to this bucket's name.

### 2. The flag (`random_id.flag_hex`, `local.generated_flag`, `aws_s3_object.backup_file`)

- `random_id.flag_hex` generates 16 random bytes (32 hex characters) at `apply` time.
- `local.generated_flag` formats it as `FLAG-<32hex>`, matching the required flag format.
- `aws_s3_object.backup_file` uploads `prod_backup_config.toml` into the bucket — a fake "forgotten
  backup" containing plausible decoy content (a fake DB host/credentials) plus a
  `[system_canary] flag_token = "..."` line holding the real flag. The decoy content exists so the
  flag isn't the *only* thing in the file — a player has to actually read the file rather than
  pattern-match on "the only string in here."
- `output "qa_verification_flag"` exposes the flag to whoever runs `terraform apply`/`terraform
  output` locally (marked `sensitive` so it doesn't print in plain CI logs), purely for your own QA
  — players never see this output, since players never get Terraform access.
- **Resetting a team** (`terraform destroy` + `apply` again) generates a brand-new `random_id`, so
  the old flag stops working the moment the stack is destroyed.

### 3. The entry-point app (`challenge-1-iac/app/app.py`, `challenge-1-iac/app/Dockerfile`, run via ECS Fargate)

- The Flask app has exactly one route (`/`). It reads two environment variables —
  `TEAM_ID` and `TARGET_BUCKET_URL` — that the ECS task definition injects per team, and renders a
  static "internal developer portal" page containing:
  ```html
  <!-- TODO: remove before prod - forgotten backup bucket still wired up here: {TARGET_BUCKET_URL} -->
  ```
  That HTML comment is the **entire enumeration step** of the challenge — there is no scanning,
  brute-forcing, or guessing involved. A player just has to think to check page source (`curl` or
  browser view-source) instead of only looking at the rendered page.
- The image is built and pushed to a **single shared ECR repository**
  (`aikido-ctf-flawed-blueprint`) once, out-of-band, before any team deploys — see
  `challenge-1-iac/app/README.md`. `main.tf` looks this repository up via `data
  "aws_ecr_repository"` (read-only), not a resource, specifically because a `resource` would try to
  *create* the repo again on every team's separate `apply` and fail with "already exists" starting
  from the second team.
- `aws_ecs_task_definition.entrypoint_task` wires up the container: pulls the shared image, exposes
  port 80, and injects `TEAM_ID` / the team's actual bucket URL
  (`aws_s3_bucket.leaky_bucket.bucket_regional_domain_name`) as environment variables — so the same
  image works correctly for every team without ever being rebuilt per team.
- `aws_ecs_service.entrypoint_service` runs exactly one Fargate task per team, in the default VPC.
  Its security group (`aws_security_group.container_sg`) only allows inbound traffic from the
  shared ALB's security group — the task itself is never directly internet-reachable.

### 4. Getting players a URL to hit: the shared ALB, not a raw task IP

A Fargate task running under an ECS *service* has no Terraform-native "give me its IP" attribute —
the task's network interface is assigned dynamically by ECS after the service is created. An
earlier version of this challenge worked around that with a `local-exec` provisioner that polled
the AWS CLI for the task's public IP; that approach is gone now in favor of routing every team
through one shared Application Load Balancer, the same pattern Challenge 2 already used:

- A separate, event-wide **`challenge-1-iac/bootstrap/`** stack (applied once, before any team)
  provisions: a Route53 zone lookup for `aikidoctf.com`, a wildcard ACM cert for
  `*.challenge1.aikidoctf.com`, and one shared ALB (`flawed-blueprint-alb`) with an HTTPS listener.
- Each team's own `main.tf` looks all of that up read-only (`data "aws_lb"`, `data
  "aws_lb_listener"`, `data "aws_route53_zone"`, `data "aws_security_group"`) and adds only:
  - its own target group (`aws_lb_target_group.app`), which the ECS service registers into via its
    `load_balancer` block — so ECS automatically keeps the target group pointed at whichever task
    is currently running, even across task replacements;
  - its own host-header listener rule (`aws_lb_listener_rule.app`) matching
    `<team_id>.challenge1.aikidoctf.com`, with no `priority` set — AWS assigns the next free
    priority on the shared listener at apply time, so independent teams' applies never collide;
  - its own Route53 alias record (`aws_route53_record.app`) pointing that hostname at the shared
    ALB.
- `output "entrypoint_url"` is now just `"https://${var.team_id}.${var.ctf_domain}"` — a plain
  string, not something Terraform has to poll AWS to discover. It's stable across task restarts:
  if the underlying Fargate task ever gets replaced, ECS re-registers the new task's IP with the
  same target group automatically, and the team's URL/DNS record never change.

**Operational note:** this means Challenge 1 depends on `challenge-1-iac/bootstrap/` having been
applied first (same as Challenge 2) — see the root `README.md`'s "Team isolation" section for the
shared-vs-per-team split in more detail.

## The full attack chain, end to end

```
1. Player is handed https://<team_id>.challenge1.aikidoctf.com/  (the entrypoint_url output)
2. Player requests it, and either views the rendered page or its HTML source
3. The HTML comment reveals: https://aikido-ctf-blueprint-backup-<team_id>.s3.us-west-2.amazonaws.com
4. Player runs: aws s3 ls s3://aikido-ctf-blueprint-backup-<team_id> --no-sign-request
   -> lists prod_backup_config.toml (no AWS account/credentials needed — the bucket policy allows anyone)
5. Player runs: aws s3 cp s3://.../prod_backup_config.toml . --no-sign-request
6. Player opens the file, finds flag_token = "FLAG-<32hex>" under [system_canary]
7. Player submits the flag
```

No exploit, no zero-day, no brute force — purely enumeration (view source → list bucket →
download → read), which is exactly what a "Low" difficulty, 20-minute challenge calls for.

## File map

| File | Role |
|---|---|
| `challenge-1-iac/bootstrap/variables.tf`, `challenge-1-iac/bootstrap/main.tf` | Shared, event-wide: Route53 zone lookup, wildcard ACM cert for `*.challenge1.aikidoctf.com`, shared ALB — applied once |
| `challenge-1-iac/variables.tf` | `aws_region` (fixed to `us-west-2`), `team_id`, `zone_name`, `ctf_domain` |
| `challenge-1-iac/main.tf` | Bucket + policy (the vuln), flag generation, ECS/Fargate app hosting, ALB target group/listener rule, DNS record |
| `challenge-1-iac/app/app.py` | The entry-point Flask app that leaks the bucket URL |
| `challenge-1-iac/app/Dockerfile` | Builds the app into the image referenced by the ECS task |
| `challenge-1-iac/app/README.md` | One-time ECR bootstrap instructions (build/push before any team deploys) |
| `challenge-1-iac/metadata.yaml` | Submission metadata (name, category, difficulty, flag format, tags, etc.) |
| `challenge-1-iac/docs/challenge-description.md` | Player-facing scenario/objective |
| `challenge-1-iac/docs/learning-objectives.md` | Educational takeaways (public bucket policies, access blocks, IaC scanning) |
| `challenge-1-iac/docs/architecture-diagram.md` | Mermaid diagram of the flow above |
| `challenge-1-iac/docs/walkthrough.md` | Full solve path with exact commands, reset procedure, known shortcuts |
| `challenge-1-iac/docs/hints.md` | 3 progressive hints |
