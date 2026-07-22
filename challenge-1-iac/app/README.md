# Entry Point App — Build & Publish (one-time, before any team deploys)

`main.tf` looks up the shared ECR repository as a **data source** (`data.aws_ecr_repository.app`)
rather than creating it, because the same `main.tf` is applied once per team (`-var
team_id=<team>`) and a repository resource would collide on the second team's apply. So the
repository and image are provisioned once, out-of-band, before the first team stack is deployed.

```bash
# 1. Create the shared repository once (us-west-2)
aws ecr create-repository --repository-name aikido-ctf-flawed-blueprint --region us-west-2

# 2. Authenticate Docker to ECR
aws ecr get-login-password --region us-west-2 \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-west-2.amazonaws.com

# 3. Build and push the image
# IMPORTANT: Fargate tasks here run as linux/amd64 (no runtime_platform override in
# main.tf). Building with plain `docker build` on an Apple Silicon / ARM machine
# produces an arm64-only manifest, which ECS then fails to pull with
# "CannotPullContainerError: ... does not contain descriptor matching platform
# 'linux/amd64'". Always build explicitly for linux/amd64:
docker buildx build --platform linux/amd64 \
  -t <account-id>.dkr.ecr.us-west-2.amazonaws.com/aikido-ctf-flawed-blueprint:latest \
  --push app/
```

After this, every `terraform apply -var="team_id=<team>"` reuses the same `:latest` image — the
app itself is generic and only reads `TEAM_ID` / `TARGET_BUCKET_URL` from the environment, both of
which are injected per-team by the ECS task definition in `main.tf`.

Re-run step 3 whenever `app/app.py` changes; existing team deployments must have their ECS service
force a new deployment (`aws ecs update-service --force-new-deployment`) to pick up the new image.
