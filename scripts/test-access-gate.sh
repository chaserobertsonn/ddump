#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ddump-access-tests.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

SWIFTC="$(xcrun --find swiftc 2>/dev/null || command -v swiftc || true)"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
HOST_ARCH="$(uname -m)"

"$SWIFTC" \
  -sdk "$MACOS_SDK" \
  -target "${HOST_ARCH}-apple-macosx13.0" \
  "${PROJECT_DIR}/helpers/DDumpAccessGateCore.swift" \
  "${PROJECT_DIR}/tests/access-gate/DDumpAccessGateTests.swift" \
  -o "${TEST_TMP}/DDumpAccessGateTests"

"${TEST_TMP}/DDumpAccessGateTests"
