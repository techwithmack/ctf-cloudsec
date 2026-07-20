# Architecture Diagram — Challenge 1: The Flawed Blueprint

```mermaid
flowchart LR
    Player((Player))

    subgraph AWS["AWS Account — us-west-2 (per-team stack, team_id scoped)"]
        subgraph ECS["ECS Fargate Cluster: aikido-ctf-cluster-${team_id}"]
            Task["Fargate Task\nentrypoint-app\nSG: 0.0.0.0/0 -> :80\nEnv: TEAM_ID, TARGET_BUCKET_URL"]
        end

        ECR[("ECR Repository\naikido-ctf-flawed-blueprint\n(shared, built once)")]
        ExecRole["IAM Role\necs_execution_role\n(AmazonECSTaskExecutionRolePolicy)"]

        subgraph Storage["S3"]
            Bucket[("S3 Bucket\naikido-ctf-blueprint-backup-${team_id}\nPublic read policy\nAccess block disabled")]
            Flag["prod_backup_config.toml\ncontains FLAG-{32hex}"]
        end
    end

    Player -- "1. HTTP GET /" --> Task
    ECR -- "image pull" --> Task
    ExecRole -. "assumed by" .-> Task
    Task -- "2. HTML response leaks bucket URL\nin an HTML comment" --> Player
    Player -- "3. aws s3 ls / cp --no-sign-request" --> Bucket
    Bucket --> Flag
    Flag -- "4. flag retrieved" --> Player
```

## Notes

- Every resource (bucket, cluster, IAM role, task family, security group, service) is name-suffixed
  with `team_id`, so each team's `terraform apply -var="team_id=<team>"` provisions a fully
  isolated set of resources — no shared state between teams except the read-only ECR image.
- The container image itself is generic: it is built and pushed to ECR **once** (see
  `app/README.md`) and reused by every team's task via environment-variable injection, not
  per-team image builds.
- The bucket's public read policy plus disabled public-access-block settings are the sole
  vulnerability — everything else in the stack (execution role, security group, ECS service) exists
  only to host the entry-point web app that leaks the bucket's URL.
