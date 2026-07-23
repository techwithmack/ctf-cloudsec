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

provision() {
  local dir="$1" ctf_domain="$2" label="$3"
  echo "=== $label: provisioning $TEAM_ID ==="
  (
    cd "$REPO_ROOT/$dir"
    terraform init -input=false >/dev/null
    terraform workspace select "$TEAM_ID" 2>/dev/null || terraform workspace new "$TEAM_ID"
    terraform apply -auto-approve \
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

echo "--- Challenge 1 ---"
(
  cd "$REPO_ROOT/challenge-1-iac"
  terraform workspace select "$TEAM_ID" >/dev/null
  echo "URL:  $(terraform output -raw entrypoint_url)"
  echo "Flag: $(terraform output -raw qa_verification_flag)"
)

echo "--- Challenge 2 ---"
(
  cd "$REPO_ROOT/challenge-2-iac"
  terraform workspace select "$TEAM_ID" >/dev/null
  echo "URL:      $(terraform output -raw entrypoint_url)"
  echo "Username: $(terraform output -raw player_username)"
  echo "Password: $(terraform output -raw player_password)"
  echo "Flag:     $(terraform output -raw qa_verification_flag)"
)
