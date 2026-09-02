#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <beta-manifest-r2-key> <expected-beta-manifest-sha256> <expected-current-stable-etag|NONE> <output-dir>" >&2
}

if [[ "$#" -ne 4 ]]; then
  usage
  exit 2
fi

beta_manifest_key="$1"
expected_beta_manifest_sha="$2"
expected_current_etag="$3"
output_dir="$4"
require_env DDUMP_DOWNLOADS_BASE_URL
require_env DDUMP_STABLE_ROLLOUT
require_env DDUMP_BETA_EVIDENCE_URL
require_env DDUMP_STABLE_APPROVAL_NOTES
phased_rollout_interval="${DDUMP_PHASED_ROLLOUT_INTERVAL:-0}"
[[ "$phased_rollout_interval" =~ ^[0-9]+$ ]] || die "DDUMP_PHASED_ROLLOUT_INTERVAL must be a non-negative integer"
[[ "${DDUMP_ROLLBACK_READY:-0}" == "1" ]] || die "DDUMP_ROLLBACK_READY must be 1"
[[ "${DDUMP_FORWARD_FIX_READY:-0}" == "1" ]] || die "DDUMP_FORWARD_FIX_READY must be 1"
mkdir -p "$output_dir"

full_beta_manifest="${output_dir}/beta-release-manifest.json"
beta_body="${output_dir}/beta-release-manifest.body.json"
beta_auth="${output_dir}/beta-release-authorization.json"
"${SCRIPT_DIR}/r2-object.py" get --key "$beta_manifest_key" --output "$full_beta_manifest"
"${SCRIPT_DIR}/split-release-manifest.sh" "$full_beta_manifest" "$beta_body" "$beta_auth"
"${SCRIPT_DIR}/verify-release-manifest.sh" "$beta_body" "$beta_auth" "$expected_beta_manifest_sha"

beta_channel="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["channel"])' "$beta_body")"
[[ "$beta_channel" == "beta" ]] || die "stable promotion requires a beta manifest, found ${beta_channel}"

version="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$beta_body")"
safe_version "$version"
beta_dmg_url="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifact"]["url"])' "$beta_body")"
expected_dmg_sha="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifact"]["sha256"])' "$beta_body")"
expected_dmg_size="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifact"]["size"])' "$beta_body")"
require_https_url "$beta_dmg_url"
require_cmd curl

dmg="${output_dir}/DDump-${version}.dmg"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --output "$dmg" "$beta_dmg_url"
[[ "$(sha256_file "$dmg")" == "$expected_dmg_sha" ]] || die "beta artifact digest mismatch"
[[ "$(file_size "$dmg")" == "$expected_dmg_size" ]] || die "beta artifact size mismatch"

stable_prefix="releases/stable/${version}"
stable_url="${DDUMP_DOWNLOADS_BASE_URL%/}/stable/${version}/DDump-${version}.dmg"
sha_file="${output_dir}/DDump-${version}.dmg.sha256"
printf '%s  %s\n' "$expected_dmg_sha" "DDump-${version}.dmg" >"$sha_file"

note "copying exact beta artifact bytes to stable immutable key"
"${SCRIPT_DIR}/r2-object.py" put --key "${stable_prefix}/DDump-${version}.dmg" --file "$dmg" --content-type "application/x-apple-diskimage" --cache-control "public, max-age=31536000, immutable" --if-none-match '*'
"${SCRIPT_DIR}/r2-object.py" put --key "${stable_prefix}/DDump-${version}.dmg.sha256" --file "$sha_file" --content-type "text/plain; charset=utf-8" --cache-control "public, max-age=31536000, immutable" --if-none-match '*'
"${SCRIPT_DIR}/http-readback.sh" "$stable_url" "$expected_dmg_sha" "$expected_dmg_size" "${output_dir}/stable-asset-readback.json" "application/x-apple-diskimage" "immutable"

stable_body="${output_dir}/stable-release-manifest.body.json"
/usr/bin/python3 - "$beta_body" "$stable_body" "$stable_url" "$stable_prefix" "$expected_beta_manifest_sha" <<'PY'
import json
import os
import sys

source, output, url, prefix, beta_manifest_sha = sys.argv[1:]
with open(source, "r", encoding="utf-8") as handle:
    data = json.load(handle)
version = data["version"]
data["channel"] = "stable"
data["artifact"]["url"] = url
data["artifact"]["r2_key"] = f"{prefix}/DDump-{version}.dmg"
data["artifact"]["sha256_key"] = f"{prefix}/DDump-{version}.dmg.sha256"
data["manifest_key"] = f"{prefix}/release-manifest.json"
phased_interval = int(os.environ.get("DDUMP_PHASED_ROLLOUT_INTERVAL", "0"))
data["phased_rollout_interval"] = phased_interval or None
data["stable_promotion"] = {
    "beta_manifest_sha256": beta_manifest_sha,
    "beta_evidence_url": os.environ["DDUMP_BETA_EVIDENCE_URL"],
    "stable_rollout": os.environ["DDUMP_STABLE_ROLLOUT"],
    "approval_notes": os.environ["DDUMP_STABLE_APPROVAL_NOTES"],
    "rollback_ready": True,
    "forward_fix_ready": True,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

stable_auth="${output_dir}/stable-release-authorization.json"
"${SCRIPT_DIR}/sign-release-manifest.sh" "$stable_body" "$stable_auth"
stable_manifest_sha="$(sha256_file "$stable_body")"
full_stable_manifest="${output_dir}/stable-release-manifest.json"
/usr/bin/python3 - "$stable_body" "$stable_auth" "$full_stable_manifest" <<'PY'
import json
import sys

body_path, auth_path, output_path = sys.argv[1:]
with open(body_path, "r", encoding="utf-8") as handle:
    body = json.load(handle)
with open(auth_path, "r", encoding="utf-8") as handle:
    auth = json.load(handle)
body["release_authorization"] = auth
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(body, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

"${SCRIPT_DIR}/r2-object.py" put --key "${stable_prefix}/release-manifest.json" --file "$full_stable_manifest" --content-type "application/json; charset=utf-8" --cache-control "public, max-age=31536000, immutable" --if-none-match '*'
"${SCRIPT_DIR}/promote-feed.sh" stable "$stable_body" "$stable_auth" "$stable_manifest_sha" "$expected_current_etag" "$output_dir"
note "stable promotion complete without rebuild"
