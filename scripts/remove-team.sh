#!/usr/bin/env bash
# Tear down both challenges' environments for one team.
#
# Usage: scripts/remove-team.sh <team_id> [--yes]
#
# Destroys that team's Terraform-managed resources in both challenges and
# deletes its Terraform workspace. Prompts for confirmation unless --yes is
# passed (for use in non-interactive automation). Safe to run against a
# team_id that was never provisioned - just skips it.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <team_id> [--yes]" >&2
  exit 1
fi

TEAM_ID="$1"
AUTO_YES="${2:-}"
ZONE_NAME="aikidoctf.com"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$AUTO_YES" != "--yes" ]; then
  read -r -p "Destroy all resources for team '$TEAM_ID' in both challenges? [y/N] " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# Runs `terraform destroy`, tee-ing its output so callers still see live
# progress. If it fails because a previous run left the state lock held (e.g.
# a CI job that got killed by its own timeout mid-apply/destroy - this is not
# hypothetical, see the 2026-08 reaper timeout incident), this parses the
# Lock ID out of Terraform's own error message, force-unlocks it, and retries
# exactly once - otherwise a single killed run permanently strands that
# team_id until someone notices and force-unlocks it by hand.
destroy_with_lock_retry() {
  local log
  log="$(mktemp)"
  if terraform destroy -auto-approve "$@" 2>&1 | tee "$log"; then
    rm -f "$log"
    return 0
  fi

  local lock_id
  if grep -q 'Error acquiring the state lock' "$log"; then
    lock_id="$(grep -oE 'ID:[[:space:]]+[0-9a-fA-F-]+' "$log" | awk '{print $2}' | head -1)"
  fi
  rm -f "$log"

  if [ -z "$lock_id" ]; then
    return 1
  fi

  echo "Stale state lock $lock_id detected (left by a previous interrupted run) - force-unlocking and retrying once." >&2
  terraform force-unlock -force "$lock_id"
  terraform destroy -auto-approve "$@"
}

destroy() {
  local dir="$1" ctf_domain="$2" label="$3"
  echo "=== $label: destroying $TEAM_ID ==="
  (
    cd "$REPO_ROOT/$dir"
    terraform init -input=false >/dev/null
    if ! terraform workspace select "$TEAM_ID" 2>/dev/null; then
      echo "No workspace '$TEAM_ID' found in $dir - skipping."
      exit 0
    fi
    destroy_with_lock_retry \
      -var="team_id=$TEAM_ID" \
      -var="zone_name=$ZONE_NAME" \
      -var="ctf_domain=$ctf_domain" \
      -var="aws_region=us-west-2"
    terraform workspace select default
    terraform workspace delete "$TEAM_ID"
  )
}

destroy "challenge-1-iac" "challenge1.$ZONE_NAME" "Challenge 1"
destroy "challenge-2-iac" "challenge2.$ZONE_NAME" "Challenge 2"

echo
echo "=== $TEAM_ID torn down ==="
