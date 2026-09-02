#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <candidate-manifest-r2-key> <expected-manifest-sha256> <expected-current-beta-etag|NONE> <output-dir>" >&2
}

if [[ "$#" -ne 4 ]]; then
  usage
  exit 2
fi

manifest_key="$1"
expected_manifest_sha="$2"
expected_current_etag="$3"
output_dir="$4"
require_env DDUMP_BETA_ROLLOUT
mkdir -p "$output_dir"

full_manifest="${output_dir}/release-manifest.json"
body_manifest="${output_dir}/release-manifest.body.json"
auth_json="${output_dir}/release-authorization.json"
"${SCRIPT_DIR}/r2-object.py" get --key "$manifest_key" --output "$full_manifest"
"${SCRIPT_DIR}/split-release-manifest.sh" "$full_manifest" "$body_manifest" "$auth_json"
"${SCRIPT_DIR}/verify-release-manifest.sh" "$body_manifest" "$auth_json" "$expected_manifest_sha"

channel="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["channel"])' "$body_manifest")"
[[ "$channel" == "beta" ]] || die "beta promotion requires a beta manifest, found ${channel}"

"${SCRIPT_DIR}/promote-feed.sh" beta "$body_manifest" "$auth_json" "$expected_manifest_sha" "$expected_current_etag" "$output_dir"

/usr/bin/python3 - "$output_dir/beta-rollout.json" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(
        {
            "schema": "ddump.beta-rollout.v1",
            "rollout": os.environ["DDUMP_BETA_ROLLOUT"],
            "release_notes_approved": os.environ.get("DDUMP_RELEASE_NOTES_APPROVED", "false"),
            "approver": os.environ.get("GITHUB_ACTOR", ""),
            "workflow_run_id": os.environ.get("GITHUB_RUN_ID", ""),
        },
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
PY

note "beta promotion complete"
