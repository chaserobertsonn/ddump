#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <signed-output-dir>" >&2
}

if [[ "$#" -ne 1 ]]; then
  usage
  exit 2
fi

signed_dir="$1"
require_dir "$signed_dir"
require_env DDUMP_VERSION
require_env DDUMP_CHANNEL
require_env DDUMP_DOWNLOADS_BASE_URL
safe_version "$DDUMP_VERSION"
safe_channel "$DDUMP_CHANNEL"
[[ "$DDUMP_CHANNEL" != "stable" ]] || die "candidate upload cannot target stable"

require_file "${signed_dir}/DDump-${DDUMP_VERSION}.dmg"
require_file "${signed_dir}/release-manifest.body.json"
require_file "${signed_dir}/release-manifest.json"
require_file "${signed_dir}/release-authorization.json"

case "$DDUMP_CHANNEL" in
  private-preview) prefix="releases/candidates/${DDUMP_SOURCE_SHA:-unknown}/${DDUMP_VERSION}" ;;
  beta) prefix="releases/beta/${DDUMP_VERSION}" ;;
esac

dmg="${signed_dir}/DDump-${DDUMP_VERSION}.dmg"
dmg_sha="$(sha256_file "$dmg")"
dmg_size="$(file_size "$dmg")"
sha_file="${signed_dir}/DDump-${DDUMP_VERSION}.dmg.sha256"
printf '%s  %s\n' "$dmg_sha" "DDump-${DDUMP_VERSION}.dmg" >"$sha_file"

asset_url="${DDUMP_DOWNLOADS_BASE_URL%/}/${DDUMP_CHANNEL}/${DDUMP_VERSION}/DDump-${DDUMP_VERSION}.dmg"
manifest_url="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifact"].get("url",""))' "${signed_dir}/release-manifest.json")"
manifest_key="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("manifest_key",""))' "${signed_dir}/release-manifest.json")"
[[ "$manifest_url" == "$asset_url" ]] || die "signed manifest artifact URL does not match upload target"
[[ "$manifest_key" == "${prefix}/release-manifest.json" ]] || die "signed manifest key does not match upload target"

note "uploading immutable candidate assets"
"${SCRIPT_DIR}/r2-object.py" put --key "${prefix}/DDump-${DDUMP_VERSION}.dmg" --file "$dmg" --content-type "application/x-apple-diskimage" --cache-control "public, max-age=31536000, immutable" --if-none-match '*'
"${SCRIPT_DIR}/r2-object.py" put --key "${prefix}/DDump-${DDUMP_VERSION}.dmg.sha256" --file "$sha_file" --content-type "text/plain; charset=utf-8" --cache-control "public, max-age=31536000, immutable" --if-none-match '*'
"${SCRIPT_DIR}/r2-object.py" put --key "${prefix}/release-manifest.json" --file "${signed_dir}/release-manifest.json" --content-type "application/json; charset=utf-8" --cache-control "public, max-age=31536000, immutable" --if-none-match '*'
"${SCRIPT_DIR}/r2-object.py" put --key "${prefix}/release-authorization.json" --file "${signed_dir}/release-authorization.json" --content-type "application/json; charset=utf-8" --cache-control "public, max-age=31536000, immutable" --if-none-match '*'

readback_json="${signed_dir}/candidate-readback.json"
if [[ "$DDUMP_CHANNEL" == "private-preview" && -z "${DDUMP_PRIVATE_PREVIEW_READBACK_URL:-}" ]]; then
  note "private preview uploaded without anonymous readback URL"
else
  readback_url="${DDUMP_PRIVATE_PREVIEW_READBACK_URL:-$asset_url}"
  "${SCRIPT_DIR}/http-readback.sh" "$readback_url" "$dmg_sha" "$dmg_size" "$readback_json" "application/x-apple-diskimage" "immutable"
  note "candidate asset uploaded and externally verified"
fi
