#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ddump-helper-migration-tests.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

SWIFTC="$(xcrun --find swiftc 2>/dev/null || command -v swiftc || true)"
if [[ -z "$SWIFTC" ]]; then
  echo "swiftc is required to run DDump helper migration tests." >&2
  exit 1
fi

MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
SDK_ARGS=()
if [[ -n "$MACOS_SDK" ]]; then
  SDK_ARGS=(-sdk "$MACOS_SDK")
fi

HOST_ARCH="$(uname -m)"

"$SWIFTC" \
  "${SDK_ARGS[@]}" \
  -target "${HOST_ARCH}-apple-macosx13.0" \
  "${PROJECT_DIR}/app/HelperMigrationCoordinator.swift" \
  "${PROJECT_DIR}/tests/helper-migration/HelperMigrationCoordinatorTests.swift" \
  -o "${TEST_TMP}/HelperMigrationCoordinatorTests"

DDUMP_PROJECT_DIR="$PROJECT_DIR" "${TEST_TMP}/HelperMigrationCoordinatorTests"
