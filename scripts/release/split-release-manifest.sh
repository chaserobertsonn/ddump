#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <release-manifest-json> <body-output-json> <auth-output-json>" >&2
}

if [[ "$#" -ne 3 ]]; then
  usage
  exit 2
fi

manifest="$1"
body="$2"
auth="$3"
require_file "$manifest"

/usr/bin/python3 - "$manifest" "$body" "$auth" <<'PY'
import json
import sys

manifest_path, body_path, auth_path = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
auth = data.pop("release_authorization", None)
if not auth:
    raise SystemExit("manifest is missing release_authorization")
with open(body_path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\n")
with open(auth_path, "w", encoding="utf-8") as handle:
    json.dump(auth, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

note "release manifest split for verification"
