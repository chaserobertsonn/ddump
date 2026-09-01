#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <manifest-json> <signature-json> <expected-manifest-sha256>" >&2
}

if [[ "$#" -ne 3 ]]; then
  usage
  exit 2
fi

manifest="$1"
signature_json="$2"
expected_sha="$3"
require_file "$manifest"
require_file "$signature_json"
require_cmd openssl
require_env DDUMP_RELEASE_AUTH_PUBLIC_KEY_B64

actual_sha="$(sha256_file "$manifest")"
[[ "$actual_sha" == "$expected_sha" ]] || die "manifest digest mismatch"

work_dir="$(tmpdir)"
trap 'rm -rf "$work_dir"' EXIT
public_key="${work_dir}/release-auth-public.pem"
signature="${work_dir}/manifest.sig"
printf '%s' "$DDUMP_RELEASE_AUTH_PUBLIC_KEY_B64" | base64_decode_to_file "$public_key"
/usr/bin/python3 - "$signature_json" "$signature" <<'PY'
import base64
import json
import sys

signature_json, output = sys.argv[1:]
with open(signature_json, "r", encoding="utf-8") as handle:
    data = json.load(handle)
with open(output, "wb") as handle:
    handle.write(base64.b64decode(data["release_authorization_signature"]))
PY

openssl dgst -sha256 -verify "$public_key" -signature "$signature" "$manifest" >/dev/null
note "release authorization signature verified"
