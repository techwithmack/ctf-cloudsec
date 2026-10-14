# Self-Service Bridge Integration Guide

**Audience:** whoever operates Cloud Village's self-service bridge (CTFd auth → GitHub Actions
`workflow_dispatch`) for BSides NYC. Owner on our side: Mackenzie Jackson (mackenzie@aikido.dev).

The bridge changes nothing about how provisioning works: it is just another thing that dispatches
`provision-teams.yml`, the same workflow organizers run by hand. There is **no webhook or callback**
from us. The bridge polls the workflow run for completion and builds the URLs itself.

```
Player → your bridge → validates CTFd token → workflow_dispatch → provision-teams.yml → AWS
                ▲                                                         │
                └──────── polls run status (match run by challenge_request_id) ◄──┘
```

## Dispatch contract

`POST /repos/techwithmack/ctf-cloudsec/actions/workflows/provision-teams.yml/dispatches`, always
with `"ref": "main"`, and inputs:

| input | rules |
|---|---|
| `team_ids` | comma/newline separated, max **20** per dispatch, each `^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$` |
| `challenge_request_id` | `^[A-Za-z0-9._-]{1,128}$` (your tracking UUID fits) |

The run's display name is `Provision <team_ids> (request <challenge_request_id>)`, so you can find
your run by that ID. Invalid input fails the run before anything touches AWS.

## What the player gets

- Challenge 1: `https://<team_id>.challenge1.aikidolabs.net`
- Challenge 2: `https://<team_id>.challenge2.aikidolabs.net`, username `player`, and the event-wide
  password we give you for the CTFd challenge text (the `CTF_PLAYER_PASSWORD` repo variable).
- Flags are shared per challenge and scored by the sponsor; the bridge never needs them.

Environments **expire after roughly 1-2 hours** (a reaper checks hourly and tears down anything
past the 1-hour TTL, so a team can live up to ~2 hours worst case). There is no self-service
destroy and no extension. Re-dispatching a live `team_id` is an idempotent re-apply, not a reset.
Tell players to expect their environment to last an hour or so, not a strict 60-minute cutoff.

## What the bridge must do

1. **Derive `team_id` server-side from the authenticated CTFd identity.** Never dispatch a
   client-supplied value. The Challenge 2 password is shared, so the `team_id` in the URL is the only
   thing keeping teams out of each other's Forgejo. Use an **unguessable** `team_id` (e.g. a
   truncated hash of the CTFd team ID; the 20-character limit fits), not `team-06`.
2. **Always dispatch `ref: "main"`**, not a caller-configurable value.
3. **Use a fine-grained PAT** on the `maxdotdotg` account: only this repository, only "Actions:
   Read and write", with an expiry shortly after the event. It never leaves your side. It can't be
   scoped to one workflow file, so see the next section for what stops it reaching teardown.
4. **Dedupe repeat requests** (double clicks). Our side is safe to re-dispatch.
5. Tell us the expected concurrent-team count so we can check it against the 20-team cap and the
   shared ALB's listener-rule budget.

## Protections on our side

- Input validation and the 20-team cap above.
- `destroy-teams.yml` and `reap-teams.yml` reject manual dispatches from anyone not on the
  `ORGANIZER_GITHUB_LOGINS` allowlist (`maxdotdotg` is deliberately absent), so the bridge's token
  can only provision.
- Workflow actions are pinned to commit SHAs; `main` requires a reviewed PR.
