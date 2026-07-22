# Architecture Diagram — Challenge 1: The Flawed Blueprint

```mermaid
flowchart LR
    Player((Player))

    subgraph Shared["Shared bootstrap (applied once, bootstrap/main.tf)"]
        Zone[("Route53 Zone\naikidoctf.com")]
        Cert["ACM Wildcard Cert\n*.challenge1.aikidoctf.com"]
        ALB["Shared ALB\nflawed-blueprint-alb\nHTTPS listener"]
        ECR[("ECR Repository\naikido-ctf-flawed-blueprint\n(shared, built once)")]
    end

    subgraph AWS["AWS Account — us-west-2 (per-team stack, team_id scoped)"]
        DNS["Route53 Record\n${team_id}.challenge1.aikidoctf.com\n-> ALB alias"]
        Rule["ALB Listener Rule\nhost-header: ${team_id}.challenge1.aikidoctf.com"]
        TG["Target Group\nblueprint-tg-${team_id}"]

        subgraph ECS["ECS Fargate Cluster: aikido-ctf-cluster-${team_id}"]
            Task["Fargate Task\nentrypoint-app\nSG: ALB-only -> :80\nEnv: TEAM_ID, TARGET_BUCKET_URL"]
        end

        ExecRole["IAM Role\necs_execution_role\n(AmazonECSTaskExecutionRolePolicy)"]

        subgraph Storage["S3"]
            Bucket[("S3 Bucket\naikido-ctf-blueprint-backup-${team_id}\nPublic read policy\nAccess block disabled")]
            Flag["prod_backup_config.toml\ncontains FLAG-{32hex}"]
        end
    end

    Player -- "1. HTTPS GET /" --> DNS
    DNS --> ALB
    ALB --> Rule
    Rule --> TG
    TG --> Task
    ECR -- "image pull" --> Task
    ExecRole -. "assumed by" .-> Task
    Task -- "2. HTML response leaks bucket URL\nin an HTML comment" --> Player
    Player -- "3. aws s3 ls / cp --no-sign-request" --> Bucket
    Bucket --> Flag
    Flag -- "4. flag retrieved" --> Player
```

## Notes

- Every per-team resource (bucket, cluster, IAM role, task family, security group, target group,
  listener rule, DNS record) is name-suffixed with `team_id`, so each team's
  `terraform apply -var="team_id=<team>" -var="zone_name=aikidoctf.com" -var="ctf_domain=challenge1.aikidoctf.com"`
  provisions a fully isolated set of resources. Teams share only read-only lookups: the ECR image,
  the Route53 zone, and the ALB/listener (distinguished per team by host-header rule, not by
  separate load balancers) — the same shared-resource pattern Challenge 2 uses.
- The container image itself is generic: it is built and pushed to ECR **once** (see
  `app/README.md`) and reused by every team's task via environment-variable injection, not
  per-team image builds.
- The bucket's public read policy plus disabled public-access-block settings are the sole
  vulnerability — everything else in the stack (execution role, security group, ALB routing, ECS
  service) exists only to host the entry-point web app that leaks the bucket's URL.
