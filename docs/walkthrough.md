# Solution Walkthrough — Challenge 1: The Flawed Blueprint

## Required Tooling

- `curl` (or any browser) — to view the entry-point page source
- AWS CLI v2 — `aws s3 ls` / `aws s3 cp`, both used **unauthenticated** via `--no-sign-request`
- No AWS account or credentials are required to solve this challenge

## 1. Enumerate the Entry Point

Navigate to the entry point URL given to your team (the `entrypoint_url` Terraform output, e.g.
`https://<team_id>.challenge1.aikidoctf.com`).

```bash
curl -s https://<team_id>.challenge1.aikidoctf.com/
```

Expected output — an HTML page for an "Aikido Internal Developer Portal," including an HTML
comment:

```html
<!-- TODO: remove before prod - forgotten backup bucket still wired up here: https://aikido-ctf-blueprint-backup-<team_id>.s3.us-west-2.amazonaws.com -->
```

**Solve path explanation:** the comment is the intended discovery vector. Viewing page source (or
`curl`, or browser dev tools) is the only enumeration step required to find the bucket name — this
mirrors how forgotten debug/config artifacts leak in real internal tools.

## 2. List the Bucket Contents

Extract the bucket name from the leaked URL and list it without any AWS credentials, since the
bucket policy grants public read:

```bash
aws s3 ls s3://aikido-ctf-blueprint-backup-<team_id> --no-sign-request
```

Expected output:

```
2026-07-20 12:00:00        512 prod_backup_config.toml
```

## 3. Download the Backup File

```bash
aws s3 cp s3://aikido-ctf-blueprint-backup-<team_id>/prod_backup_config.toml . --no-sign-request
cat prod_backup_config.toml
```

Expected output includes a `[system_canary]` section:

```toml
[system_canary]
# TODO: Remove this debug token before pushing to production configuration
flag_token = "FLAG-<32 hex characters>"
```

## 4. Flag Retrieval

Submit the value of `flag_token`, e.g. `FLAG-4f7d9a2c5e8b1f347ab82de14a0cc912`, matching the
required `FLAG-{32hexadecimal}` format.

## Known Unintended Solve Paths

- **Bucket name guessing.** The bucket naming pattern (`aikido-ctf-blueprint-backup-<team_id>`) is
  predictable once a player has their own `team_id` (e.g., from the portal's welcome text or their
  scoreboard). A player could in principle skip viewing the entry point entirely and probe the
  bucket name directly. This is a known, low-impact shortcut (it still requires the player to
  correctly guess the exact prefix and their own team_id) and is not considered a break — it still
  demonstrates the same core lesson (unauthenticated public bucket enumeration). No fix planned;
  documented here per QA requirements.

## Reset Procedures

Each team's infrastructure is an independent Terraform stack keyed by `team_id`, applied against
the shared `bootstrap/` stack (Route53 zone lookup, wildcard ACM cert, shared ALB — applied once
for the whole event). To reset a team's environment:

```bash
terraform destroy -var="team_id=<team_id>" -var="aws_region=us-west-2" -var="zone_name=aikidoctf.com" -var="ctf_domain=challenge1.aikidoctf.com"
terraform apply   -var="team_id=<team_id>" -var="aws_region=us-west-2" -var="zone_name=aikidoctf.com" -var="ctf_domain=challenge1.aikidoctf.com"
```

- The S3 bucket has `force_destroy = true`, so `terraform destroy` cleans it up (including the
  backup object) without manual emptying.
- A fresh `apply` generates a **new** `random_id`-based flag, so a reset team gets a new flag value
  — old flags stop working immediately after destroy.

## Stability & Rate Limiting Concerns

- Each team runs a single Fargate task (no autoscaling) — sufficient for one team's traffic at
  low-difficulty scale, but not designed for load beyond a handful of concurrent requests per team.
- The entry point is fronted by a shared ALB (`bootstrap/main.tf`), with each team distinguished by
  a host-header listener rule (`<team_id>.challenge1.aikidoctf.com`) and its own target group —
  not by a raw task IP. If the underlying Fargate task restarts for any reason, ECS re-registers
  the replacement task's new IP with the same target group automatically; `entrypoint_url` never
  goes stale, unlike the earlier raw-public-IP approach.
- `aws s3 ls` / `aws s3 cp --no-sign-request` are unauthenticated and subject to standard S3
  request-rate behavior; no additional rate limiting is configured or expected to be needed at this
  challenge's traffic scale.
