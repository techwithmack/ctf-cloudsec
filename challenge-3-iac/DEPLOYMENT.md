# Challenge 3 — Deployment Runbook

Operator-facing setup guide for "The Shadow Pipeline Overlord." For the player-facing solve path
see `docs/walkthrough.md`; for image build-only instructions see `forgejo/README.md`.

## 0. Prerequisites

- AWS credentials configured (`aws sts get-caller-identity` works), same account/region
  (`us-west-2`) as Challenge 1.
- Docker Desktop running (needed once, to build the Forgejo image).
- Terraform >= 1.0.
- **A domain you control**, or are willing to register, dedicated to this challenge (e.g.
  `ctf-shadow-pipeline.<yourtld>`). Every team's Forgejo instance is published at
  `<team_id>.<that domain>`, and AWS IAM's OIDC federation needs a stable, ongoing-reachable public
  HTTPS hostname for each team — this is not optional infrastructure, it's load-bearing for the
  challenge's core mechanic.

## 1. Domain & DNS

**Recommended default: delegate a dedicated subdomain, don't touch the domain's main DNS.**
This works no matter where the domain is registered or where its DNS currently lives (Route53,
GoDaddy, Cloudflare, Namecheap, whatever) — you're only ever adding one NS delegation record at
the parent, nothing else about the domain changes, and if anything about the CTF DNS breaks, only
that one subdomain is affected.

1. Pick a subdomain, e.g. `ctf.yourdomain.com`. Use that as `ctf_domain` everywhere below (it's
   what `variables.tf` calls `ctf_domain` — it does **not** need to be a bare top-level domain).
2. Apply bootstrap with the default `create_route53_zone = true`:
   ```bash
   cd challenge-3-iac/bootstrap
   terraform init
   terraform apply -var="ctf_domain=ctf.yourdomain.com"
   ```
   This creates a **new Route53 hosted zone scoped to just that subdomain** and outputs its 4
   nameservers.
3. Get those nameservers:
   ```bash
   terraform output nameservers
   ```
4. Go to wherever `yourdomain.com`'s DNS is managed today (your registrar's DNS panel, or Route53
   if it's already there, or Cloudflare, etc.) and add **one NS record**:
   - Name: `ctf` (some UIs want the full `ctf.yourdomain.com` — either way, it's the subdomain, not
     the apex)
   - Type: `NS`
   - Values: the 4 nameserver hostnames from step 3
5. Wait for propagation — usually minutes, sometimes a couple hours depending on the parent zone's
   own NS record TTL. Verify with:
   ```bash
   dig NS ctf.yourdomain.com
   ```
   once it resolves to the 4 Route53 nameservers, you're done — no further DNS action needed. ACM
   cert validation and every team's `<team_id>.ctf.yourdomain.com` record happen automatically
   inside that delegated zone from here on.

**Alternative, if `yourdomain.com`'s DNS is already hosted in Route53 in this same AWS account**
and you'd rather not create a separate delegated zone: set `-var="create_route53_zone=false"` and
use the existing zone's name directly as `ctf_domain`. This skips the delegation step (steps 3–5
above), but every record this challenge creates lands directly in your main zone instead of an
isolated one — the subdomain-delegation path above is preferable unless you have a specific reason
not to.

## 2. Apply the bootstrap stack (once, shared across all teams)

```bash
cd challenge-3-iac/bootstrap
terraform init
terraform apply -var="ctf_domain=<your-domain>"
```

This creates: the Route53 zone (if new), a wildcard ACM cert (`*.<your-domain>`, DNS-validated
automatically since Terraform owns the zone), a shared ALB with an HTTPS listener, and the shared
ECR repo for the Forgejo image. Takes a few minutes — ACM DNS validation and the ALB provisioning
are the slow parts.

**If you registered a brand-new domain (path A):** after apply, run:

```bash
terraform output nameservers
```

and set those as the domain's nameservers at your registrar. DNS propagation can take anywhere
from minutes to a few hours — do this early if you're on a deadline.

## 3. Build and push the Forgejo image (once)

Follow `forgejo/README.md` exactly — in short:

```bash
aws ecr get-login-password --region us-west-2 \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-west-2.amazonaws.com

docker buildx build --platform linux/amd64 \
  -t <account-id>.dkr.ecr.us-west-2.amazonaws.com/shadow-pipeline-forgejo:latest \
  --push challenge-3-iac/forgejo/
```

(`--platform linux/amd64` matters even if you're not on Apple Silicon — it's just good hygiene,
since the ECS task definition expects amd64 and there's no `runtime_platform` override.)

## 4. Apply a team stack

```bash
cd challenge-3-iac
terraform init
terraform apply -var="team_id=<team>" -var="ctf_domain=<your-domain>"
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

1. `curl -sI https://<team_id>.<your-domain>/` — expect a `200` once DNS has propagated and the
   ALB target is healthy.
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
in `challenge-3-iac/`. Running two teams' applies from one directory will conflict. Before scaling
past one or two teams, either use a separate `terraform workspace` per team, or a separate state
key (e.g. an S3 backend with `-backend-config="key=team-<id>/terraform.tfstate"`) per team — same
caveat as Challenge 1, just more consequential here given the heavier per-team resource count.

## 7. Teardown

Per team:

```bash
cd challenge-3-iac
terraform destroy -var="team_id=<team>" -var="ctf_domain=<your-domain>"
```

Whole event, once all teams are torn down:

```bash
cd challenge-3-iac/bootstrap
terraform destroy -var="ctf_domain=<your-domain>"
```

(Only do this once no per-team stack still references the shared ALB/zone/ECR repo — destroying
bootstrap first would break every still-running team.)
