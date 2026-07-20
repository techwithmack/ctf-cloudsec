#!/bin/bash
# Entrypoint for the custom Forgejo image. Starts the real Forgejo process (the
# base image's own s6-supervised entrypoint), waits for it to come up, and then -
# on first boot only, guarded by a marker file on the persistent /data volume -
# idempotently provisions everything Challenge 3 needs: an org+repo, a
# low-privileged player account (the team's starting credentials), branch
# protection that covers "main" but not "deploy/*" (the vulnerability), the
# pre-committed deploy workflow, repo-level Action secrets pointing at this
# team's AWS role/flag secret, and a CI runner registration token handed off to
# the EC2 runner via SSM Parameter Store.
#
# A container restart re-runs this script, but the marker file (persisted on the
# same EFS-backed volume as Forgejo's own SQLite DB) makes re-provisioning a
# no-op - Forgejo's data, including any branches the player already pushed, and
# the runner's registration, survive a restart untouched.
set -euo pipefail

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

echo "[bootstrap] provisioning admin account..."
# The gitea CLI refuses to run as root ("Forgejo is not supposed to be run as
# root") - it must run as the `git` user the base image's own services run as.
su-exec git /usr/local/bin/gitea admin user create \
  --username "$ADMIN_USERNAME" \
  --password "$ADMIN_PASSWORD" \
  --email "admin@ctf.local" \
  --admin

API="http://localhost:3000/api/v1"
AUTH=(-u "${ADMIN_USERNAME}:${ADMIN_PASSWORD}")

echo "[bootstrap] creating org and repo..."
curl -sf "${AUTH[@]}" -X POST "${API}/orgs" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${ORG_NAME}\"}" >/dev/null

curl -sf "${AUTH[@]}" -X POST "${API}/orgs/${ORG_NAME}/repos" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${REPO_NAME}\", \"auto_init\": true}" >/dev/null

echo "[bootstrap] creating low-privileged player account..."
curl -sf "${AUTH[@]}" -X POST "${API}/admin/users" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${PLAYER_USERNAME}\", \"password\": \"${PLAYER_PASSWORD}\", \"email\": \"${PLAYER_USERNAME}@ctf.local\", \"must_change_password\": false}" >/dev/null

curl -sf "${AUTH[@]}" -X PUT "${API}/repos/${ORG_NAME}/${REPO_NAME}/collaborators/${PLAYER_USERNAME}" \
  -H "Content-Type: application/json" \
  -d '{"permission": "write"}' >/dev/null

echo "[bootstrap] committing the deploy workflow to main..."
# Must happen BEFORE branch protection is applied below: Forgejo's Contents API
# commit check does not honor branch-protection's admin-bypass the way a git push
# does, so even the admin account gets a 403 "user cannot commit to repo" if main
# is already protected when this call runs.
WORKFLOW_B64=$(base64 /deploy-workflow.yml | tr -d '\n')
curl -sf "${AUTH[@]}" -X POST "${API}/repos/${ORG_NAME}/${REPO_NAME}/contents/.forgejo/workflows/deploy.yml" \
  -H "Content-Type: application/json" \
  -d "{\"content\": \"${WORKFLOW_B64}\", \"message\": \"Add deploy workflow\", \"branch\": \"main\"}" >/dev/null

echo "[bootstrap] protecting main (deploy/* is deliberately left unprotected)..."
curl -sf "${AUTH[@]}" -X POST "${API}/repos/${ORG_NAME}/${REPO_NAME}/branch_protections" \
  -H "Content-Type: application/json" \
  -d '{"rule_name": "main", "enable_push": false, "enable_merge_whitelist": true, "required_approvals": 1}' >/dev/null

echo "[bootstrap] setting repo Action secrets..."
curl -sf "${AUTH[@]}" -X PUT "${API}/repos/${ORG_NAME}/${REPO_NAME}/actions/secrets/AWS_DEPLOY_ROLE_ARN" \
  -H "Content-Type: application/json" \
  -d "{\"data\": \"${AWS_DEPLOY_ROLE_ARN}\"}" >/dev/null

curl -sf "${AUTH[@]}" -X PUT "${API}/repos/${ORG_NAME}/${REPO_NAME}/actions/secrets/FLAG_SECRET_ID" \
  -H "Content-Type: application/json" \
  -d "{\"data\": \"${FLAG_SECRET_ID}\"}" >/dev/null

curl -sf "${AUTH[@]}" -X PUT "${API}/repos/${ORG_NAME}/${REPO_NAME}/actions/secrets/AWS_REGION" \
  -H "Content-Type: application/json" \
  -d "{\"data\": \"${AWS_REGION}\"}" >/dev/null

echo "[bootstrap] minting a repo-scoped runner registration token..."
RUNNER_TOKEN=$(curl -sf "${AUTH[@]}" "${API}/repos/${ORG_NAME}/${REPO_NAME}/actions/runners/registration-token" | jq -r .token)

aws ssm put-parameter \
  --name "${SSM_PARAM_NAME}" \
  --type SecureString \
  --value "${RUNNER_TOKEN}" \
  --overwrite \
  --region "${AWS_REGION}" >/dev/null

touch "$MARKER"
echo "[bootstrap] provisioning complete."

wait "$FORGEJO_PID"
