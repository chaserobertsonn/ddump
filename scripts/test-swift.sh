#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ddump-swift-tests.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

SWIFTC="$(xcrun --find swiftc 2>/dev/null || command -v swiftc || true)"
if [[ -z "$SWIFTC" ]]; then
  echo "swiftc is required to run DDump Swift tests." >&2
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
  "${PROJECT_DIR}/app/DDumpSemanticVersion.swift" \
  "${PROJECT_DIR}/tests/swift/DDumpSemanticVersionTests.swift" \
  -o "${TEST_TMP}/DDumpSemanticVersionTests"

"${TEST_TMP}/DDumpSemanticVersionTests"

"$SWIFTC" \
  "${SDK_ARGS[@]}" \
  -target "${HOST_ARCH}-apple-macosx13.0" \
  "${PROJECT_DIR}/app/PaidLaunch/"*.swift \
  "${PROJECT_DIR}/tests/paid-launch/PaidLaunchHarness.swift" \
  -o "${TEST_TMP}/PaidLaunchHarness"

"${TEST_TMP}/PaidLaunchHarness"

"$SWIFTC" \
  "${SDK_ARGS[@]}" \
  -target "${HOST_ARCH}-apple-macosx13.0" \
  "${PROJECT_DIR}/app/PaidLaunch/"*.swift \
  "${PROJECT_DIR}/tests/swift/BackendEntitlementJWSTests.swift" \
  -o "${TEST_TMP}/BackendEntitlementJWSTests"

"${TEST_TMP}/BackendEntitlementJWSTests"
