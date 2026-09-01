#!/bin/bash
set -euo pipefail

export LC_ALL=C
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

DDUMP_EXPECTED_TEAM_ID="${DDUMP_EXPECTED_TEAM_ID:-W4GNV4SRNU}"
DDUMP_APP_BUNDLE_ID="${DDUMP_APP_BUNDLE_ID:-com.ddump.app}"
DDUMP_INSTALLER_BUNDLE_ID="${DDUMP_INSTALLER_BUNDLE_ID:-com.ddump.app.installer}"
DDUMP_MIN_MACOS="${DDUMP_MIN_MACOS:-13.0}"

die() {
  echo "error: $*" >&2
  exit 1
}

note() {
  echo "== $* =="
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "missing required environment variable: ${name}"
  fi
}

require_file() {
  [[ -f "$1" ]] || die "missing file: $1"
}

require_dir() {
  [[ -d "$1" ]] || die "missing directory: $1"
}

safe_version() {
  [[ "$1" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "invalid version/build string: $1"
}

safe_channel() {
  case "$1" in
    private-preview|beta|stable) ;;
    *) die "invalid channel: $1" ;;
  esac
}

sha256_file() {
  require_file "$1"
  /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

file_size() {
  require_file "$1"
  if stat -f %z "$1" >/dev/null 2>&1; then
    stat -f %z "$1"
  else
    stat -c %s "$1"
  fi
}

json_quote() {
  /usr/bin/python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/bin/plutil -extract "$key" raw -o - "$plist"
}

verify_bundle_metadata() {
  local bundle="$1"
  local expected_id="$2"
  local expected_name="$3"
  require_dir "$bundle"
  local plist="${bundle}/Contents/Info.plist"
  require_file "$plist"
  [[ "$(plist_value "$plist" CFBundleIdentifier)" == "$expected_id" ]] || die "${expected_name} bundle id mismatch"
  [[ "$(plist_value "$plist" LSMinimumSystemVersion)" == "$DDUMP_MIN_MACOS" ]] || die "${expected_name} minimum macOS mismatch"
  [[ "$(plist_value "$plist" CFBundlePackageType)" == "APPL" ]] || die "${expected_name} package type mismatch"
}

verify_binary_architectures() {
  local binary="$1"
  local label="$2"
  require_file "$binary"
  local archs
  archs="$(lipo -archs "$binary")"
  [[ " $archs " == *" arm64 "* ]] || die "${label} is missing arm64: ${archs}"
  [[ " $archs " == *" x86_64 "* ]] || die "${label} is missing x86_64: ${archs}"
  echo "$archs"
}

codesign_details() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1
}

verify_team_id() {
  local path="$1"
  local label="$2"
  codesign_details "$path" | grep -q "TeamIdentifier=${DDUMP_EXPECTED_TEAM_ID}" || die "${label} Team ID mismatch"
}

verify_designated_requirement() {
  local path="$1"
  local label="$2"
  /usr/bin/codesign -dr - "$path" 2>&1 | grep -q "designated" || die "${label} designated requirement missing"
}

verify_strict_signature() {
  local path="$1"
  local label="$2"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$path" >/dev/null
  verify_team_id "$path" "$label"
  verify_designated_requirement "$path" "$label"
}

require_https_url() {
  [[ "$1" == https://* ]] || die "URL must use https: $1"
}

tmpdir() {
  mktemp -d "${TMPDIR:-/tmp}/ddump-release.XXXXXX"
}

base64_decode_to_file() {
  local output="$1"
  if /usr/bin/base64 --help 2>&1 | grep -q -- '--decode'; then
    /usr/bin/base64 --decode >"$output"
  else
    /usr/bin/base64 -D >"$output"
  fi
}
