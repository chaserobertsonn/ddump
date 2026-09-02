#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <candidate-build-tar.gz> <output-dir>" >&2
}

if [[ "$#" -ne 2 ]]; then
  usage
  exit 2
fi

candidate_tar="$1"
output_dir="$2"
require_file "$candidate_tar"
require_env DDUMP_VERSION
require_env DDUMP_BUILD
require_env DDUMP_CHANNEL
require_env DDUMP_SOURCE_SHA
require_env DDUMP_SIGN_IDENTITY
require_env DDUMP_DEVELOPER_ID_APPLICATION_CERT_P12_B64
require_env DDUMP_DEVELOPER_ID_APPLICATION_CERT_PASSWORD
require_env DDUMP_NOTARYTOOL_KEY_ID
require_env DDUMP_NOTARYTOOL_ISSUER_ID
require_env DDUMP_NOTARYTOOL_PRIVATE_KEY_P8_B64
safe_version "$DDUMP_VERSION"
safe_version "$DDUMP_BUILD"
safe_channel "$DDUMP_CHANNEL"
[[ "${DDUMP_PHASED_ROLLOUT_INTERVAL:-0}" =~ ^[0-9]+$ ]] || die "DDUMP_PHASED_ROLLOUT_INTERVAL must be a non-negative integer"
[[ "$DDUMP_SIGN_IDENTITY" == Developer\ ID\ Application:* ]] || die "DDUMP_SIGN_IDENTITY must be a Developer ID Application identity"

require_cmd codesign
require_cmd ditto
require_cmd hdiutil
require_cmd lipo
require_cmd security
require_cmd spctl
require_cmd xcrun

work_dir="$(tmpdir)"
keychain_dir="$(tmpdir)"
keychain="${keychain_dir}/ddump-release.keychain-db"
notary_key="${keychain_dir}/notary-api-key.p8"
keychain_password="${DDUMP_KEYCHAIN_PASSWORD:-${RUNNER_TEMP:-$keychain_dir}}"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work_dir" "$keychain_dir"
}
trap cleanup EXIT

note "preparing temporary signing keychain"
printf '%s' "$DDUMP_DEVELOPER_ID_APPLICATION_CERT_P12_B64" | base64_decode_to_file "${keychain_dir}/developer-id.p12"
printf '%s' "$DDUMP_NOTARYTOOL_PRIVATE_KEY_P8_B64" | base64_decode_to_file "$notary_key"
chmod 600 "${keychain_dir}/developer-id.p12" "$notary_key"
security create-keychain -p "$keychain_password" "$keychain" >/dev/null
security set-keychain-settings -lut 21600 "$keychain" >/dev/null
security unlock-keychain -p "$keychain_password" "$keychain" >/dev/null
security import "${keychain_dir}/developer-id.p12" -k "$keychain" -P "$DDUMP_DEVELOPER_ID_APPLICATION_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" >/dev/null
security find-identity -v -p codesigning "$keychain" | grep -F "$DDUMP_SIGN_IDENTITY" >/dev/null || die "Developer ID identity not available in temporary keychain"

note "unpacking exact candidate artifact"
tar -xzf "$candidate_tar" -C "$work_dir"
app_path="${work_dir}/DDump.app"
root_dir="${work_dir}/dmg-root"
installer_path="${root_dir}/Install DDump.app"
payload_app_path="${installer_path}/Contents/Resources/Payload/app/DDump.app"
require_dir "$app_path"
require_dir "$installer_path"
require_dir "$payload_app_path"

verify_bundle_metadata "$app_path" "$DDUMP_APP_BUNDLE_ID" "DDump.app"
verify_bundle_metadata "$payload_app_path" "$DDUMP_APP_BUNDLE_ID" "payload DDump.app"
verify_bundle_metadata "$installer_path" "$DDUMP_INSTALLER_BUNDLE_ID" "Install DDump.app"
app_archs="$(verify_binary_architectures "${app_path}/Contents/MacOS/DDump" "DDump.app")"
payload_app_archs="$(verify_binary_architectures "${payload_app_path}/Contents/MacOS/DDump" "payload DDump.app")"
installer_archs="$(verify_binary_architectures "${installer_path}/Contents/MacOS/InstallDDump" "Install DDump.app")"

sign_code_path() {
  local path="$1"
  local preserve=()
  if /usr/bin/codesign -d "$path" >/dev/null 2>&1; then
    preserve=(--preserve-metadata=identifier,entitlements)
  fi
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    "${preserve[@]}" \
    --sign "$DDUMP_SIGN_IDENTITY" \
    "$path"
}

sign_all_macho_children() {
  local bundle="$1"
  while IFS= read -r -d '' child; do
    if file "$child" | grep -q 'Mach-O'; then
      sign_code_path "$child"
    fi
  done < <(find "${bundle}/Contents" -type f \( -perm -111 -o -name '*.dylib' \) -print0)
}

sign_nested_bundles_inside_out() {
  local bundle="$1"
  while IFS= read -r child; do
    sign_code_path "$child"
  done < <(
    find "${bundle}/Contents" -type d \
      \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' -o -name '*.bundle' \) \
      -print \
      | awk '{ path=$0; depth=gsub("/", "/", path); print depth "\t" $0 }' \
      | sort -rn \
      | cut -f2-
  )
}

sign_bundle_with_nested_code() {
  local bundle="$1"
  sign_all_macho_children "$bundle"
  sign_nested_bundles_inside_out "$bundle"
  sign_code_path "$bundle"
  verify_strict_signature "$bundle" "$bundle"
}

sign_installer_preserving_payload() {
  local bundle="$1"
  local executable="${bundle}/Contents/MacOS/InstallDDump"
  require_file "$executable"
  sign_code_path "$executable"
  # The payload DDump.app was already signed, notarized, and stapled. Re-signing
  # any of its children here would invalidate that sealed bundle and ticket.
  sign_code_path "$bundle"
  verify_strict_signature "$bundle" "$bundle"
}

notarize_and_staple() {
  local path="$1"
  local label="$2"
  local result_json="$3"
  local log_json="$4"
  local archive="${work_dir}/${label}.zip"
  /usr/bin/ditto -c -k --keepParent "$path" "$archive"
  xcrun notarytool submit "$archive" \
    --key "$notary_key" \
    --key-id "$DDUMP_NOTARYTOOL_KEY_ID" \
    --issuer "$DDUMP_NOTARYTOOL_ISSUER_ID" \
    --wait \
    --output-format json >"$result_json"
  local submission_id
  local status
  submission_id="$(/usr/bin/plutil -extract id raw -o - "$result_json")"
  status="$(/usr/bin/plutil -extract status raw -o - "$result_json")"
  [[ -n "$submission_id" && "$status" == "Accepted" ]] || die "${label} notarization was not accepted"
  xcrun notarytool log "$submission_id" \
    --key "$notary_key" \
    --key-id "$DDUMP_NOTARYTOOL_KEY_ID" \
    --issuer "$DDUMP_NOTARYTOOL_ISSUER_ID" \
    "$log_json" >/dev/null
  xcrun stapler staple "$path" >/dev/null
  xcrun stapler validate "$path" >/dev/null
  echo "$submission_id"
}

mkdir -p "$output_dir"
app_notary_result="${output_dir}/app-notarization-result.json"
app_notary_log="${output_dir}/app-notarization-log.json"
installer_notary_result="${output_dir}/installer-notarization-result.json"
installer_notary_log="${output_dir}/installer-notarization-log.json"
dmg_notary_result="${output_dir}/dmg-notarization-result.json"
dmg_notary_log="${output_dir}/dmg-notarization-log.json"

note "signing nested app payloads"
sign_bundle_with_nested_code "$app_path"
app_notarization_id="$(notarize_and_staple "$app_path" "DDump-app" "$app_notary_result" "$app_notary_log")"
# The installer must carry the exact app bytes Apple accepted. Signing the
# payload copy independently can change its timestamped CodeDirectory and make
# the notarization ticket for the top-level app inapplicable.
rm -rf "$payload_app_path"
/usr/bin/ditto "$app_path" "$payload_app_path"
xcrun stapler validate "$payload_app_path" >/dev/null
verify_strict_signature "$payload_app_path" "payload DDump.app"

note "signing installer helper app"
sign_installer_preserving_payload "$installer_path"
installer_notarization_id="$(notarize_and_staple "$installer_path" "DDump-installer" "$installer_notary_result" "$installer_notary_log")"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app_path" >/dev/null
/usr/sbin/spctl --assess --type execute --verbose=4 "$installer_path" >/dev/null

final_dmg="${output_dir}/DDump-${DDUMP_VERSION}.dmg"
rm -f "$final_dmg"
note "creating, signing, notarizing, and stapling DMG"
hdiutil create \
  -volname "DDump ${DDUMP_VERSION}" \
  -srcfolder "$root_dir" \
  -ov \
  -format UDZO \
  "$final_dmg" >/dev/null
/usr/bin/codesign --force --timestamp --sign "$DDUMP_SIGN_IDENTITY" "$final_dmg"
/usr/bin/codesign --verify --strict --verbose=2 "$final_dmg" >/dev/null
dmg_notarization_id="$(notarize_and_staple "$final_dmg" "DDump-dmg" "$dmg_notary_result" "$dmg_notary_log")"
hdiutil verify "$final_dmg" >/dev/null
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$final_dmg" >/dev/null
verify_team_id "$final_dmg" "DMG"
verify_designated_requirement "$final_dmg" "DMG"

sparkle_json="${output_dir}/sparkle-signature.json"
"${SCRIPT_DIR}/sign-sparkle-update.sh" "$final_dmg" "$sparkle_json"

dmg_sha="$(sha256_file "$final_dmg")"
dmg_size="$(file_size "$final_dmg")"
signer_subject="$(codesign_details "$app_path" | awk -F= '/^Authority=Developer ID Application:/{print $2; exit}')"
app_requirement="$(/usr/bin/codesign -dr - "$app_path" 2>&1 | sed 's/^.*designated => //')"
installer_requirement="$(/usr/bin/codesign -dr - "$installer_path" 2>&1 | sed 's/^.*designated => //')"
dmg_requirement="$(/usr/bin/codesign -dr - "$final_dmg" 2>&1 | sed 's/^.*designated => //')"

manifest_body="${output_dir}/release-manifest.body.json"
APP_REQUIREMENT="$app_requirement" INSTALLER_REQUIREMENT="$installer_requirement" DMG_REQUIREMENT="$dmg_requirement" /usr/bin/python3 - "$manifest_body" "$sparkle_json" <<PY
import json
import os
import sys

manifest_path, sparkle_path = sys.argv[1:]
with open(sparkle_path, "r", encoding="utf-8") as handle:
    sparkle = json.load(handle)

data = {
    "schema": "ddump.release-manifest.v1",
    "source_sha": os.environ["DDUMP_SOURCE_SHA"],
    "source_branch": os.environ.get("GITHUB_REF_NAME", ""),
    "workflow": os.environ.get("GITHUB_WORKFLOW", ""),
    "workflow_run_id": os.environ.get("GITHUB_RUN_ID", ""),
    "workflow_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
    "version": os.environ["DDUMP_VERSION"],
    "build": os.environ["DDUMP_BUILD"],
    "channel": os.environ["DDUMP_CHANNEL"],
    "minimum_macos": "${DDUMP_MIN_MACOS}",
    "artifact": {
        "filename": "DDump-${DDUMP_VERSION}.dmg",
        "sha256": "${dmg_sha}",
        "size": int("${dmg_size}"),
        "content_type": "application/x-apple-diskimage",
        "url": os.environ.get("DDUMP_ARTIFACT_URL", ""),
        "r2_key": os.environ.get("DDUMP_ARTIFACT_R2_KEY", ""),
        "sha256_key": os.environ.get("DDUMP_ARTIFACT_SHA256_R2_KEY", ""),
    },
    "architectures": {
        "app": "${app_archs}",
        "payload_app": "${payload_app_archs}",
        "installer": "${installer_archs}",
    },
    "apple": {
        "team_id": "${DDUMP_EXPECTED_TEAM_ID}",
        "signer": "${signer_subject}",
        "app_notarization_id": "${app_notarization_id}",
        "installer_notarization_id": "${installer_notarization_id}",
        "dmg_notarization_id": "${dmg_notarization_id}",
        "gatekeeper": "accepted",
        "stapled": True,
    },
    "bundles": {
        "app_bundle_id": "${DDUMP_APP_BUNDLE_ID}",
        "installer_bundle_id": "${DDUMP_INSTALLER_BUNDLE_ID}",
        "app_designated_requirement": os.environ["APP_REQUIREMENT"],
        "installer_designated_requirement": os.environ["INSTALLER_REQUIREMENT"],
        "dmg_designated_requirement": os.environ["DMG_REQUIREMENT"],
    },
    "sparkle": sparkle,
    "release_notes_url": os.environ.get("DDUMP_RELEASE_NOTES_URL", ""),
    "manifest_key": os.environ.get("DDUMP_MANIFEST_R2_KEY", ""),
    "previous_known_good_version": os.environ.get("DDUMP_PREVIOUS_KNOWN_GOOD_VERSION", ""),
    "phased_rollout_interval": int(os.environ.get("DDUMP_PHASED_ROLLOUT_INTERVAL", "0")) or None,
    "approver": os.environ.get("GITHUB_ACTOR", ""),
    "protected_environment": os.environ.get("DDUMP_PROTECTED_ENVIRONMENT", ""),
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\\n")
PY

auth_json="${output_dir}/release-authorization.json"
"${SCRIPT_DIR}/sign-release-manifest.sh" "$manifest_body" "$auth_json"

/usr/bin/python3 - "$manifest_body" "$auth_json" "${output_dir}/release-manifest.json" <<'PY'
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

note "signed release manifest ready"
