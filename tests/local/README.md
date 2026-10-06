# Local end-to-end checks

`./tests/local/run-all.sh` validates the Terraform/workflows/scripts, then plays both challenges'
solve paths against locally-run copies of the real images. No AWS account or credentials are used.

| Script | What it proves | Stand-ins |
|---|---|---|
| `challenge1.sh` | Portal image builds; its HTML comment leaks the bucket URL; the bucket can be listed and read with no credentials; the flag is in `prod_backup_config.toml` | moto for S3 |
| `challenge2.sh` | The real Forgejo image + `bootstrap.sh` provision the org/repo/`player`/branch protection; the documented credentials work; `main` rejects pushes; `deploy/*` doesn't and triggers the real pipeline on a real `forgejo-runner`; the flag appears in the job log the player reads | moto for STS + Secrets Manager; a shim for `aws ssm put-parameter` |

**Not covered (needs a real account):** S3 bucket policy / public-access-block actually permitting
anonymous access, the IAM OIDC provider and role trust policy accepting a `deploy/*` token, and the
ECS/EC2/ALB wiring. Those were verified live (CLAUDE.md, 2026-08-04) and must be re-checked with a
real provision (`scripts/add-team.sh <throwaway-team>`) after any change to them.

Requires Docker. On Apple silicon the Challenge 2 job image runs as `linux/amd64` under emulation
(the workflow downloads the x86_64 AWS CLI), so the first run is slow.
