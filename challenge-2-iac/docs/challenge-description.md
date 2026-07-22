# Challenge 2: The Shadow Pipeline Overlord

**Category:** CI/CD / IAM / Containers
**Difficulty:** High
**Estimated Solve Time:** 75 minutes
**Hosting Model:** Sponsor Hosted (Aikido)
**Player Isolation:** True — each team gets its own isolated Forgejo instance, CI runner, and AWS
IAM trust relationship

## Scenario

Meridian Systems' platform team runs its own self-hosted Git and CI/CD platform. You've been given
low-privileged access to it — a single collaborator account on one repository, "infra," which
contains the deployment pipeline for a production service.

The pipeline deploys by assuming a cloud IAM role through OpenID Connect — no static AWS
credentials are stored anywhere in the CI system, so there's nothing to steal in the traditional
sense. But that doesn't mean the pipeline is safe to touch.

## Objective

Find a way to get your own code to run with the deploy pipeline's privileges, and use that access
to retrieve the flag.

## Starting Access

- A Forgejo account with **Write** access to one repository (`infra`)
- No admin access, no access to CI/CD configuration screens, no AWS credentials of any kind

## Flag Format

```
FLAG-{32 hexadecimal characters}
```
