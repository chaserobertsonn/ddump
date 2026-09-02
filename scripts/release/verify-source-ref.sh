#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_env DDUMP_SOURCE_SHA
require_cmd git

[[ "$DDUMP_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || die "DDUMP_SOURCE_SHA must be a full commit SHA"
current_sha="$(git rev-parse HEAD)"
[[ "$current_sha" == "$DDUMP_SOURCE_SHA" ]] || die "checkout SHA ${current_sha} does not match ${DDUMP_SOURCE_SHA}"

protected_ref="${DDUMP_PROTECTED_RELEASE_REF:-origin/main}"
git fetch --no-tags --depth=1 origin main >/dev/null 2>&1 || true
if git rev-parse --verify "$protected_ref" >/dev/null 2>&1; then
  git merge-base --is-ancestor "$DDUMP_SOURCE_SHA" "$protected_ref" || die "${DDUMP_SOURCE_SHA} is not reachable from ${protected_ref}"
fi

if [[ -n "${DDUMP_REQUIRED_CHECKS:-}" && -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  require_cmd gh
  IFS=',' read -r -a required_checks <<<"$DDUMP_REQUIRED_CHECKS"
  checks_json="$(gh api "repos/${GITHUB_REPOSITORY}/commits/${DDUMP_SOURCE_SHA}/check-runs" --paginate)"
  for required in "${required_checks[@]}"; do
    required="$(printf '%s' "$required" | sed 's/^ *//; s/ *$//')"
    [[ -n "$required" ]] || continue
    CHECKS_JSON="$checks_json" /usr/bin/python3 - "$required" <<'PY'
import json
import os
import sys

required = sys.argv[1]
payload = json.loads(os.environ["CHECKS_JSON"])
for run in payload.get("check_runs", []):
    if run.get("name") == required and run.get("conclusion") == "success":
        raise SystemExit(0)
print(f"missing successful required check: {required}", file=sys.stderr)
raise SystemExit(1)
PY
  done
fi

note "source ref verified"
