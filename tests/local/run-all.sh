#!/usr/bin/env bash
# Runs every local check: static validation, then both challenges' full solve paths.
# Needs Docker, Terraform, python3 + PyYAML, jq, aws CLI, git. No AWS account/credentials used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
rc=0
run() { echo; echo "######## $1"; shift; if "$@"; then echo "-> OK"; else echo "-> FAILED"; rc=1; fi; }

static() {
  local ok=0 d f
  for f in "$ROOT"/scripts/*.sh "$ROOT"/tests/local/*.sh; do bash -n "$f" || ok=1; done
  for f in "$ROOT"/.github/workflows/*.yml; do python3 -c "import yaml,sys;yaml.safe_load(open(sys.argv[1]))" "$f" || { echo "bad YAML: $f"; ok=1; }; done
  # Both challenge stacks and every bootstrap must stay valid Terraform. `init -backend=false`
  # because validation needs providers but must not touch the shared remote state.
  for d in challenge-1-iac challenge-1-iac/bootstrap challenge-2-iac challenge-2-iac/bootstrap ci-bootstrap; do
    ( cd "$ROOT/$d" && terraform init -backend=false -input=false >/dev/null 2>&1 && terraform validate -no-color >/dev/null ) \
      && echo "terraform validate ok: $d" || { echo "terraform validate FAILED: $d"; ok=1; }
    ( cd "$ROOT/$d" && terraform fmt -check >/dev/null ) || { echo "terraform fmt needed: $d"; ok=1; }
  done
  return $ok
}

run "static checks" static
run "challenge 1 solve" "$ROOT/tests/local/challenge1.sh"
run "challenge 2 solve" "$ROOT/tests/local/challenge2.sh"
echo; [ $rc -eq 0 ] && echo "ALL LOCAL CHECKS PASSED" || echo "SOME LOCAL CHECKS FAILED"
exit $rc
