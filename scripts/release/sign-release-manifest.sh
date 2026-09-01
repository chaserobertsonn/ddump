#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <manifest-json> <output-signature-json>" >&2
}

if [[ "$#" -ne 2 ]]; then
  usage
  exit 2
fi

manifest="$1"
output_json="$2"
require_file "$manifest"
require_cmd openssl
require_env DDUMP_RELEASE_AUTH_PRIVATE_KEY_B64

work_dir="$(tmpdir)"
trap 'rm -rf "$work_dir"' EXIT
private_key="${work_dir}/release-auth-private.pem"
signature="${work_dir}/manifest.sig"
printf '%s' "$DDUMP_RELEASE_AUTH_PRIVATE_KEY_B64" | base64_decode_to_file "$private_key"
chmod 600 "$private_key"

openssl dgst -sha256 -sign "$private_key" -out "$signature" "$manifest"
manifest_sha="$(sha256_file "$manifest")"
signature_b64="$(/usr/bin/base64 <"$signature" | tr -d '\n')"

/usr/bin/python3 - "$output_json" "$manifest_sha" "$signature_b64" <<'PY'
import json
import sys

path, digest, signature = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "manifest_sha256": digest,
            "release_authorization_signature": signature,
            "release_authorization_algorithm": "openssl-dgst-sha256",
        },
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
PY

note "release authorization signature generated"
