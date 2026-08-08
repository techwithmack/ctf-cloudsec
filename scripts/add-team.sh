#!/usr/bin/env bash
# Provision (or update) both challenges' environments for one team.
#
# Usage: scripts/add-team.sh <team_id>
#
# Prerequisite: challenge-1-iac/bootstrap/ and challenge-2-iac/bootstrap/ must
# already be applied (the shared ALB/ACM cert/Route53 zone/ECR repo - done
# once per event, not per team).
#
# Safe to re-run for an existing team_id: it just re-applies that team's
# stack against its own Terraform workspace. It will not silently reset a
# team's flag/credentials - Terraform only replaces resources that actually
# need replacing.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <team_id>" >&2
  exit 1
fi

TEAM_ID="$1"
ZONE_NAME="aikidoctf.com"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Retries `terraform apply` a few times on failure. Real-world trigger: both
# challenges' shared-ALB listener rules deliberately omit `priority` (see that
# resource's own comment) so AWS assigns the next free one - under enough
# concurrent team provisions (provision-teams.yml matrixes many teams at
# once), two applies can race for the same priority and exceed the AWS
# provider's own retry budget. A rerun succeeds trivially once the other
# team's rule already exists, so a bounded retry here is simpler and more
# robust than hand-rolling a distributed lock for what's fundamentally a
# transient conflict.
#
# Also self-heals a stale state lock, the same way remove-team.sh's
# destroy_with_lock_retry already does for destroys: provision-teams.yml's own
# 30-minute job timeout can force-cancel a slow apply (Forgejo health-wait
# loops, EC2 capacity retries, etc.) mid-write, which kills the process before
# Terraform's deferred unlock runs and strands the lock in DynamoDB. Without
# this, every later provision attempt for that team_id fails instantly with
# "Error acquiring the state lock" forever, since a plain retry does nothing
# against a lock that's still held - confirmed live across several teams'
# state during this event before this fix (see the 2026-08-08 incident with
# CTF Ops/Techops).
apply_with_retry() {
  local attempt=1
  while [ "$attempt" -le 3 ]; do
    local log
    log="$(mktemp)"
    if terraform apply -auto-approve "$@" 2>&1 | tee "$log"; then
      rm -f "$log"
      return 0
    fi

    local lock_id=""
    if grep -q 'Error acquiring the state lock' "$log"; then
      lock_id="$(grep -oE 'ID:[[:space:]]+[0-9a-fA-F-]+' "$log" | awk '{print $2}' | head -1)"
    fi
    rm -f "$log"

    if [ -n "$lock_id" ]; then
      echo "Stale state lock $lock_id detected (left by a previous interrupted apply) - force-unlocking and retrying." >&2
      terraform force-unlock -force "$lock_id"
      continue # a deterministic fix, not a flaky retry - doesn't count against the attempt budget below
    fi

    if [ "$attempt" -lt 3 ]; then
      echo "terraform apply failed (attempt $attempt/3) - retrying in 10s, likely a transient AWS API conflict (e.g. ALB listener rule priority)" >&2
      sleep 10
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

provision() {
  local dir="$1" ctf_domain="$2" label="$3"
  echo "=== $label: provisioning $TEAM_ID ==="
  (
    cd "$REPO_ROOT/$dir"
    terraform init -input=false >/dev/null
    terraform workspace select "$TEAM_ID" 2>/dev/null || terraform workspace new "$TEAM_ID"
    apply_with_retry \
      -var="team_id=$TEAM_ID" \
      -var="zone_name=$ZONE_NAME" \
      -var="ctf_domain=$ctf_domain" \
      -var="aws_region=us-west-2"
  )
}

provision "challenge-1-iac" "challenge1.$ZONE_NAME" "Challenge 1"
provision "challenge-2-iac" "challenge2.$ZONE_NAME" "Challenge 2"

echo
echo "=== $TEAM_ID is ready ==="

# In GitHub Actions, register each secret with the log masker *before* printing
# it - masking only applies to lines emitted after the ::add-mask:: command, so
# the value must never be echoed unmasked first. Outside CI this is a no-op.
mask() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::add-mask::$1"
  fi
}

echo "--- Challenge 1 ---"
(
  cd "$REPO_ROOT/challenge-1-iac"
  terraform workspace select "$TEAM_ID" >/dev/null
  c1_flag="$(terraform output -raw qa_verification_flag)"
  mask "$c1_flag"
  echo "URL:  $(terraform output -raw entrypoint_url)"
  echo "Flag: $c1_flag"
)

echo "--- Challenge 2 ---"
(
  cd "$REPO_ROOT/challenge-2-iac"
  terraform workspace select "$TEAM_ID" >/dev/null
  c2_password="$(terraform output -raw player_password)"
  c2_flag="$(terraform output -raw qa_verification_flag)"
  mask "$c2_password"
  mask "$c2_flag"
  echo "URL:      $(terraform output -raw entrypoint_url)"
  echo "Username: $(terraform output -raw player_username)"
  echo "Password: $c2_password"
  echo "Flag:     $c2_flag"
)
