# Who can reach team passwords and AWS: access notes and audit

Audit date: **2026-10-16**. Repo: `techwithmack/ctf-cloudsec` (**public**).

## Who has access

| Account | GitHub permission | Notes |
|---|---|---|
| `techwithmack` | admin | Organizer. Only login on the `ORGANIZER_GITHUB_LOGINS` allowlist. |
| `maxdotdotg` | write | Cloud Village CTF/Techops ("max g" on Discord). Added Aug 2026 so they could run/dispatch the provision workflow. Still a collaborator. |

No deploy keys and no webhooks exist on the repo.

**Identity caution.** Earlier notes in this repo said `maxdotdotg` is Jayesh's own account. The
Discord thread shows "max g (CTF/Techops)" (GitHub `maxdotdotg`) and "Jayesh" (`cvjayesh`, Cloud
Village founder) as separate people. Not confirmed either way; either way `maxdotdotg` must stay
**off** `ORGANIZER_GITHUB_LOGINS`.

## What Write access can reach (design facts)

- **Logs:** passwords and flags are masked (`***`), so logs alone do not reveal them.
- **AWS role:** the `ctf-github-actions-provisioner` role's OIDC trust policy
  (`ci-bootstrap/main.tf`) matches on the `repository` claim only, **not on branch**. A user with
  Write access can push a branch containing their own workflow, assume the role, and read any team's
  Terraform state (passwords, shared flags) or act within the role's CTF-prefix permissions. The
  `destroy-approval` environment only gates `destroy-teams.yml`, not arbitrary workflows.
- Repo variables (e.g. `CTF_PLAYER_PASSWORD`, if set) are likely readable by collaborators
  (unverified).
- The sponsor already holds both flags (CTFd scoring is theirs), so the practical exposure is
  account/PAT compromise, not Cloud Village misuse.

Possible hardening (**not done**): restrict the trust policy to `refs/heads/main`. One-line change
in `ci-bootstrap/main.tf` plus `terraform apply` there; test with a throwaway team before the event.

## Audit result: Max's activity (as of 2026-10-16)

- **279 workflow runs**, all `workflow_dispatch` on `main`, between **2026-08-06 and 2026-08-09**.
  Almost all "Provision" runs; 2 manual "Reap expired" runs on 08-07/08-08 (before the organizer
  allowlist existed). Last run: **2026-08-09 14:10 UTC**. **None since.**
- **No** push-triggered runs and **no** runs from any non-`main` branch by Max.
  (The only non-`main` run in history is `test/challenge-request-id-dispatch`, by `techwithmack`.)
- Code contributions: PR #1 "add request-id" (2026-08-06), which added the `challenge_request_id`
  input.
- Limits of this audit: run history does not show who *viewed* logs, and it would not show anything
  done through the GitHub API or the personal access token (PAT) itself.

## PAT

A PAT was given to Cloud Village so their automation can dispatch the workflow. Its scope and expiry
are not visible from the repo. Check GitHub → Settings → Developer settings → Personal access
tokens. It should be fine-grained, limited to this repo, **Actions: read and write** only, with an
expiry shortly after the event. Revoke and reissue if it is older, broader, or unknown. (Max
originally asked for one expiring August 10th.)

## Other things in the AWS account (not ours)

The account also holds `idor-*`, `leakedcreds-*` and `ssrf-*` resources (ALBs, ECS clusters, ECR
repos, certs, `learnlab.aikidoctf.com` zone). They are **not part of this repo** and are
intentionally left alone. The reaper and scripts only touch `aikido-ctf-*`, `flawed-blueprint-*`
and `shadow-pipeline-*`.
