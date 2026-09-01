#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

workflow_dir="${1:-.github/workflows}"
require_dir "$workflow_dir"

fail=0
while IFS= read -r line; do
  file="${line%%:*}"
  text="${line#*:}"
  uses_ref="$(printf '%s\n' "$text" | sed -nE 's/.*uses:[[:space:]]*([^[:space:]#]+).*/\1/p')"
  [[ -n "$uses_ref" ]] || continue
  if [[ ! "$uses_ref" =~ @([0-9a-f]{40})$ ]]; then
    echo "unpinned Action in ${file}: ${uses_ref}" >&2
    fail=1
  fi
  if [[ "$text" != *"#"* ]]; then
    echo "missing version comment for Action in ${file}: ${uses_ref}" >&2
    fail=1
  fi
done < <(grep -RIn 'uses:' "$workflow_dir" || true)

[[ "$fail" == "0" ]] || exit 1
note "GitHub Action pins verified"
