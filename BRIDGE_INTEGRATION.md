# Self-Service Bridge Integration Guide

**Audience:** whoever is building/operating Cloud Village's self-service bridge (CTFd auth →
GitHub Actions `workflow_dispatch` → DynamoDB status) for BSides NYC — currently Jayesh.

**Owner on our side:** Mackenzie Jackson (mackenzie@aikido.dev).

This is the single source of truth for what your Lambda needs to do, what we've already built and
hardened on our end, and exactly what we still need from you. If something here conflicts with an
earlier email thread, this doc wins — it reflects what's actually shipped in the repo.

---

## How the pieces fit together

```
Player                CTFd              Your Lambda bridge          This repo (GitHub Actions)         AWS
  │  "start challenge"   │                      │                          │                            │
  ├────────────────────►│                      │                          │                            │
  │                      │  auth event/webhook  │                          │                            │
  │                      ├─────────────────────►│                          │                            │
  │                      │                      │  1. validate identity    │                            │
  │                      │                      │  2. bind to team_id      │                            │
  │                      │                      │  3. write DynamoDB row   │                            │
  │                      │                      │  4. POST workflow_dispatch                             │
  │                      │                      ├─────────────────────────►│                            │
  │                      │                      │   (team_ids, challenge_request_id)                    │
  │                      │                      │                          │  5. validate + provision   │
  │                      │                      │                          ├───────────────────────────►│
  │                      │                      │  6. HMAC-signed webhook  │                            │
  │                      │                      │◄─────────────────────────┤                            │
  │                      │                      │   (URLs + Ch2 creds,     │                            │
  │                      │                      │    never the flag)       │                            │
  │                      │  status/URLs         │  7. update DynamoDB row  │                            │
  │◄─────────────────────┤◄─────────────────────┤                          │                            │
```

Environments self-destruct after **1 hour** regardless of how they were provisioned — a scheduled
reaper enforces this with no exceptions. There is no self-service *destroy*: your bridge should
only ever call `provision-teams.yml`. It should never be given credentials that can dispatch
`destroy-teams.yml` or `reap-teams.yml` — see [PAT scope](#1-the-github-token-pat) below for why
that's now enforced on our side too, not just a request.

---

## What we've already built and hardened (as of 2026-09-29)

You don't need to ask for any of this — it's shipped:

- `team_id` is validated against `^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$` before it ever reaches
  Terraform (was free text when only a human typed it; not safe once an external caller can
  dispatch this on a player's behalf).
- `challenge_request_id` is validated against `^[A-Za-z0-9._-]{1,128}$`.
- A single dispatch is capped at **20 team_ids**. If you ever batch multiple requests into one
  call, stay under that or split into multiple dispatches — this exists so a bug or a replayed
  call can't fan out an unbounded number of teams against our shared ALB/AWS account in one shot.
- The "notify bridge" step that POSTs results back to you refuses anything but `https://`, times
  out instead of hanging a job indefinitely, and fails loudly (not silently) if your endpoint
  doesn't return 2xx.
- `destroy-teams.yml` and `reap-teams.yml` (the two workflows that *tear down* environments — one
  of them, the reaper, has **no human-approval gate at all by design**) now refuse to run for any
  manually-dispatched trigger unless `github.actor` is on an organizer allowlist. This exists
  specifically because a token scoped to "Actions: write" can dispatch *any* workflow in the repo,
  not just `provision-teams.yml` — there's no way to scope a GitHub token to a single workflow
  file. This allowlist means your bridge's token literally cannot reach either teardown workflow,
  no matter what it's scoped to or what happens to it later.
- GitHub Actions steps in all three workflows are pinned to exact commit SHAs (not moving version
  tags), since these jobs assume a real AWS role.
- `main` now requires a reviewed PR to merge (organizer admin accounts can still push directly in
  an emergency) and rejects force-pushes/branch deletion.

---

## What we need from you

Please confirm/complete each of these before we flip this on for real players. Nothing below is
optional — these close specific, concrete risks, not generic best-practice boilerplate.

### 1. The GitHub token (PAT)

You (Jayesh, as `maxdotdotg`) already have Write access to this repo as a collaborator, which is
the minimum GitHub requires for any token — of any kind — to be able to call `workflow_dispatch`
here at all. So there's no invite step left; you can generate the token yourself, right now.

**Please create a fine-grained personal access token under your `maxdotdotg` account, not a
classic one**, scoped to:

- **Only** the `ctf-cloudsec` repository (not "all repositories").
- Repository permission **"Actions: Read and write"** — and nothing else. No `Contents`, no
  `Administration`, no other write permission. Your account already has broader Write access as a
  collaborator, but the *token* should still be scoped down to only what your Lambda actually
  needs — don't let the token inherit everything your account can do just because it's available.
- **An expiration date** — set it to a few days past when BSides NYC actually closes out, not
  "no expiration."

One consequence worth knowing about on our end, so it's not a surprise: because `github.actor` for
anything this token dispatches will show up as `maxdotdotg`, we've deliberately kept that account
*off* the allowlist that gates our two teardown workflows (`destroy-teams.yml` and
`reap-teams.yml`) — your token can dispatch provisioning, and nothing else, regardless of what
scope you give it. That's expected and not something you need to work around.

Then confirm for us:
- Where/how the token is stored on your end (should be a secrets manager, not an env var baked
  into a deploy artifact or committed anywhere).

If this token is ever suspected leaked or misused: revoke it immediately on your end and tell
Mackenzie — we can rotate our side (the webhook secret, the allowlist) same-day with no
infrastructure changes.

### 2. Identity-to-team_id binding — this is the important one

**Your Lambda must be the thing that decides `team_id`, derived from the authenticated CTFd
identity — never accept a client-supplied `team_id` and dispatch it as-is.**

Here's precisely why this matters: `add-team.sh` is intentionally idempotent. Re-running it for a
`team_id` that already has a live environment does **not** rotate that team's Challenge 2 password
(`random_password.player` in Terraform only regenerates if the resource is destroyed/recreated,
not on a plain re-apply). If your Lambda ever lets Team A's authenticated request result in a
dispatch for `team_id=team-b`, our "notify bridge" step will faithfully POST **Team B's real,
already-issued Challenge 2 username and password** to you, and whatever you do with that payload
next (show it to Team A) is a live cross-team credential leak — not a hypothetical, an actual
account-takeover path.

So: bind `team_id` to the authenticated team server-side, deterministically (e.g. a hash/lookup of
the CTFd team ID), and never let request input override it.

### 3. Always dispatch against `ref: "main"`

When calling the `workflow_dispatch` REST endpoint, always pass `"ref": "main"` explicitly. Don't
let this be a caller-configurable value anywhere in your code path.

### 4. Expected volume / concurrency

Tell us your rough expected concurrent-player number so we can sanity-check the 20-team batch cap
and the shared ALB's listener-rule budget against it. If you expect bursts well above that, we can
raise the cap deliberately rather than you working around it.

### 5. Debounce / dedup on repeated requests

If a player double-clicks "start challenge," what does your Lambda do? Our side is safe to
re-dispatch (idempotent, won't reset the flag) but — per #2 above — it returns the **same existing
credentials**, not a fresh reset. Make sure your UI copy doesn't imply a re-request gives players a
clean slate.

### 6. Webhook receiver implementation

Stand up an HTTPS endpoint and give us the URL for `CTF_BRIDGE_WEBHOOK_URL`. We already have
`CTF_BRIDGE_WEBHOOK_SECRET` configured on our side and will share it with you the same way you're
sending us the PAT (password drop) — treat it with the same care as the PAT itself.

**Verify every request's signature before trusting the payload.** We sign the same way GitHub
signs its own webhooks:

```
signature = hex(HMAC_SHA256(key = CTF_BRIDGE_WEBHOOK_SECRET, message = raw_request_body))
header:   X-Signature-256: sha256=<signature>
```

Python:
```python
import hmac, hashlib

def verify(raw_body: bytes, header_value: str, secret: str) -> bool:
    expected = "sha256=" + hmac.new(secret.encode(), raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header_value)
```

Node:
```js
const crypto = require("crypto");

function verify(rawBody, headerValue, secret) {
  const expected = "sha256=" + crypto.createHmac("sha256", secret).update(rawBody).digest("hex");
  return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(headerValue));
}
```

Use a constant-time compare (as above) — a naive `==`/`===` string compare leaks timing
information about how much of the signature you got right.

**Payload shape** (`Content-Type: application/json`):
```json
{
  "team_id": "team-06",
  "challenge_request_id": "your-correlation-id",
  "challenge1": { "url": "https://team-06.challenge1.aikidoctf.com" },
  "challenge2": {
    "url": "https://team-06.challenge2.aikidoctf.com",
    "username": "player",
    "password": "..."
  }
}
```
Note there's no flag in this payload — flags are shared per challenge (not per team) and scored by
the sponsor separately; the bridge never needs to see them.

**Respond fast with 2xx.** We give you 15 seconds per attempt with 3 retries (5s apart) — if you
need to do slow work (writing DynamoDB, notifying the player), ack immediately and do that
asynchronously rather than making us wait on it.

**If we can't reach your endpoint** after retries, the team's environment is still live — we just
couldn't hand you the URLs/creds. The GitHub Actions job log records this as a failure with the
`challenge_request_id`, so you have a lead to correlate against if a player reports "nothing
happened."

### 7. Player-facing TTL messaging

Environments hard-expire at 1 hour with no extension mechanism — a scheduled reaper checks every
5 minutes and tears down anything older, unconditionally. Your CTFd-side UI should tell players
this up front (e.g. "this environment expires in 60 minutes; if you need more time, request it
again"). Re-requesting gives Challenge 2 a fresh EFS volume, but per #2, credentials for a team_id
that's mid-lifetime don't change on a re-apply — only a full destroy+reprovision resets them, and
self-service never triggers a destroy.

---

## Quick checklist to send back to us

- [ ] Fine-grained PAT created under `maxdotdotg` (Actions: read/write only, this repo only,
      expiring), stored in a secrets manager on your end
- [ ] Confirmed: `team_id` is derived from authenticated CTFd identity server-side, never from
      client input
- [ ] Confirmed: dispatch always sends `ref: "main"`
- [ ] Webhook URL (https) ready to receive our signed POST
- [ ] Confirmed: your endpoint verifies `X-Signature-256` before trusting the payload
- [ ] Confirmed: debounce/dedup behavior for repeated player requests
- [ ] Expected concurrent-player volume shared with us

Once these are checked off, set `CTF_BRIDGE_WEBHOOK_URL` (ask Mackenzie to add it as a repo
secret) and we're live end to end.
