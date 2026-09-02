#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SPARKLE_VERSION="2.9.6"
SPARKLE_SHA256="8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip"
DEPENDENCY_ROOT="${DDUMP_DEPENDENCY_ROOT:-${PROJECT_DIR}/.build/dependencies}"
INSTALL_ROOT="${DEPENDENCY_ROOT}/Sparkle-${SPARKLE_VERSION}"
FRAMEWORK_PATH="${INSTALL_ROOT}/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

if [[ -d "$FRAMEWORK_PATH" && -f "${INSTALL_ROOT}/.ddump-verified-sha256" ]] \
  && [[ "$(/bin/cat "${INSTALL_ROOT}/.ddump-verified-sha256")" == "$SPARKLE_SHA256" ]]; then
  printf '%s\n' "$INSTALL_ROOT"
  exit 0
fi

if [[ -e "$INSTALL_ROOT" ]]; then
  echo "Existing Sparkle dependency is incomplete or unverified: ${INSTALL_ROOT}" >&2
  echo "Remove that exact versioned directory and rerun this script." >&2
  exit 1
fi

mkdir -p "$DEPENDENCY_ROOT"
DOWNLOAD_ROOT="$(mktemp -d "${DEPENDENCY_ROOT}/.sparkle-${SPARKLE_VERSION}.XXXXXX")"
trap 'rm -rf "$DOWNLOAD_ROOT"' EXIT
ARCHIVE_PATH="${DOWNLOAD_ROOT}/Sparkle.zip"
EXTRACTED_ROOT="${DOWNLOAD_ROOT}/extracted"

curl --fail --location --silent --show-error --retry 3 \
  --output "$ARCHIVE_PATH" \
  "$SPARKLE_URL"

actual_sha256="$(/usr/bin/shasum -a 256 "$ARCHIVE_PATH" | /usr/bin/awk '{print $1}')"
if [[ "$actual_sha256" != "$SPARKLE_SHA256" ]]; then
  echo "Sparkle archive checksum mismatch." >&2
  exit 1
fi

mkdir -p "$EXTRACTED_ROOT"
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$EXTRACTED_ROOT"
if [[ ! -d "${EXTRACTED_ROOT}/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" ]]; then
  echo "Sparkle archive did not contain the expected macOS framework." >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 \
  "${EXTRACTED_ROOT}/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

printf '%s\n' "$SPARKLE_SHA256" >"${EXTRACTED_ROOT}/.ddump-verified-sha256"
/bin/mv "$EXTRACTED_ROOT" "$INSTALL_ROOT"
printf '%s\n' "$INSTALL_ROOT"
