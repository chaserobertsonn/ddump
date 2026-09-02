#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <channel> <manifest-json> <signature-json> <expected-manifest-sha256> <expected-current-etag|NONE> <output-dir>" >&2
}

if [[ "$#" -ne 6 ]]; then
  usage
  exit 2
fi

channel="$1"
manifest="$2"
signature_json="$3"
expected_manifest_sha="$4"
expected_current_etag="$5"
output_dir="$6"
safe_channel "$channel"
[[ "$channel" != "private-preview" ]] || die "private preview does not publish an appcast"
require_file "$manifest"
require_file "$signature_json"
mkdir -p "$output_dir"

"${SCRIPT_DIR}/verify-release-manifest.sh" "$manifest" "$signature_json" "$expected_manifest_sha"

manifest_channel="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["channel"])' "$manifest")"
[[ "$manifest_channel" == "$channel" ]] || die "manifest channel ${manifest_channel} does not match ${channel}"

appcast="${output_dir}/appcast.xml"
"${SCRIPT_DIR}/generate-appcast.sh" "$manifest" "$appcast"
"${SCRIPT_DIR}/sign-sparkle-feed.sh" "$appcast"
/usr/bin/python3 - "$appcast" <<'PY'
import sys
import xml.etree.ElementTree as ET

ET.parse(sys.argv[1])
PY
appcast_sha="$(sha256_file "$appcast")"
appcast_size="$(file_size "$appcast")"

current_key="appcasts/${channel}/appcast.xml"
backup_key="appcasts/${channel}/rollback/$(date -u +%Y%m%dT%H%M%SZ)-${appcast_sha}.previous.xml"
current_feed="${output_dir}/previous-appcast.xml"

if [[ "$expected_current_etag" != "NONE" ]]; then
  "${SCRIPT_DIR}/r2-object.py" get --key "$current_key" --output "$current_feed"
  "${SCRIPT_DIR}/r2-object.py" put --key "$backup_key" --file "$current_feed" --content-type "application/xml; charset=utf-8" --cache-control "public, max-age=31536000, immutable" --if-none-match '*'
  "${SCRIPT_DIR}/r2-object.py" put --key "$current_key" --file "$appcast" --content-type "application/xml; charset=utf-8" --cache-control "no-cache, must-revalidate" --if-match "$expected_current_etag"
else
  "${SCRIPT_DIR}/r2-object.py" put --key "$current_key" --file "$appcast" --content-type "application/xml; charset=utf-8" --cache-control "no-cache, must-revalidate" --if-none-match '*'
fi

require_env DDUMP_UPDATES_BASE_URL
feed_url="${DDUMP_UPDATES_BASE_URL%/}/${channel}/appcast.xml"
readback_json="${output_dir}/appcast-readback.json"
"${SCRIPT_DIR}/http-readback.sh" "$feed_url" "$appcast_sha" "$appcast_size" "$readback_json" "application/xml" "must-revalidate"

/usr/bin/python3 - "$output_dir/promotion-provenance.json" "$channel" "$expected_manifest_sha" "$expected_current_etag" "$appcast_sha" "$backup_key" <<'PY'
import json
import os
import sys

path, channel, manifest_sha, expected_etag, appcast_sha, backup_key = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "schema": "ddump.feed-promotion.v1",
            "channel": channel,
            "manifest_sha256": manifest_sha,
            "expected_previous_etag": expected_etag,
            "new_appcast_sha256": appcast_sha,
            "rollback_backup_key": None if expected_etag == "NONE" else backup_key,
            "approver": os.environ.get("GITHUB_ACTOR", ""),
            "workflow_run_id": os.environ.get("GITHUB_RUN_ID", ""),
        },
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
PY

note "${channel} appcast promoted with CAS"
