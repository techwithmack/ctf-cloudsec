# Architecture Diagram — Challenge 2: The Shadow Pipeline Overlord

```mermaid
flowchart TB
    Player((Player))

    subgraph Bootstrap["Bootstrap (applied once, shared across all teams)"]
        R53Zone[("Route53 zone\n<ctf_domain>")]
        ACM[("Wildcard ACM cert\n*.<ctf_domain>")]
        ALB["Shared ALB\nHTTPS:443"]
        ECR[("ECR: shadow-pipeline-forgejo\n(custom image, built once)")]
    end

    subgraph Team["Per-team stack (team_id scoped)"]
        DNS["Route53 A record\n<team_id>.<ctf_domain> -> ALB"]
        TG["Target group + host-header\nlistener rule"]

        subgraph FargateForgejo["ECS Fargate: Forgejo"]
            Forgejo["Forgejo container\nbootstrap.sh entrypoint\nSG: 3000 from ALB only"]
            EFS[("EFS: persistent /data\n(SQLite DB, repos, Actions state)")]
        end

        subgraph EC2Runner["EC2: CI Runner (NOT Fargate - needs Docker-in-Docker)"]
            Runner["forgejo-runner daemon\nno inbound, no AWS role\nbeyond reading its own token"]
        end

        SSM[("SSM Parameter\nrunner registration token")]
        OIDC["IAM OIDC Provider\nissuer: https://<team_id>.<ctf_domain>/api/actions"]
        DeployRole["IAM Role: deploy-<team_id>\nTrust: sub matches\nrepo:team-<id>/infra:ref:refs/heads/deploy/*\n(correctly scoped - NOT the bug)"]
        Secret[("Secrets Manager\nFLAG-{32hex}")]
    end

    Player -- "1. git push deploy/pwn\n(unprotected branch)" --> Forgejo
    Forgejo -- "writes runner token" --> SSM
    Runner -- "reads token, registers & polls" --> SSM
    Forgejo -- "2. schedules job" --> Runner
    Runner -- "3. requests OIDC ID token" --> Forgejo
    Runner -- "4. AssumeRoleWithWebIdentity" --> OIDC
    OIDC --> DeployRole
    DeployRole -- "5. GetSecretValue" --> Secret
    Runner -- "6. flag printed to job log" --> Forgejo
    Player -- "7. reads job log" --> Forgejo

    ALB --> TG --> Forgejo
    DNS --> ALB
    ACM --> ALB
    R53Zone --> DNS
    ECR -- "image pull" --> Forgejo
```

## Notes

- Every per-team resource (Forgejo task, EFS volume, EC2 runner, IAM OIDC provider, IAM role,
  Secrets Manager secret, Route53 record) is name-suffixed with `team_id`, matching Challenge 1's
  isolation convention. The only things shared across teams are the bootstrap resources (ALB, ACM
  cert, Route53 zone, ECR image) — all read-only from each team's perspective.
- The **only** thing that differs from a textbook-correct OIDC CI/CD setup is Forgejo's branch
  protection configuration (protects `main`, omits `deploy/*`). The AWS IAM side — the OIDC
  provider, the trust policy's ref condition, the role's attached permissions — is intentionally
  configured the way a careful team actually would.
- The CI runner runs on EC2, not Fargate, because it needs to launch Docker containers per job
  (the Docker executor `act_runner`/`forgejo-runner` requires) — Fargate does not support
  privileged containers or Docker-in-Docker.
