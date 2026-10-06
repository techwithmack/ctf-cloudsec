#!/usr/bin/env bash
# Local end-to-end solve of Challenge 2 with no AWS account. Builds the REAL Forgejo image and
# runs its REAL bootstrap.sh, registers a REAL forgejo-runner against it, then plays the
# walkthrough as a player: log in with the documented credentials, clone `infra`, find that
# `main` is protected but `deploy/*` is not, push a deploy/* branch, and read the flag out of
# the job log.
#
# Stand-ins (the only parts that are not the real thing):
#   - moto replaces AWS STS + Secrets Manager (it accepts any web-identity token), via
#     AWS_ENDPOINT_URL injected into jobs through the runner's `envs`, so the deploy workflow
#     itself runs byte-for-byte unmodified.
#   - a one-line `aws` shim replaces `aws ssm put-parameter` inside the Forgejo container and
#     saves the runner registration token to a file instead of SSM.
# NOT covered here (needs a real account, verified live 2026-08-04): the IAM OIDC provider +
# role trust policy actually accepting/denying a given `sub`, and the real EC2/Fargate wiring.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
NET="ctf-c2-localtest"
FORGEJO_PORT="${FORGEJO_PORT:-3300}"
MOTO_PORT="${MOTO_PORT:-5056}"
ORG="team-localtest"
PLAYER_PW="${PLAYER_PW:-fixed-event-password-1}"
FLAG="FLAG-$(openssl rand -hex 16)"
JOB_IMAGE="ctf-local/ubuntu-amd64:22.04"
LOGIN="http://player:$PLAYER_PW@localhost:$FORGEJO_PORT/$ORG/infra.git"

cleanup() {
  docker rm -f ctf-c2-forgejo ctf-c2-moto ctf-c2-runner >/dev/null 2>&1 || true
  # job containers the runner spawned
  for c in $(docker ps -aq --filter "network=$NET"); do docker rm -f "$c" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
cleanup; WORK="$(mktemp -d)"

fail() { echo "FAIL: $*" >&2; echo "--- runner log tail:" >&2; docker logs ctf-c2-runner 2>&1 | tail -30 >&2 || true; exit 1; }
step() { echo; echo "== $*"; }
api() { curl -s -u "player:$PLAYER_PW" "http://localhost:$FORGEJO_PORT/api/v1/$1"; }

docker network create "$NET" >/dev/null

step "Build the real Forgejo image"
docker build -q -t ctf-c2-forgejo "$ROOT/challenge-2-iac/forgejo" >/dev/null

# Production runners are x86_64 EC2 and the workflow downloads the x86_64 AWS CLI, so the job
# image must be amd64 even on an Apple-silicon laptop (runs under emulation there); the runner
# otherwise asks Docker for the host's own platform, so the label below pins `?platform=`. A
# distinct tag keeps this from clobbering a native ubuntu:22.04 you may already have.
docker pull -q --platform linux/amd64 ubuntu:22.04 >/dev/null
docker tag ubuntu:22.04 "$JOB_IMAGE"
docker pull -q motoserver/moto:latest >/dev/null
docker pull -q code.forgejo.org/forgejo/runner:13 >/dev/null

step "Start moto (AWS STS/Secrets Manager stand-in) and seed the flag secret"
docker run -d --name ctf-c2-moto --network "$NET" -p "$MOTO_PORT:5000" motoserver/moto:latest >/dev/null
for _ in $(seq 1 30); do curl -sf "localhost:$MOTO_PORT/moto-api/" >/dev/null && break; sleep 1; done
AWS_ACCESS_KEY_ID=t AWS_SECRET_ACCESS_KEY=t aws --endpoint-url "http://localhost:$MOTO_PORT" --region us-west-2 \
  secretsmanager create-secret --name shadow-pipeline-flag --secret-string "$FLAG" >/dev/null

step "Start Forgejo with the same env the ECS task gets (challenge-2-iac/main.tf)"
cat > "$WORK/aws" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in --value=*) printf '%s' "${a#--value=}" > /data/runner-token;; esac; done
exit 0
EOF
chmod +x "$WORK/aws"
docker run -d --name ctf-c2-forgejo --network "$NET" -p "$FORGEJO_PORT:3000" \
  -v "$WORK/aws:/usr/local/bin/aws:ro" \
  -e FORGEJO__actions__ENABLED=true -e FORGEJO__security__INSTALL_LOCK=true \
  -e FORGEJO__database__DB_TYPE=sqlite3 -e FORGEJO__server__ROOT_URL=http://ctf-c2-forgejo:3000/ \
  -e ADMIN_USERNAME=ctfadmin -e ADMIN_PASSWORD=admin-local-pw-0123456789 \
  -e ORG_NAME="$ORG" -e REPO_NAME=infra -e PLAYER_USERNAME=player -e PLAYER_PASSWORD="$PLAYER_PW" \
  -e AWS_DEPLOY_ROLE_ARN=arn:aws:iam::123456789012:role/shadow-pipeline-deploy-localtest \
  -e FLAG_SECRET_ID=shadow-pipeline-flag -e AWS_REGION=us-west-2 -e SSM_PARAM_NAME=/local/token \
  ctf-c2-forgejo >/dev/null
for _ in $(seq 1 120); do docker logs ctf-c2-forgejo 2>&1 | grep -q 'provisioning complete' && break; sleep 2; done
docker logs ctf-c2-forgejo 2>&1 | grep -q 'provisioning complete' || fail "bootstrap.sh never completed"
docker logs ctf-c2-forgejo 2>&1 | grep -q 'FATAL' && fail "bootstrap.sh logged a FATAL"

step "Start the real forgejo-runner (v13) and register it with the token bootstrap.sh minted"
TOKEN="$(docker exec ctf-c2-forgejo cat /data/runner-token)"
[ -n "$TOKEN" ] || fail "bootstrap.sh did not mint a runner token"
cat > "$WORK/runner-config.yml" <<EOF
log:
  level: info
runner:
  file: /data/.runner
  capacity: 1
  timeout: 15m
  envs:
    AWS_ENDPOINT_URL: http://ctf-c2-moto:5000
    AWS_ACCESS_KEY_ID: test
    AWS_SECRET_ACCESS_KEY: test
container:
  network: $NET
EOF
docker run -d --name ctf-c2-runner --network "$NET" --user 0 \
  -v /var/run/docker.sock:/var/run/docker.sock -v "$WORK/runner-config.yml:/config.yml:ro" \
  --entrypoint sh code.forgejo.org/forgejo/runner:13 -c \
  "mkdir -p /data && cd /data && forgejo-runner register --no-interactive --instance http://ctf-c2-forgejo:3000 --token='$TOKEN' --name local-runner --labels 'ubuntu-latest:docker://$JOB_IMAGE?platform=linux/amd64' && exec forgejo-runner daemon --config /config.yml" >/dev/null
for _ in $(seq 1 30); do docker logs ctf-c2-runner 2>&1 | grep -q 'declared successfully' && break; sleep 1; done
docker logs ctf-c2-runner 2>&1 | grep -q 'declared successfully' || fail "runner failed to register/declare"

step "Player step 1: the documented credentials work, wrong ones don't, and the account is not admin"
[ "$(api user | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["login"],d["is_admin"])')" = "player False" ] \
  || fail "player login/admin check wrong"
[ "$(curl -s -o /dev/null -w '%{http_code}' -u player:wrong "http://localhost:$FORGEJO_PORT/api/v1/user")" = 401 ] \
  || fail "wrong password was accepted"

step "Player step 2: clone infra and look around"
git clone -q "$LOGIN" "$WORK/infra"
cd "$WORK/infra"
git config user.email player@ctf.local; git config user.name player
[ -f .forgejo/workflows/deploy.yml ] || fail "deploy workflow missing from the repo"
grep -q "deploy/\*\*" .forgejo/workflows/deploy.yml || fail "deploy workflow isn't triggered by deploy/**"
git branch -r | grep -q 'release/2026.03-legacy' || fail "decoy branches missing"

step "Player step 3: main is protected (push must be rejected)"
echo "# probe" >> README.md; git commit -qam "probe main"
if git push -q origin HEAD:main 2>"$WORK/push-main.err"; then fail "push to main SUCCEEDED - branch protection is not working"; fi
grep -qi 'declined\|protected\|rejected' "$WORK/push-main.err" || fail "main push failed for an unexpected reason: $(cat "$WORK/push-main.err")"
echo "rejected as expected"

step "Player step 4: deploy/* is NOT protected - push triggers the pipeline"
git push -q origin HEAD:refs/heads/deploy/pwn 2>&1 || fail "push to deploy/* was rejected (it should be allowed)"
echo "pushed deploy/pwn; waiting for the runner to run the job (apt + AWS CLI download, slow under emulation)..."
# Read the job log the way a player does: log in to the web UI and fetch the run's log.
BASE="http://localhost:$FORGEJO_PORT"
JAR="$WORK/cookies"
curl -s -c "$JAR" -b "$JAR" "$BASE/user/login" -o /dev/null
curl -s -c "$JAR" -b "$JAR" -o /dev/null --data-urlencode "password=$PLAYER_PW" -d user_name=player "$BASE/user/login"
fetch_log() {  # $1 = run index; prints status then every log line
  curl -s -b "$JAR" -H "Content-Type: application/json" -H "Origin: $BASE" -X POST \
    -d '{"logCursors":[{"step":0,"cursor":0,"expanded":true},{"step":1,"cursor":0,"expanded":true},{"step":2,"cursor":0,"expanded":true}]}' \
    "$BASE/$ORG/infra/actions/runs/$1/jobs/0/attempt/1" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print("STATUS:" + str(d.get("state", {}).get("run", {}).get("status")))
for g in (d.get("logs") or {}).get("stepsLog") or []:
    for l in g["lines"]: print(l["message"])
'
}
GOT=""; LOGTXT=""
for _ in $(seq 1 180); do
  LOGTXT="$(fetch_log 1)"
  GOT="$(printf '%s' "$LOGTXT" | grep -oE 'FLAG-[0-9a-f]{32}' | head -1 || true)"
  [ -n "$GOT" ] && break
  printf '%s' "$LOGTXT" | grep -qE '^STATUS:(failure|cancelled|skipped)' && { printf '%s\n' "$LOGTXT" | tail -15 >&2; fail "pipeline job ended without printing a flag"; }
  sleep 5
done

step "Player step 5: read the flag from the job output"
echo "flag from job log: ${GOT:-<none>}"
[ "$GOT" = "$FLAG" ] || fail "flag mismatch (got '${GOT:-none}', expected '$FLAG')"
echo "$GOT" | grep -qE '^FLAG-[0-9a-f]{32}$' || fail "flag doesn't match FLAG-{32 hex}"

echo; echo "PASS: Challenge 2 solve path works end to end (real Forgejo + bootstrap + runner; AWS stubbed)"
