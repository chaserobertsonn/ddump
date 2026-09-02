#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_env DDUMP_VERSION
require_env DDUMP_BUILD
require_env DDUMP_CHANNEL
require_env DDUMP_SOURCE_SHA
require_env DDUMP_SPARKLE_PUBLIC_ED_KEY
safe_version "$DDUMP_VERSION"
safe_version "$DDUMP_BUILD"
safe_channel "$DDUMP_CHANNEL"
[[ "$DDUMP_CHANNEL" != "stable" ]] || die "candidate build cannot target stable"
[[ "${DDUMP_PHASED_ROLLOUT_INTERVAL:-0}" =~ ^[0-9]+$ ]] || die "DDUMP_PHASED_ROLLOUT_INTERVAL must be a non-negative integer"

cd "$PROJECT_DIR"
"${SCRIPT_DIR}/verify-source-ref.sh"
"${SCRIPT_DIR}/verify-action-pins.sh" .github/workflows

note "running secretless app, backend, release, and card-safety checks"
./scripts/run-tests.sh
npx -y deno@2.9.6 fmt --check supabase tests/backend backend
npx -y deno@2.9.6 check supabase/functions/*/index.ts tests/backend/*.ts
npx -y deno@2.9.6 test --config backend/deno.json tests/backend
bash -n scripts/release/*.sh
/usr/bin/python3 - <<'PY'
from pathlib import Path

for path in Path("scripts/release").glob("*.py"):
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY

note "running secretless public readiness and unsigned packaging"
DDUMP_VERSION="$DDUMP_VERSION" MACOSX_DEPLOYMENT_TARGET="$DDUMP_MIN_MACOS" ./scripts/public-readiness-check.sh
update_channel="stable"
paid_build_flavor="stable"
if [[ "$DDUMP_CHANNEL" == "private-preview" ]]; then
  paid_build_flavor="beta"
fi
DDUMP_RELEASE_MODE=0 \
  DDUMP_VERSION="$DDUMP_VERSION" \
  DDUMP_BUILD="$DDUMP_BUILD" \
  DDUMP_SPARKLE_ENABLED=1 \
  DDUMP_HELPER_MIGRATION_ENABLED=1 \
  DDUMP_PAID_LAUNCH_ENABLED=1 \
  DDUMP_PAID_ENVIRONMENT="${DDUMP_PAID_ENVIRONMENT:-test}" \
  DDUMP_PAID_BUILD_FLAVOR="$paid_build_flavor" \
  DDUMP_UPDATE_CHANNEL="$update_channel" \
  DDUMP_SPARKLE_PUBLIC_ED_KEY="$DDUMP_SPARKLE_PUBLIC_ED_KEY" \
  MACOSX_DEPLOYMENT_TARGET="$DDUMP_MIN_MACOS" \
  ./scripts/package-dmg.sh

app_path="${PROJECT_DIR}/dist/DDump.app"
installer_path="${PROJECT_DIR}/dist/dmg-root/Install DDump.app"
unsigned_dmg="${PROJECT_DIR}/dist/DDump-${DDUMP_VERSION}-unsigned.dmg"
verify_bundle_metadata "$app_path" "$DDUMP_APP_BUNDLE_ID" "DDump.app"
verify_bundle_metadata "$installer_path" "$DDUMP_INSTALLER_BUNDLE_ID" "Install DDump.app"
[[ "$(plist_value "${app_path}/Contents/Info.plist" CFBundleVersion)" == "$DDUMP_BUILD" ]] || die "DDump.app build number mismatch"
[[ "$(plist_value "${installer_path}/Contents/Info.plist" CFBundleVersion)" == "$DDUMP_BUILD" ]] || die "installer build number mismatch"
[[ "$(plist_value "${app_path}/Contents/Info.plist" DDumpSparkleEnabled)" == "true" ]] || die "candidate does not enable Sparkle"
[[ "$(plist_value "${app_path}/Contents/Info.plist" DDumpHelperMigrationEnabled)" == "true" ]] || die "candidate does not enable helper migration"
[[ "$(plist_value "${app_path}/Contents/Info.plist" DDumpPaidLaunchEnabled)" == "true" ]] || die "candidate does not enable the paid-launch surface"
[[ "$(plist_value "${app_path}/Contents/Info.plist" DDumpPaidBuildFlavor)" == "$paid_build_flavor" ]] || die "candidate paid build flavor mismatch"
[[ "$(plist_value "${app_path}/Contents/Info.plist" DDumpUpdateChannel)" == "stable" ]] || die "promotable candidate must default to stable updates"
app_archs="$(verify_binary_architectures "${app_path}/Contents/MacOS/DDump" "DDump.app")"
installer_archs="$(verify_binary_architectures "${installer_path}/Contents/MacOS/InstallDDump" "Install DDump.app")"
require_file "$unsigned_dmg"

release_dir="${PROJECT_DIR}/dist/release"
rm -rf "$release_dir"
mkdir -p "$release_dir"
tarball="${release_dir}/DDump-${DDUMP_VERSION}-${DDUMP_SOURCE_SHA}.candidate-build.tar.gz"
(
  cd "${PROJECT_DIR}/dist"
  tar -czf "$tarball" DDump.app dmg-root "DDump-${DDUMP_VERSION}-unsigned.dmg"
)

unsigned_sha="$(sha256_file "$unsigned_dmg")"
unsigned_size="$(file_size "$unsigned_dmg")"
tar_sha="$(sha256_file "$tarball")"
tar_size="$(file_size "$tarball")"

/usr/bin/python3 - "$release_dir/candidate-provenance.json" <<PY
import json
import os

data = {
    "schema": "ddump.candidate-provenance.v1",
    "source_sha": os.environ["DDUMP_SOURCE_SHA"],
    "source_branch": os.environ.get("GITHUB_REF_NAME", ""),
    "workflow": os.environ.get("GITHUB_WORKFLOW", ""),
    "workflow_run_id": os.environ.get("GITHUB_RUN_ID", ""),
    "workflow_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
    "version": os.environ["DDUMP_VERSION"],
    "build": os.environ["DDUMP_BUILD"],
    "channel": os.environ["DDUMP_CHANNEL"],
    "app_default_update_channel": "${update_channel}",
    "paid_build_flavor": "${paid_build_flavor}",
    "minimum_macos": os.environ.get("DDUMP_MIN_MACOS", "13.0"),
    "architectures": {
        "app": "${app_archs}",
        "installer": "${installer_archs}",
    },
    "unsigned_dmg": {
        "path": "DDump-${DDUMP_VERSION}-unsigned.dmg",
        "sha256": "${unsigned_sha}",
        "size": int("${unsigned_size}"),
    },
    "candidate_build_archive": {
        "path": os.path.basename("${tarball}"),
        "sha256": "${tar_sha}",
        "size": int("${tar_size}"),
    },
    "release_notes_path": os.environ.get("DDUMP_RELEASE_NOTES_PATH", ""),
    "previous_known_good_version": os.environ.get("DDUMP_PREVIOUS_KNOWN_GOOD_VERSION", ""),
}
with open("${release_dir}/candidate-provenance.json", "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\\n")
PY

note "candidate build archive ready: ${tarball}"
