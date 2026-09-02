#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ddump-release-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$PROJECT_DIR"

sparkle_root="$(./scripts/fetch-sparkle.sh)"
export DDUMP_SPARKLE_SIGN_UPDATE="${sparkle_root}/bin/sign_update"

# Sparkle private-key files contain a base64-encoded 32-byte seed. The workflow
# secret is a second base64 layer so GitHub can transport the file exactly.
openssl rand 32 | /usr/bin/base64 >"${TEST_DIR}/sparkle-private-key"
export DDUMP_SPARKLE_EDDSA_PRIVATE_KEY_B64="$(/usr/bin/base64 <"${TEST_DIR}/sparkle-private-key" | tr -d '\n')"

printf 'synthetic signed update archive\n' >"${TEST_DIR}/DDump-9.9.9.dmg"
./scripts/release/sign-sparkle-update.sh \
  "${TEST_DIR}/DDump-9.9.9.dmg" \
  "${TEST_DIR}/sparkle-signature.json"
archive_signature="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sparkle_ed_signature"])' "${TEST_DIR}/sparkle-signature.json")"
"${DDUMP_SPARKLE_SIGN_UPDATE}" --verify --ed-key-file "${TEST_DIR}/sparkle-private-key" \
  "${TEST_DIR}/DDump-9.9.9.dmg" "$archive_signature" >/dev/null
cp "${TEST_DIR}/DDump-9.9.9.dmg" "${TEST_DIR}/DDump-9.9.9-tampered.dmg"
printf 'tamper\n' >>"${TEST_DIR}/DDump-9.9.9-tampered.dmg"
if "${DDUMP_SPARKLE_SIGN_UPDATE}" --verify --ed-key-file "${TEST_DIR}/sparkle-private-key" \
  "${TEST_DIR}/DDump-9.9.9-tampered.dmg" "$archive_signature" >/dev/null 2>&1; then
  echo "tampered Sparkle enclosure was accepted" >&2
  exit 1
fi

python3 - "${TEST_DIR}/sparkle-signature.json" "${TEST_DIR}/manifest.json" <<'PY'
import json
import sys

signature_path, manifest_path = sys.argv[1:]
with open(signature_path, encoding="utf-8") as handle:
    sparkle = json.load(handle)
manifest = {
    "schema": "ddump.release-manifest.v1",
    "source_sha": "0" * 40,
    "version": "9.9.9",
    "build": "999",
    "channel": "beta",
    "minimum_macos": "13.0",
    "artifact": {
        "url": "https://downloads.ddump.app/beta/9.9.9/DDump-9.9.9.dmg",
        "sha256": "0" * 64,
        "size": sparkle["sparkle_length"],
        "content_type": "application/x-apple-diskimage",
    },
    "sparkle": sparkle,
    "release_notes_url": "https://ddump.app/releases/9.9.9",
    "phased_rollout_interval": 3600,
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

./scripts/release/generate-appcast.sh "${TEST_DIR}/manifest.json" "${TEST_DIR}/appcast.xml"
./scripts/release/sign-sparkle-feed.sh "${TEST_DIR}/appcast.xml"
cp "${TEST_DIR}/appcast.xml" "${TEST_DIR}/appcast-tampered.xml"
python3 - "${TEST_DIR}/appcast-tampered.xml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text(encoding="utf-8").replace("DDump 9.9.9", "DDump 9.9.8", 1), encoding="utf-8")
PY
if "${DDUMP_SPARKLE_SIGN_UPDATE}" --verify --ed-key-file "${TEST_DIR}/sparkle-private-key" \
  "${TEST_DIR}/appcast-tampered.xml" >/dev/null 2>&1; then
  echo "tampered Sparkle appcast was accepted" >&2
  exit 1
fi
python3 - "${TEST_DIR}/appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
xml = ET.tostring(root, encoding="unicode")
assert "beta" in xml
assert "phasedRolloutInterval" in xml
assert "edSignature" in xml
PY

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${TEST_DIR}/release-auth-private.pem" 2>/dev/null
openssl pkey -in "${TEST_DIR}/release-auth-private.pem" -pubout -out "${TEST_DIR}/release-auth-public.pem" 2>/dev/null
export DDUMP_RELEASE_AUTH_PRIVATE_KEY_B64="$(/usr/bin/base64 <"${TEST_DIR}/release-auth-private.pem" | tr -d '\n')"
export DDUMP_RELEASE_AUTH_PUBLIC_KEY_B64="$(/usr/bin/base64 <"${TEST_DIR}/release-auth-public.pem" | tr -d '\n')"
./scripts/release/sign-release-manifest.sh "${TEST_DIR}/manifest.json" "${TEST_DIR}/release-auth.json"
manifest_sha="$(/usr/bin/shasum -a 256 "${TEST_DIR}/manifest.json" | awk '{print $1}')"
./scripts/release/verify-release-manifest.sh \
  "${TEST_DIR}/manifest.json" \
  "${TEST_DIR}/release-auth.json" \
  "$manifest_sha"

./scripts/release/validate-forward-fix.sh 9.9.9 9.9.10
if ./scripts/release/validate-forward-fix.sh 9.9.9 9.9.8 >/dev/null 2>&1; then
  echo "forward-fix downgrade was not rejected" >&2
  exit 1
fi

grep -Fq '/usr/bin/ditto "$app_path" "$payload_app_path"' scripts/release/sign-notarize-candidate.sh
if grep -Fq 'sign_bundle_with_nested_code "$payload_app_path"' scripts/release/sign-notarize-candidate.sh; then
  echo "installer payload app must reuse exact notarized app bytes" >&2
  exit 1
fi

echo "PASS: release manifests, archive/feed signatures, exact notarized payload, channels, phased rollout, and forward-fix guards"
