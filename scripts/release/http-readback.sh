#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <url> <expected-sha256> <expected-size> <output-json> [expected-content-type-prefix] [expected-cache-control-substring]" >&2
}

if [[ "$#" -lt 4 || "$#" -gt 6 ]]; then
  usage
  exit 2
fi

url="$1"
expected_sha="$2"
expected_size="$3"
output_json="$4"
expected_content_type="${5:-}"
expected_cache_control="${6:-}"
require_https_url "$url"
require_cmd curl

work_dir="$(tmpdir)"
trap 'rm -rf "$work_dir"' EXIT
headers="${work_dir}/headers.txt"
body="${work_dir}/body.bin"

http_code="$(curl --proto '=https' --tlsv1.2 --fail-with-body --silent --show-error \
  --location --dump-header "$headers" --output "$body" --write-out '%{http_code}' "$url")"
[[ "$http_code" == "200" ]] || die "readback returned HTTP ${http_code}"

actual_sha="$(sha256_file "$body")"
actual_size="$(file_size "$body")"
[[ "$actual_sha" == "$expected_sha" ]] || die "readback SHA-256 mismatch"
[[ "$actual_size" == "$expected_size" ]] || die "readback size mismatch"

content_type="$(awk 'BEGIN{IGNORECASE=1} /^content-type:/ { sub(/\r$/, ""); print substr($0, index($0,$2)); exit }' "$headers")"
etag="$(awk 'BEGIN{IGNORECASE=1} /^etag:/ { sub(/\r$/, ""); print $2; exit }' "$headers")"
cache_control="$(awk 'BEGIN{IGNORECASE=1} /^cache-control:/ { sub(/\r$/, ""); print substr($0, index($0,$2)); exit }' "$headers")"
[[ -n "$content_type" ]] || die "readback missing Content-Type"
[[ -n "$etag" ]] || die "readback missing ETag"
if [[ -n "$expected_content_type" && "$content_type" != "$expected_content_type"* ]]; then
  die "readback Content-Type mismatch: ${content_type}"
fi
if [[ -n "$expected_cache_control" && "$cache_control" != *"$expected_cache_control"* ]]; then
  die "readback Cache-Control mismatch: ${cache_control}"
fi

/usr/bin/python3 - "$output_json" "$url" "$actual_sha" "$actual_size" "$content_type" "$etag" "$cache_control" <<'PY'
import json
import sys

path, url, sha, size, content_type, etag, cache_control = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "url": url,
            "http_status": 200,
            "sha256": sha,
            "size": int(size),
            "content_type": content_type,
            "etag": etag,
            "cache_control": cache_control,
        },
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
PY

note "readback verified ${url}"
