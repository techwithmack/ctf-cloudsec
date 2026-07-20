# Forgejo Image — Build & Publish (one-time, before any team deploys)

Like Challenge 1's entry-point app, `main.tf` looks up the shared ECR repository as a **data
source** (`data.aws_ecr_repository.forgejo`), not a resource — every team's `terraform apply`
uses this same per-team-templated stack, so the repository itself is created exactly once by
`challenge-3-iac/bootstrap/`, and the image is built/pushed exactly once here, before the first
team deploys.

```bash
# 1. Apply the bootstrap stack first (creates the shared ECR repo, ALB, ACM cert, Route53 zone)
cd challenge-3-iac/bootstrap
terraform init
terraform apply -var="ctf_domain=<your-domain>"
terraform output ecr_repository_url

# 2. Authenticate Docker to that ECR repo
aws ecr get-login-password --region us-west-2 \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-west-2.amazonaws.com

# 3. Build and push the image (linux/amd64 - see Challenge 1's app/README.md for why this
# matters if you're building on Apple Silicon: a native arm64 build won't pull on Fargate)
docker buildx build --platform linux/amd64 \
  -t <account-id>.dkr.ecr.us-west-2.amazonaws.com/shadow-pipeline-forgejo:latest \
  --push challenge-3-iac/forgejo/
```

After this, every `terraform apply -var="team_id=<team>" -var="ctf_domain=<domain>"` in
`challenge-3-iac/` reuses the same `:latest` image. The image itself is generic — all per-team
identity (org/repo names, credentials, AWS role ARN, flag secret ARN, SSM parameter name) is
injected via environment variables in the ECS task definition, the same pattern Challenge 1 uses
for its entry-point app.

Re-run step 3 whenever `bootstrap.sh` or `deploy-workflow.yml` changes; existing team deployments
pick up the new image on their next task restart (`aws ecs update-service --force-new-deployment`),
though note that `bootstrap.sh`'s provisioning step only re-runs if the persistent EFS-backed
`/data` volume's marker file (`/data/.ctf-bootstrap-done`) is absent — a config-only change (e.g.
a workflow tweak) that needs to reach an *already-provisioned* team's repo requires either
deleting that marker file first or applying the change directly via the Forgejo API/UI for that
team.
