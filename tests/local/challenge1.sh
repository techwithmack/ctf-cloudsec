#!/usr/bin/env bash
# Local end-to-end solve of Challenge 1 with no AWS account: builds the real portal image,
# stands up moto (an S3 emulator) as the "forgotten bucket", and runs the walkthrough as a
# player would - read the portal's HTML comment, list the bucket unauthenticated, pull the
# backup file, extract the flag. Fails (non-zero) if any step doesn't behave as the
# walkthrough says.
#
# What this does NOT cover (needs a real account): the bucket policy / public-access-block
# actually permitting anonymous access. moto doesn't enforce bucket policies, so that part was
# only ever verified live (see CLAUDE.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S3_PORT="${S3_PORT:-5055}"
APP_PORT="${APP_PORT:-8085}"
BUCKET="aikido-ctf-blueprint-backup-localtest"
FLAG="FLAG-$(openssl rand -hex 16)"
NET="ctf-c1-localtest"

cleanup() {
  docker rm -f ctf-c1-moto ctf-c1-portal >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

docker network create "$NET" >/dev/null

step "Start the S3 stand-in and plant the backup object (same content shape as main.tf's backup_file)"
docker run -d --name ctf-c1-moto --network "$NET" -p "$S3_PORT:5000" motoserver/moto:latest >/dev/null
for _ in $(seq 1 30); do curl -sf "http://localhost:$S3_PORT/moto-api/" >/dev/null && break; sleep 1; done

export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-west-2
S3="aws --endpoint-url http://localhost:$S3_PORT"
$S3 s3 mb "s3://$BUCKET" >/dev/null
# Mirrors the heredoc in challenge-1-iac/main.tf so a change there that breaks the solve shape is
# noticed here when the two are diffed.
cat > "${TMPDIR:-/tmp}/c1-backup.toml" <<EOF
[database]
host = "db-prod.internal.aikido.ctf"
port = 5432
username = "deploy_user"
password = "SuperSecretPassword123!"

[environment]
debug = false
app_version = "1.0.4"

[system_canary]
# TODO: Remove this debug token before pushing to production configuration
flag_token = "$FLAG"
EOF
$S3 s3 cp "${TMPDIR:-/tmp}/c1-backup.toml" "s3://$BUCKET/prod_backup_config.toml" >/dev/null
# moto enforces ACLs for anonymous callers and ignores bucket policies, so the real stack's
# public-read/list bucket policy is approximated with public-read ACLs here.
$S3 s3api put-bucket-acl --bucket "$BUCKET" --acl public-read
$S3 s3api put-object-acl --bucket "$BUCKET" --key prod_backup_config.toml --acl public-read

step "Build and start the real portal image"
docker build -q -t ctf-c1-portal "$ROOT/challenge-1-iac/app" >/dev/null
docker run -d --name ctf-c1-portal --network "$NET" -p "$APP_PORT:80" \
  -e TEAM_ID=localtest \
  -e TARGET_BUCKET_URL="http://localhost:$S3_PORT/$BUCKET" \
  ctf-c1-portal >/dev/null
for _ in $(seq 1 30); do curl -sf "http://localhost:$APP_PORT/" >/dev/null && break; sleep 1; done

step "Player step 1: view the portal source, find the leaked bucket URL"
PAGE="$(curl -sf "http://localhost:$APP_PORT/")"
echo "$PAGE" | grep -q "Welcome, localtest" || fail "portal didn't render the team welcome"
BUCKET_URL="$(echo "$PAGE" | sed -n 's/.*forgotten backup bucket still wired up here: \([^ ]*\) -->.*/\1/p')"
[ -n "$BUCKET_URL" ] || fail "no bucket URL in the HTML comment"
echo "found: $BUCKET_URL"
# The flag itself must not be anywhere on the portal.
echo "$PAGE" | grep -q "$FLAG" && fail "flag leaked directly on the portal page"

step "Player step 2: list the bucket with no credentials (--no-sign-request / plain HTTP)"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
LISTING="$(aws --no-sign-request --endpoint-url "http://localhost:$S3_PORT" s3 ls "s3://$BUCKET/")"
echo "$LISTING"
echo "$LISTING" | grep -q prod_backup_config.toml || fail "backup file not listed"
curl -sf "$BUCKET_URL" | grep -q prod_backup_config.toml || fail "anonymous HTTP listing didn't show the file"

step "Player step 3: download the file and read the flag"
GOT="$(aws --no-sign-request --endpoint-url "http://localhost:$S3_PORT" s3 cp "s3://$BUCKET/prod_backup_config.toml" - \
  | sed -n 's/^flag_token = "\(.*\)"/\1/p')"
echo "flag: $GOT"
[ "$GOT" = "$FLAG" ] || fail "flag mismatch (got '$GOT', expected '$FLAG')"
echo "$GOT" | grep -qE '^FLAG-[0-9a-f]{32}$' || fail "flag doesn't match FLAG-{32 hex}"

echo; echo "PASS: Challenge 1 solve path works end to end (local stand-in)"
