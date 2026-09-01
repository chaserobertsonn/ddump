#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <channel> <rollback-r2-key> <expected-current-etag> <output-dir>" >&2
}

if [[ "$#" -ne 4 ]]; then
  usage
  exit 2
fi

channel="$1"
rollback_key="$2"
expected_current_etag="$3"
output_dir="$4"
safe_channel "$channel"
[[ "$channel" != "private-preview" ]] || die "private preview has no appcast rollback"
[[ -n "$rollback_key" && "$rollback_key" == appcasts/"$channel"/rollback/* ]] || die "rollback key must be an appcasts/${channel}/rollback object"
[[ -n "$expected_current_etag" && "$expected_current_etag" != "NONE" ]] || die "rollback requires the current feed ETag"
mkdir -p "$output_dir"

rollback_feed="${output_dir}/rollback-appcast.xml"
"${SCRIPT_DIR}/r2-object.py" get --key "$rollback_key" --output "$rollback_feed"
rollback_sha="$(sha256_file "$rollback_feed")"
rollback_size="$(file_size "$rollback_feed")"

"${SCRIPT_DIR}/r2-object.py" put --key "appcasts/${channel}/appcast.xml" --file "$rollback_feed" --content-type "application/xml; charset=utf-8" --cache-control "no-cache, must-revalidate" --if-match "$expected_current_etag"

require_env DDUMP_UPDATES_BASE_URL
"${SCRIPT_DIR}/http-readback.sh" "${DDUMP_UPDATES_BASE_URL%/}/${channel}/appcast.xml" "$rollback_sha" "$rollback_size" "${output_dir}/rollback-readback.json" "application/xml" "must-revalidate"
note "${channel} appcast rolled back before install"
