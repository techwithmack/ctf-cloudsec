# Challenge 2: The Shadow Pipeline Overlord — How It Actually Works

This is the internal technical explainer for how the challenge is built and how the flag flows
from Terraform to the player. For the player-facing writeup, hints, and grading metadata, see
`challenge-2-iac/docs/`. This file is about the mechanics underneath.

## The one-sentence version

Terraform stands up a self-hosted Forgejo instance per team with a low-privileged `player` account
that has Write access to one repo whose CI pipeline can assume a real AWS IAM role via OIDC; the
repo's branch protection covers `main` but not `deploy/*`, so a player who notices that gap can
trigger the privileged pipeline themselves and read the flag straight out of its job log — no
static AWS credentials exist anywhere in the system for a player to steal in the first place.

## Per-team isolation model

Every resource name in `challenge-2-iac/main.tf` is suffixed with `var.team_id` (e.g.
`shadow-pipeline-cluster-${var.team_id}`, `shadow-pipeline-deploy-${var.team_id}`). Like Challenge
1, this whole file is a **template applied once per team**, via its own Terraform workspace:

```bash
cd challenge-2-iac
terraform workspace new team007   # or `select` if it already exists
terraform apply \
  -var="team_id=team007" \
  -var="zone_name=aikidoctf.com" \
  -var="ctf_domain=challenge2.aikidoctf.com"
```

Each invocation creates a fully independent Forgejo instance, EFS volume, EC2 CI runner, IAM OIDC
provider, deploy role, and flag secret for that team. The only things shared across all teams are
read-only lookups against the event-wide `challenge-2-iac/bootstrap/` stack (the ALB, the ACM cert,
the Route53 zone, the Forgejo container image) — no team's stack ever creates any of those itself.

## What gets built, and why

### 1. Forgejo itself (ECS Fargate + EFS)

- `aws_ecs_task_definition.forgejo` runs the custom Forgejo image (see below) on Fargate, with
  `platform_version = "1.4.0"` specifically because EFS volume support on Fargate requires it.
- `aws_efs_file_system.forgejo_data` (+ one mount target per subnet) gives Forgejo's SQLite
  database, repo contents, and Actions state somewhere to persist. Without this, replacing the
  Fargate task (a deploy, a health-check failure) would silently wipe the team's entire git
  history and any branch they'd already pushed mid-solve.
- `aws_security_group.forgejo_sg` only allows inbound `3000` from the shared ALB's security group
  — Forgejo is never directly internet-reachable, exactly like Challenge 1's entry-point app.
- Two separate IAM roles exist for the same task, deliberately kept apart:
  - `ecs_execution_role` — the standard ECS plumbing role (pull the image, write logs).
  - `forgejo_task` — the *container's own* runtime identity, scoped to exactly one action:
    `ssm:PutParameter` on this team's own runner-token parameter. It has no other AWS permission at
    all, so even if Forgejo itself were somehow compromised from outside, that identity alone
    grants nothing interesting.

### 2. `forgejo/bootstrap.sh` — provisioning Forgejo's contents on first boot

This script is the container's actual entrypoint. It starts the real Forgejo process in the
background, waits for its API to respond, and then idempotently provisions everything the
challenge needs by calling Forgejo's own REST API as a freshly-created admin account:

1. Creates the admin account (`gitea admin user create`, since the CLI must run as Forgejo's own
   `git` user rather than root).
2. Creates an org (`team-<team_id>`) and one repo inside it (`infra`).
3. Creates the **low-privileged `player` account** — this is the identity the team actually
   receives — and adds it as a **Write** collaborator on `infra`. Write, not Admin: the player can
   push branches and see workflow *behavior*, but cannot view or change branch protection settings
   (`GET .../branch_protections` requires Admin) — the gap has to be found empirically, not read
   off a settings page.
4. Commits the pre-written deploy workflow (`.forgejo/workflows/deploy.yml`, see below) to `main`.
5. Applies branch protection to **`main` only** (`enable_push: false`) — `deploy/*` is deliberately
   never touched by any protection rule. **This is the entire vulnerability.** The OIDC trust
   policy on the AWS side (below) is correctly scoped; the bug is purely that Forgejo's branch
   protection doesn't cover every ref pattern the CI trusts.
6. Sets three repo-level Action secrets (`AWS_DEPLOY_ROLE_ARN`, `FLAG_SECRET_ID`, `AWS_REGION`) that
   the workflow reads at runtime — not visible to the player via the API, but the workflow's
   *behavior* (what it does with them) is fully visible since the player can read the workflow file
   they just cloned.
7. Mints a repo-scoped CI runner registration token and writes it to this team's own SSM parameter
   (`/ctf/challenge2/${team_id}/runner-token`), which the EC2 runner (below) is waiting to read.

Every step tolerates its own "already provisioned" response (a different status code per endpoint,
verified against a real Forgejo instance — 422 for org/user/workflow conflicts, 409 for repo
conflicts, 403 for branch-protection conflicts) rather than treating it as fatal. That's not just
cosmetic idempotency: if the container crashes partway through a first boot, ECS replaces it with a
fresh container that reruns the whole script from step 1 — without this tolerance, the very first
already-applied step would exit non-zero and crash every subsequent container too, forever, in a
real crash loop found by live testing. A marker file (`/data/.ctf-bootstrap-done` on the EFS
volume) skips the whole provisioning block on any later restart once it has succeeded once.

### 3. The deploy workflow (`forgejo/deploy-workflow.yml`)

Triggers on `push: branches: [deploy/**]`. With `enable-openid-connect: true`, the job gets
`ACTIONS_ID_TOKEN_REQUEST_URL`/`_TOKEN` env vars it can use to ask Forgejo for a short-lived OIDC ID
token scoped to *this specific run* (audience `sts.amazonaws.com`, subject encoding the repo and
ref). The job then:

1. Requests that ID token.
2. Calls `aws sts assume-role-with-web-identity` with it against `AWS_DEPLOY_ROLE_ARN`.
3. Uses the resulting temporary credentials to call `aws secretsmanager get-secret-value` for
   `FLAG_SECRET_ID` and prints the result to stdout as its "deployment sync" step.

Nothing about this workflow is secret or hidden from the player — it's committed to `main`, which
the player can read (Write access includes read). The only thing standing between the player and
running it with their own commit is whichever ref the push lands on, which is exactly the gap
`bootstrap.sh` leaves open.

### 4. IAM OIDC trust — correctly scoped, and deliberately not the bug

- `aws_iam_openid_connect_provider.forgejo` registers Forgejo's own Actions issuer
  (`https://<team_id>.challenge2.aikidoctf.com/api/actions`) as a trusted OIDC provider. AWS
  validates this by connecting to the issuer's discovery endpoint at creation time — which is why
  this resource has to wait (`null_resource.wait_for_forgejo_healthy`, polling the ALB target
  group's health) until Forgejo is actually up behind the ALB, not just until the ECS service
  object exists.
- `aws_iam_role.deploy`'s trust policy conditions on:
  - `"...:aud" = "sts.amazonaws.com"`
  - `"...:sub"` matching `repo:team-<team_id>/infra:ref:refs/heads/deploy/*` (a `StringLike`,
    i.e. wildcard, condition)
- That trust policy is **exactly right** — it only trusts tokens whose subject claim says "this
  came from team `<team_id>`'s own `infra` repo, on a ref under `deploy/`." A token minted by a
  *different* team's Forgejo (a different OIDC provider ARN entirely, since each team has its own)
  could never satisfy it. The vulnerability is entirely that Forgejo will happily mint a
  `deploy/pwn` token for anyone with Write access, not that AWS trusts the wrong thing.
- `aws_iam_role_policy.deploy_secrets_read` scopes the role to `secretsmanager:GetSecretValue` on
  exactly this team's one flag secret ARN — nothing account-wide, nothing another team's stack
  could ever be affected by even in the worst case.

### 5. The CI runner (EC2, not Fargate)

- Fargate can't run `forgejo-runner`'s jobs (they need Docker-in-Docker to execute the job's own
  containers), so this component is a plain EC2 instance instead.
- `runner/user_data.sh.tftpl` installs Docker and `forgejo-runner`, then polls this team's SSM
  parameter for the registration token `bootstrap.sh` will eventually publish (Terraform
  pre-creates the parameter with a `PENDING` placeholder specifically so `terraform destroy` cleans
  it up between deployments; the runner's boot script keeps waiting past that placeholder rather
  than registering with it).
- The one-time registration token has to go through `forgejo-runner register` (not `daemon`'s
  inline token config, which rejects the token's own base64url character set) — `register` writes
  a `.runner` file containing the runner's real persistent token, which `daemon` then reads with no
  further config needed. Both this and the AWS CLI's SSM write use `--flag=value` rather than
  `--flag value`, because the token can start with `-` by chance and confuse either tool's argument
  parser otherwise (found by live testing, not theoretical).
- `aws_security_group.runner_sg` has **no inbound rules at all** — the runner only ever makes
  outbound connections (polling Forgejo for jobs), and its IAM role
  (`aws_iam_role.runner`/`aws_iam_instance_profile.runner`) grants nothing beyond
  `ssm:GetParameter` on this team's own token and the standard `AmazonSSMManagedInstanceCore`
  policy (for Session Manager access, useful for debugging a stuck runner). The host itself is
  deliberately not a privilege-escalation target: the OIDC token exchange happens inside the job's
  container, sourced from Forgejo's short-lived ID token — never from anything sitting on the
  runner host.

### 6. Routing: the shared ALB, same pattern as Challenge 1

A separate, event-wide **`challenge-2-iac/bootstrap/`** stack (applied once, before any team)
provisions: a Route53 zone lookup for `aikidoctf.com`, a wildcard ACM cert for
`*.challenge2.aikidoctf.com`, one shared ALB (`shadow-pipeline-alb`), and the shared ECR repo for
the Forgejo image. Each team's own `main.tf` looks all of that up read-only and adds only its own
target group, host-header listener rule (`<team_id>.challenge2.aikidoctf.com`, no `priority` set so
independent teams' applies never collide), and Route53 alias record — identical reasoning to
Challenge 1's `bootstrap/`, described in more detail in `challenge1.md`.

## The full attack chain, end to end

```
1. Player logs into https://<team_id>.challenge2.aikidoctf.com as `player` (given credentials)
2. Player clones team-<team_id>/infra, reads .forgejo/workflows/deploy.yml on main
3. Player pushes to main -> rejected, branch protection blocks it
4. Player pushes the same content to a branch matching deploy/* (e.g. deploy/pwn) -> succeeds
5. Forgejo schedules deploy.yml on this team's EC2 runner
6. The job requests an OIDC ID token from Forgejo, calls sts:AssumeRoleWithWebIdentity
   -> permitted, because refs/heads/deploy/pwn matches the trust policy's refs/heads/deploy/* condition
7. The job calls secretsmanager:GetSecretValue for this team's flag secret and prints it
8. Player reads the flag straight out of their own job's log in the Actions tab
```

No exploit in AWS IAM, no OIDC misconfiguration, no zero-day — the trust policy is correct end to
end. The entire vulnerability is that Forgejo's branch protection has a gap the player has to
discover by testing (protected `main`, unprotected `deploy/*`), which is exactly the "real
branch-protection gap under a real, correctly-configured OIDC trust policy" the challenge is built
to teach.

## File map

| File | Role |
|---|---|
| `challenge-2-iac/bootstrap/main.tf`, `challenge-2-iac/bootstrap/variables.tf` | Shared, event-wide: Route53 zone lookup, wildcard ACM cert for `*.challenge2.aikidoctf.com`, shared ALB, shared ECR repo — applied once |
| `challenge-2-iac/variables.tf` | `aws_region`, `team_id`, `zone_name`, `ctf_domain`, `runner_instance_type` |
| `challenge-2-iac/main.tf` | Per-team stack: Forgejo (ECS Fargate + EFS), CI runner (EC2), IAM OIDC provider + deploy role, the flag secret, ALB routing |
| `challenge-2-iac/forgejo/Dockerfile` | Custom Forgejo image build |
| `challenge-2-iac/forgejo/bootstrap.sh` | Container entrypoint: provisions org/repo/player/branch-protection/workflow/secrets/runner-token idempotently on first boot |
| `challenge-2-iac/forgejo/deploy-workflow.yml` | The pre-committed pipeline the runner executes |
| `challenge-2-iac/runner/user_data.sh.tftpl` | EC2 user-data that installs the runner and registers it against Forgejo using the token from SSM |
| `challenge-2-iac/DEPLOYMENT.md` | Operator runbook: domain/DNS setup, bootstrap apply, per-team apply, verification steps, teardown |
| `challenge-2-iac/metadata.yaml` | Submission metadata |
| `challenge-2-iac/docs/challenge-description.md` | Player-facing scenario/objective |
| `challenge-2-iac/docs/learning-objectives.md` | OIDC trust boundaries, branch-protection completeness, CI log exfiltration, least privilege, runner-host isolation |
| `challenge-2-iac/docs/architecture-diagram.md` | Mermaid diagram of bootstrap vs. per-team resources and the full attack chain |
| `challenge-2-iac/docs/walkthrough.md` | Full solve path with exact commands, reset procedure, known shortcuts |
| `challenge-2-iac/docs/hints.md` | 3 progressive hints |
