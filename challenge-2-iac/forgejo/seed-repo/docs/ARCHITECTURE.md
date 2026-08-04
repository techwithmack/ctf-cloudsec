# checkout-service — Architecture

checkout-service is a containerized checkout API fronted by an ALB, running on ECS Fargate. See
`terraform/` for the exact resource definitions.

```
[ ALB ] -> [ ECS Service: checkout-service ] -> [ RDS: checkout-db ]
```

Deploys are handled by this repo's CI/CD pipeline (see `docs/RUNBOOK.md`), which assumes a scoped
IAM role via OIDC federation — no long-lived AWS credentials are stored in CI.
