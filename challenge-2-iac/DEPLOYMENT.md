# Challenge 2 — Deployment Runbook

Operator-facing setup guide for "The Shadow Pipeline Overlord." For the player-facing solve path
see `docs/walkthrough.md`; for image build-only instructions see `forgejo/README.md`.

## 0. Prerequisites

- AWS credentials configured (`aws sts get-caller-identity` works), same account/region
  (`us-west-2`) as Challenge 1.
- Docker Desktop running (needed once, to build the Forgejo image).
- Terraform >= 1.0.
- **A domain you control.** This deployment uses `aikidoctf.com`, registered directly through
  Route53 Registrar in this same AWS account (so its hosted zone already exists — no delegation
  step needed). Every team's Forgejo instance is published at `<team_id>.challenge2.aikidoctf.com`,
  and AWS IAM's OIDC federation needs a stable, ongoing-reachable public HTTPS hostname for each
  team — this is not optional infrastructure, it's load-bearing for the challenge's core mechanic.

## 1. Domain & DNS

Two variables control this, kept separate on purpose:

- `zone_name` — the Route53 zone that **actually exists** (`aikidoctf.com`). Used only to look up
  the zone via `data "aws_route53_zone"`.
- `ctf_domain` — the challenge-level subdomain the wildcard cert and every per-team record are
  scoped to (`challenge2.aikidoctf.com`). A wildcard cert for `*.aikidoctf.com` would **not** cover
  `<team_id>.challenge2.aikidoctf.com` (that's two levels down), so `ctf_domain` must be one level
  below the apex.

**Default path — the zone already exists (this deployment's actual setup):** set
`create_route53_zone = false` (the default) and just pass both variables. No delegation, no NS
records, nothing to wait on — records for `challenge2.aikidoctf.com` land straight in the
`aikidoctf.com` zone.

**Alternative, if you're deploying against a domain whose zone doesn't exist yet in this account:**
set `-var="create_route53_zone=true"` and `zone_name` = the new zone's name. After apply, run
`terraform output nameservers` and set those as the domain's nameservers at your registrar (or add
an NS delegation record at the parent if `zone_name` itself is a subdomain of something you manage
elsewhere). DNS propagation can take minutes to a few hours — do this early if you're on a deadline.

## 2. Apply the bootstrap stack (once, shared across all teams)

```bash
cd challenge-2-iac/bootstrap
terraform init
terraform apply -var="zone_name=aikidoctf.com" -var="ctf_domain=challenge2.aikidoctf.com"
```

This creates: the Route53 zone (only if `create_route53_zone=true`), a wildcard ACM cert
(`*.challenge2.aikidoctf.com`, DNS-validated automatically since the zone is in this account), a
shared ALB with an HTTPS listener, and the shared ECR repo for the Forgejo image. Takes a few
minutes — ACM DNS validation and the ALB provisioning are the slow parts.

## 3. Build and push the Forgejo image (once)

Follow `forgejo/README.md` exactly — in short:

```bash
aws ecr get-login-password --region us-west-2 \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-west-2.amazonaws.com

docker buildx build --platform linux/amd64 \
  -t <account-id>.dkr.ecr.us-west-2.amazonaws.com/shadow-pipeline-forgejo:latest \
  --push challenge-2-iac/forgejo/
```

(`--platform linux/amd64` matters even if you're not on Apple Silicon — it's just good hygiene,
since the ECS task definition expects amd64 and there's no `runtime_platform` override.)

## 4. Apply a team stack

```bash
cd challenge-2-iac
terraform init
terraform apply -var="team_id=<team>" -var="zone_name=aikidoctf.com" -var="ctf_domain=challenge2.aikidoctf.com"
```

This takes longer than Challenge 1's apply — an EFS mount target and the ALB listener rule/target
group both need to settle, and the Forgejo Fargate task needs to boot, run `bootstrap.sh`
(provisioning the org/repo/player/branch-protection/workflow/runner-token), and pass its ALB
health check before the EC2 runner can successfully register (the runner's user-data polls SSM for
up to ~10 minutes waiting for that token). Expect low-single-digit minutes end-to-end, not seconds.

Grab the outputs:

```bash
terraform output entrypoint_url      # hand this to the team
terraform output player_username     # "player"
terraform output player_password     # sensitive - terraform output -raw player_password
```

## 5. Verify before handing off to a team

1. `curl -sI https://<team_id>.challenge2.aikidoctf.com/` — expect a `200` once DNS has propagated
   and the ALB target is healthy.
2. Log into Forgejo with the `player` credentials, confirm the one `infra` repo is visible with
   Write access.
3. Check **Settings → Branches** on that repo — `main` should show a protection rule, `deploy/*`
   should not.
4. Check the repo's **Actions → Runners** (or `GET
   /api/v1/repos/<org>/infra/actions/runners` as the admin) — the EC2 instance should show up as a
   registered, idle runner. If it doesn't, check the EC2 instance's own boot logs
   (`journalctl -u forgejo-runner` over SSM Session Manager — the instance profile includes
   `AmazonSSMManagedInstanceCore` specifically for this) before assuming something's broken in
   Terraform.
5. Do one real solve-path pass yourself, following `docs/walkthrough.md`, and confirm the flag you
   read from the job log matches `terraform output -raw qa_verification_flag`.

## 6. Scaling to multiple teams

Repeat step 4 once per team (`-var="team_id=<team>"`), all against the same bootstrap stack from
step 2 — you only do steps 2–3 once, ever, regardless of team count.

**Important:** as written, every team's `terraform apply` runs against the *same* local state file
in `challenge-2-iac/`. Running two teams' applies from one directory will conflict. Before scaling
past one or two teams, either use a separate `terraform workspace` per team, or a separate state
key (e.g. an S3 backend with `-backend-config="key=team-<id>/terraform.tfstate"`) per team — same
caveat as Challenge 1, just more consequential here given the heavier per-team resource count.

## 7. Teardown

Per team:

```bash
cd challenge-2-iac
terraform destroy -var="team_id=<team>" -var="zone_name=aikidoctf.com" -var="ctf_domain=challenge2.aikidoctf.com"
```

Whole event, once all teams are torn down:

```bash
cd challenge-2-iac/bootstrap
terraform destroy -var="zone_name=aikidoctf.com" -var="ctf_domain=challenge2.aikidoctf.com"
```

(Only do this once no per-team stack still references the shared ALB/zone/ECR repo — destroying
bootstrap first would break every still-running team.)
