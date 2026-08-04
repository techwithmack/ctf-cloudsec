#!/usr/bin/env bash
# Auto-destroys any team environment that has been live longer than the TTL
# (default 1 hour - see the 2026-08 Discord thread with CTF Ops/Techops:
# self-serve provisioning needs a hard time limit so nothing sits around
# indefinitely). Intended to run on a schedule (see
# .github/workflows/reap-teams.yml) but safe to run manually/locally too.
#
# Usage: scripts/reap-teams.sh [ttl_seconds]
#
# "Age" is read straight from AWS (each challenge's ECS service createdAt),
# not from any timestamp Terraform tracks itself - a team's workspace has no
# reliable "when was this applied" value of its own, and the ECS service is
# recreated fresh by every provision (including a from-scratch re-provision of
# the same team_id), so its createdAt is exactly "how long has this
# environment actually been live."
set -euo pipefail

TTL_SECONDS="${1:-3600}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOW_EPOCH=$(date -u +%s)

# AWS returns createdAt as ISO-8601 (e.g. "2026-08-03T10:15:23+00:00").
# python3 is used instead of `date -d`/`date -j` so this runs the same way on
# both GitHub's ubuntu-latest runners and an organizer's Mac.
to_epoch() {
  python3 -c "import sys, datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00')).timestamp()))" "$1"
}

list_team_workspaces() {
  local dir="$1"
  (
    cd "$REPO_ROOT/$dir"
    terraform init -input=false >/dev/null
    terraform workspace list | sed 's/^[* ]*//' | grep -v '^default$' | grep -v '^$'
  )
}

# $1 = cluster name, $2 = service name. Echoes the age in seconds, or nothing
# if the service doesn't exist (team never finished provisioning, or is
# already being torn down).
service_age_seconds() {
  local cluster="$1" service="$2" created
  created=$(aws ecs describe-services \
    --cluster "$cluster" --services "$service" \
    --region us-west-2 \
    --query 'services[0].createdAt' --output text 2>/dev/null || echo "None")

  if [ -z "$created" ] || [ "$created" = "None" ]; then
    return
  fi

  echo $(( NOW_EPOCH - $(to_epoch "$created") ))
}

# $1 = challenge dir, $2 = cluster prefix, $3 = service prefix, $4 = label
reap_challenge() {
  local dir="$1" cluster_prefix="$2" service_prefix="$3" label="$4" team age

  for team in $(list_team_workspaces "$dir"); do
    age=$(service_age_seconds "${cluster_prefix}${team}" "${service_prefix}${team}")
    if [ -z "$age" ]; then
      echo "  $team ($label): no active ECS service, skipping"
      continue
    fi

    echo "  $team ($label): ${age}s old"
    if [ "$age" -ge "$TTL_SECONDS" ]; then
      echo "  $team: past ${TTL_SECONDS}s TTL, destroying"
      # Explicitly tested (not left to `set -e`) so one team's destroy
      # failure - e.g. a state lock held by a concurrent manual
      # provision/destroy run for the same team_id - doesn't abort the whole
      # pass and skip every other team still due for reaping. It'll be
      # picked up again on the next scheduled tick.
      if ! "$REPO_ROOT/scripts/remove-team.sh" "$team" --yes; then
        echo "  $team: destroy FAILED, will retry next pass" >&2
      fi
    fi
  done
}

echo "=== Reaping teams older than ${TTL_SECONDS}s ==="

# Challenge 1 and Challenge 2 are provisioned together for a given team_id
# (scripts/add-team.sh), but each challenge's TTL is checked independently -
# remove-team.sh tears down both challenges for a team regardless of which
# one's loop below triggers it, so a team destroyed via one challenge's check
# simply won't appear in the other challenge's workspace listing.
reap_challenge "challenge-1-iac" "aikido-ctf-cluster-" "entrypoint-service-" "challenge 1"
reap_challenge "challenge-2-iac" "shadow-pipeline-cluster-" "forgejo-service-" "challenge 2"

echo "=== Reap pass complete ==="
