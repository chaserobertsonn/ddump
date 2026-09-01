#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/test-swift.sh"
"${SCRIPT_DIR}/test-access-gate.sh"
"${SCRIPT_DIR}/test-import-access-boundary.sh"
"${SCRIPT_DIR}/test-helper-migration.sh"
"${SCRIPT_DIR}/../tests/release/test-release-scripts.sh"
