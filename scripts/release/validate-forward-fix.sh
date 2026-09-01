#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <bad-version> <forward-fix-version>" >&2
}

if [[ "$#" -ne 2 ]]; then
  usage
  exit 2
fi

bad="$1"
fix="$2"
safe_version "$bad"
safe_version "$fix"

/usr/bin/python3 - "$bad" "$fix" <<'PY'
import re
import sys

def parts(version):
    out = []
    for part in re.split(r"[._-]", version):
        out.append((0, int(part)) if part.isdigit() else (1, part))
    return out

bad, fix = sys.argv[1:]
if parts(fix) <= parts(bad):
    print("forward-fix version must be higher than the installed bad version", file=sys.stderr)
    raise SystemExit(1)
PY

note "forward-fix version ordering verified"
