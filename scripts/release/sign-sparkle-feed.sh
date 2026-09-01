#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <appcast-xml>" >&2
  exit 2
fi

appcast="$1"
require_file "$appcast"
require_env DDUMP_SPARKLE_EDDSA_PRIVATE_KEY_B64

sign_update="${DDUMP_SPARKLE_SIGN_UPDATE:-}"
if [[ -z "$sign_update" ]]; then
  sparkle_root="$("${PROJECT_DIR}/scripts/fetch-sparkle.sh")"
  sign_update="${sparkle_root}/bin/sign_update"
fi
[[ -x "$sign_update" ]] || die "Sparkle sign_update not found"

work_dir="$(tmpdir)"
trap 'rm -rf "$work_dir"' EXIT
private_key="${work_dir}/sparkle_ed25519_private_key"
printf '%s' "$DDUMP_SPARKLE_EDDSA_PRIVATE_KEY_B64" | base64_decode_to_file "$private_key"
chmod 600 "$private_key"

"$sign_update" --ed-key-file "$private_key" "$appcast" >/dev/null
"$sign_update" --verify --ed-key-file "$private_key" "$appcast" >/dev/null
note "Sparkle appcast EdDSA signature generated and verified"
