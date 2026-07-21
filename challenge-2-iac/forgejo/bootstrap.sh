#!/bin/bash
# Entrypoint for the custom Forgejo image. Starts the real Forgejo process (the
# base image's own s6-supervised entrypoint), waits for it to come up, and then
# idempotently provisions everything Challenge 2 needs: an org+repo, a
# low-privileged player account (the team's starting credentials), branch
# protection that covers "main" but not "deploy/*" (the vulnerability), the
# pre-committed deploy workflow, repo-level Action secrets pointing at this
# team's AWS role/flag secret, and a CI runner registration token handed off to
# the EC2 runner via SSM Parameter Store.
#
# Every provisioning call below tolerates "already provisioned" responses
# rather than treating them as fatal. This matters even beyond simple restarts:
# if the container crashes partway through (a transient network blip, EFS
# hiccup, etc.) before writing the completion marker, ECS starts a fresh
# container that re-runs every step from scratch - and without this tolerance,
# the very first already-applied step (e.g. re-creating the org) would exit
# non-zero and crash the new container too, forever, in a live-tested crash
# loop. The exact "already exists" status code differs per endpoint (verified
# empirically against a real Forgejo v15 instance, not assumed): 422 for
# org/user/workflow-file conflicts, 409 for repo conflicts, 403 for branch
# protection conflicts. The collaborator-add and secret-set calls are PUTs and
# naturally idempotent already, so they need no special handling.
set -uo pipefail

MARKER=/data/.ctf-bootstrap-done

/usr/bin/entrypoint /usr/bin/s6-svscan /etc/s6 &
FORGEJO_PID=$!

echo "[bootstrap] waiting for Forgejo to become ready..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:3000/api/v1/version >/dev/null 2>&1; then
    echo "[bootstrap] Forgejo is up."
    break
  fi
  sleep 2
done

if [ -f "$MARKER" ]; then
  echo "[bootstrap] marker file present, skipping provisioning (already done on a prior boot)."
  wait "$FORGEJO_PID"
  exit 0
fi

API="http://localhost:3000/api/v1"
AUTH=(-u "${ADMIN_USERNAME}:${ADMIN_PASSWORD}")

# Performs a curl call; treats its own 2xx as success and any status code
# listed in $2 (space-separated) as an acceptable "already provisioned"
# no-op. Any other status is fatal - prints the response body and aborts,
# so a genuine failure (bad auth, network issue, server error) still stops
# the container clearly rather than silently continuing in a broken state.
api_call() {
  local description="$1"
  local acceptable="$2"
  shift 2
  local body status
  body=$(curl -s -w '\n%{http_code}' "$@")
  status=$(echo "$body" | tail -1)
  body=$(echo "$body" | sed '$d')

  case "$status" in
    2??)
      return 0
      ;;
    *)
      for code in $acceptable; do
        if [ "$status" = "$code" ]; then
          echo "[bootstrap] $description: already provisioned (HTTP $status), continuing"
          return 0
        fi
      done
      echo "[bootstrap] FATAL: $description failed (HTTP $status): $body" >&2
      exit 1
      ;;
  esac
}

echo "[bootstrap] provisioning admin account..."
# The gitea CLI refuses to run as root ("Forgejo is not supposed to be run as
# root") - it must run as the `git` user the base image's own services run as.
# It also exits non-zero if the admin user already exists from a prior partial
# run, so tolerate that specific case rather than treating it as fatal.
if ! su-exec git /usr/local/bin/gitea admin user create \
  --username "$ADMIN_USERNAME" \
  --password "$ADMIN_PASSWORD" \
  --email "admin@ctf.local" \
  --admin 2>&1 | tee /tmp/admin_create.log; then
  if ! grep -qi "already exists" /tmp/admin_create.log; then
    echo "[bootstrap] FATAL: admin user creation failed" >&2
    exit 1
  fi
  echo "[bootstrap] admin account already provisioned, continuing"
fi

echo "[bootstrap] creating org and repo..."
api_call "create org" "422" "${AUTH[@]}" -X POST "${API}/orgs" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${ORG_NAME}\"}"

api_call "create repo" "409" "${AUTH[@]}" -X POST "${API}/orgs/${ORG_NAME}/repos" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${REPO_NAME}\", \"auto_init\": true}"

echo "[bootstrap] creating low-privileged player account..."
api_call "create player user" "422" "${AUTH[@]}" -X POST "${API}/admin/users" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${PLAYER_USERNAME}\", \"password\": \"${PLAYER_PASSWORD}\", \"email\": \"${PLAYER_USERNAME}@ctf.local\", \"must_change_password\": false}"

api_call "add player as collaborator" "" "${AUTH[@]}" -X PUT "${API}/repos/${ORG_NAME}/${REPO_NAME}/collaborators/${PLAYER_USERNAME}" \
  -H "Content-Type: application/json" \
  -d '{"permission": "write"}'

# Both of the following use check-before-write rather than tolerating a
# specific "already exists" status code: once main is protected, Forgejo's
# Contents API commit check rejects a write to main with 403 regardless of
# whether the file already exists (the branch-protection block happens before
# the file-existence check), so a retry after branch protection has already
# been applied would otherwise misread that 403 as a real failure. Checking
# first avoids relying on interpreting an ambiguous status code at all, and
# also removes the ordering dependency the two steps used to have on each
# other (commit-then-protect only worked correctly on a truly fresh repo).
FILE_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "${API}/repos/${ORG_NAME}/${REPO_NAME}/contents/.forgejo/workflows/deploy.yml?ref=main")
if [ "$FILE_STATUS" = "200" ]; then
  echo "[bootstrap] deploy workflow already committed, skipping"
else
  echo "[bootstrap] committing the deploy workflow to main..."
  WORKFLOW_B64=$(base64 /deploy-workflow.yml | tr -d '\n')
  api_call "commit deploy workflow" "" "${AUTH[@]}" -X POST "${API}/repos/${ORG_NAME}/${REPO_NAME}/contents/.forgejo/workflows/deploy.yml" \
    -H "Content-Type: application/json" \
    -d "{\"content\": \"${WORKFLOW_B64}\", \"message\": \"Add deploy workflow\", \"branch\": \"main\"}"
fi

PROTECTION_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "${API}/repos/${ORG_NAME}/${REPO_NAME}/branch_protections/main")
if [ "$PROTECTION_STATUS" = "200" ]; then
  echo "[bootstrap] main branch protection already set, skipping"
else
  echo "[bootstrap] protecting main (deploy/* is deliberately left unprotected)..."
  api_call "protect main branch" "" "${AUTH[@]}" -X POST "${API}/repos/${ORG_NAME}/${REPO_NAME}/branch_protections" \
    -H "Content-Type: application/json" \
    -d '{"rule_name": "main", "enable_push": false, "enable_merge_whitelist": true, "required_approvals": 1}'
fi

echo "[bootstrap] setting repo Action secrets..."
api_call "set AWS_DEPLOY_ROLE_ARN secret" "" "${AUTH[@]}" -X PUT "${API}/repos/${ORG_NAME}/${REPO_NAME}/actions/secrets/AWS_DEPLOY_ROLE_ARN" \
  -H "Content-Type: application/json" \
  -d "{\"data\": \"${AWS_DEPLOY_ROLE_ARN}\"}"

api_call "set FLAG_SECRET_ID secret" "" "${AUTH[@]}" -X PUT "${API}/repos/${ORG_NAME}/${REPO_NAME}/actions/secrets/FLAG_SECRET_ID" \
  -H "Content-Type: application/json" \
  -d "{\"data\": \"${FLAG_SECRET_ID}\"}"

api_call "set AWS_REGION secret" "" "${AUTH[@]}" -X PUT "${API}/repos/${ORG_NAME}/${REPO_NAME}/actions/secrets/AWS_REGION" \
  -H "Content-Type: application/json" \
  -d "{\"data\": \"${AWS_REGION}\"}"

echo "[bootstrap] minting a repo-scoped runner registration token..."
RUNNER_TOKEN=$(curl -sf "${AUTH[@]}" "${API}/repos/${ORG_NAME}/${REPO_NAME}/actions/runners/registration-token" | jq -r .token)
if [ -z "$RUNNER_TOKEN" ] || [ "$RUNNER_TOKEN" = "null" ]; then
  echo "[bootstrap] FATAL: failed to mint a runner registration token" >&2
  exit 1
fi

# Registration tokens are base64url (A-Za-z0-9-_) and can start with "-" by
# chance - the AWS CLI's argument parser then mistakes "--value <token>" for
# an unknown flag ("argument --value: expected one argument"). The --value=
# form is unambiguous regardless of what the token's first character is.
if ! aws ssm put-parameter \
  --name "${SSM_PARAM_NAME}" \
  --type SecureString \
  --value="${RUNNER_TOKEN}" \
  --overwrite \
  --region "${AWS_REGION}" >/dev/null; then
  echo "[bootstrap] FATAL: failed to write the runner token to SSM" >&2
  exit 1
fi

touch "$MARKER"
echo "[bootstrap] provisioning complete."

wait "$FORGEJO_PID"
