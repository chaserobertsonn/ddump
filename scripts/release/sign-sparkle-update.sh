#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <dmg-path> <output-json>" >&2
}

if [[ "$#" -ne 2 ]]; then
  usage
  exit 2
fi

dmg_path="$1"
output_json="$2"
require_file "$dmg_path"
require_env DDUMP_SPARKLE_EDDSA_PRIVATE_KEY_B64

sign_update="${DDUMP_SPARKLE_SIGN_UPDATE:-}"
if [[ -z "$sign_update" ]]; then
  for candidate in \
    "${PROJECT_DIR:-}/.build/dependencies/Sparkle-2.9.6/bin/sign_update" \
    "${PROJECT_DIR:-}/vendor/Sparkle/bin/sign_update" \
    "/Applications/Sparkle/bin/sign_update" \
    "/opt/homebrew/bin/sign_update" \
    "/usr/local/bin/sign_update"; do
    if [[ -x "$candidate" ]]; then
      sign_update="$candidate"
      break
    fi
  done
fi
if [[ -z "$sign_update" && -x "${PROJECT_DIR:-}/scripts/fetch-sparkle.sh" ]]; then
  sparkle_root="$("${PROJECT_DIR}/scripts/fetch-sparkle.sh")"
  if [[ -x "${sparkle_root}/bin/sign_update" ]]; then
    sign_update="${sparkle_root}/bin/sign_update"
  fi
fi
[[ -x "$sign_update" ]] || die "Sparkle sign_update not found; set DDUMP_SPARKLE_SIGN_UPDATE"

work_dir="$(tmpdir)"
trap 'rm -rf "$work_dir"' EXIT
private_key="${work_dir}/sparkle_ed25519_private_key"
printf '%s' "$DDUMP_SPARKLE_EDDSA_PRIVATE_KEY_B64" | base64_decode_to_file "$private_key"
chmod 600 "$private_key"

signature_output="${work_dir}/signature.txt"
"$sign_update" "$dmg_path" --ed-key-file "$private_key" >"$signature_output"
ed_signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$signature_output" | head -1)"
length="$(sed -n 's/.*length="\([0-9][0-9]*\)".*/\1/p' "$signature_output" | head -1)"
if [[ -z "$ed_signature" ]]; then
  ed_signature="$(awk '/sparkle:edSignature/ {print $NF; exit}' "$signature_output")"
fi
[[ -n "$ed_signature" ]] || die "Sparkle EdDSA signature was not produced"
[[ -n "$length" ]] || length="$(file_size "$dmg_path")"

/usr/bin/python3 - "$output_json" "$ed_signature" "$length" <<'PY'
import json
import sys

path, signature, length = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {"sparkle_ed_signature": signature, "sparkle_length": int(length)},
        handle,
        indent=2,
        sort_keys=True,
    )
    handle.write("\n")
PY

note "Sparkle EdDSA signature generated"
