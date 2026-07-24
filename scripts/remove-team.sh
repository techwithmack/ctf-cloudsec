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
    terraform destroy -auto-approve \
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
