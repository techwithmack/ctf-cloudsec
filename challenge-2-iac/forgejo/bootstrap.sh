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

# Realistic, occasionally ticket-referencing commit messages instead of a generic "Add <path>"
# for every seeded file - makes `git log` read like actual engineering history rather than a
# script's file dump. Falls back to the old generic message for anything not listed here, so
# adding a new seed-repo file later doesn't require touching this.
commit_message_for() {
  case "$1" in
    docs/ARCHITECTURE.md) echo "Document checkout-service architecture" ;;
    docs/RUNBOOK.md) echo "Add on-call runbook" ;;
    scripts/register-pipeline-secrets.sh) echo "Add pipeline secrets registration script (platform-team only)" ;;
    .forgejo/workflows/ci.yml) echo "Add CI lint/test workflow" ;;
    terraform/main.tf) echo "Add checkout-service ECS service Terraform" ;;
    *) echo "Add ${1}" ;;
  esac
}

# Seed the repo with realistic surrounding content (README, runbooks, a decoy CI workflow, flavor
# Terraform for the fictional service, etc.) so the deploy workflow committed below isn't the only
# file in the repo - a repo containing exactly one file is an obvious tell that undermines the
# intended empirical-discovery solve path (see docs/walkthrough.md step 2).
echo "[bootstrap] seeding repo with baseline content..."
while IFS= read -r -d '' file; do
  rel_path="${file#/seed-repo/}"
  content_b64=$(base64 "$file" | tr -d '\n')

  if [ "$rel_path" = "README.md" ]; then
    # auto_init already committed a default README when the repo was created, so this one exists
    # on every fresh team already - update it in place (needs the current blob's sha) rather than
    # the create-if-missing pattern used for every other file below.
    current_sha=$(curl -s "${AUTH[@]}" "${API}/repos/${ORG_NAME}/${REPO_NAME}/contents/README.md?ref=main" | jq -r .sha)
    api_call "seed README.md" "" "${AUTH[@]}" -X PUT "${API}/repos/${ORG_NAME}/${REPO_NAME}/contents/README.md" \
      -H "Content-Type: application/json" \
      -d "{\"content\": \"${content_b64}\", \"sha\": \"${current_sha}\", \"message\": \"Update README\", \"branch\": \"main\"}"
    continue
  fi

  file_status=$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "${API}/repos/${ORG_NAME}/${REPO_NAME}/contents/${rel_path}?ref=main")
  if [ "$file_status" = "200" ]; then
    echo "[bootstrap] ${rel_path} already committed, skipping"
    continue
  fi
  api_call "seed ${rel_path}" "" "${AUTH[@]}" -X POST "${API}/repos/${ORG_NAME}/${REPO_NAME}/contents/${rel_path}" \
    -H "Content-Type: application/json" \
    -d "{\"content\": \"${content_b64}\", \"message\": \"$(commit_message_for "$rel_path")\", \"branch\": \"main\"}"
done < <(find /seed-repo -type f -print0)

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
    -d "{\"content\": \"${WORKFLOW_B64}\", \"message\": \"Migrate deploy pipeline from Jenkins to Forgejo Actions (INFRA-71)\", \"branch\": \"main\"}"
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

# A couple of stale/abandoned branches so the repo doesn't read as "exactly two branches, one of
# them obviously the point of the challenge." Neither name matches deploy/** (deploy-workflow.yml's
# trigger pattern), so creating them - or the extra commit on the feature branch below - never
# fires the deploy pipeline itself.
echo "[bootstrap] seeding a couple of stale branches for realism..."

create_branch_if_missing() {
  local branch="$1" status
  status=$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "${API}/repos/${ORG_NAME}/${REPO_NAME}/branches/${branch}")
  if [ "$status" = "200" ]; then
    echo "[bootstrap] branch ${branch} already exists, skipping"
    return 0
  fi
  api_call "create branch ${branch}" "" "${AUTH[@]}" -X POST "${API}/repos/${ORG_NAME}/${REPO_NAME}/branches" \
    -H "Content-Type: application/json" \
    -d "{\"new_branch_name\": \"${branch}\", \"old_branch_name\": \"main\"}"
}

create_branch_if_missing "release/2026.03-legacy"
create_branch_if_missing "feature/checkout-retry-experiment"

# Give the feature branch one small extra commit so it isn't just an identical pointer to main -
# content-checked (not status-code-checked) for idempotency, since this PUTs to a file that already
# exists on that branch.
CURRENT_VARS=$(curl -s "${AUTH[@]}" "${API}/repos/${ORG_NAME}/${REPO_NAME}/raw/branch/feature/checkout-retry-experiment/terraform/variables.tf")
if echo "$CURRENT_VARS" | grep -q "retry-storm"; then
  echo "[bootstrap] retry-experiment tweak already committed, skipping"
else
  CURRENT_SHA=$(curl -s "${AUTH[@]}" "${API}/repos/${ORG_NAME}/${REPO_NAME}/contents/terraform/variables.tf?ref=feature/checkout-retry-experiment" | jq -r .sha)
  EXPERIMENT_CONTENT_B64=$(sed 's/default = 2/default = 3 # bumping for the retry-storm load test - holding off on merge, costs too much per finance/' /seed-repo/terraform/variables.tf | base64 | tr -d '\n')
  api_call "commit retry-experiment tweak" "" "${AUTH[@]}" -X PUT "${API}/repos/${ORG_NAME}/${REPO_NAME}/contents/terraform/variables.tf" \
    -H "Content-Type: application/json" \
    -d "{\"content\": \"${EXPERIMENT_CONTENT_B64}\", \"sha\": \"${CURRENT_SHA}\", \"message\": \"Bump desired_count for retry-storm load test\", \"branch\": \"feature/checkout-retry-experiment\"}"
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
