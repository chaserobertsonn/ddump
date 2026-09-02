#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:-}"
HELPER_VERSION="${2:-}"

if [[ -z "$OUTPUT_DIR" || -z "$HELPER_VERSION" ]]; then
  echo "usage: prepare-helper-payload.sh OUTPUT_DIR HELPER_VERSION" >&2
  exit 64
fi
if [[ ! "$HELPER_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
  echo "Invalid helper version: ${HELPER_VERSION}" >&2
  exit 64
fi
if [[ -e "$OUTPUT_DIR" ]]; then
  echo "Helper payload output already exists: ${OUTPUT_DIR}" >&2
  exit 1
fi

BIN_FILES=(
  ddump.sh
  ddump-trust.sh
  ddump-monitor.sh
  ddump-control.sh
  ddump-settings.sh
  ddump-debug-snapshot.sh
  ddump-notify.sh
  ddump-cluster.sh
  ddump-calendar-lookup.sh
  ddump-google-calendar.py
  ddump-access-policy.sh
  rclone-gdrive-mount.sh
  ddump-network-watch.sh
  ddump-cloud-idle-watch.sh
)
LAUNCH_AGENT_FILES=(
  com.ddump.plist
  com.ddump.network-watch.plist
  com.ddump.cloud-idle-watch.plist
  com.ddump.rclone-gdrive.plist
  com.ddump.rclone-gdrive.legacy.plist
)

mkdir -p "${OUTPUT_DIR}/bin" "${OUTPUT_DIR}/LaunchAgents"
for filename in "${BIN_FILES[@]}"; do
  source_path="${PROJECT_DIR}/bin/${filename}"
  [[ -f "$source_path" ]] || { echo "Missing helper source: ${source_path}" >&2; exit 1; }
  /bin/cp "$source_path" "${OUTPUT_DIR}/bin/${filename}"
  /bin/chmod 755 "${OUTPUT_DIR}/bin/${filename}"
done
for filename in "${LAUNCH_AGENT_FILES[@]}"; do
  source_path="${PROJECT_DIR}/resources/helpers/templates/LaunchAgents/${filename}"
  [[ -f "$source_path" ]] || { echo "Missing LaunchAgent template: ${source_path}" >&2; exit 1; }
  /bin/cp "$source_path" "${OUTPUT_DIR}/LaunchAgents/${filename}"
  /bin/chmod 644 "${OUTPUT_DIR}/LaunchAgents/${filename}"
done

MANIFEST_PATH="${OUTPUT_DIR}/helper-manifest.json"
created_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
{
  printf '{\n'
  printf '  "schemaVersion": 1,\n'
  printf '  "helperSetVersion": "%s",\n' "$HELPER_VERSION"
  printf '  "minimumAppVersion": "%s",\n' "$HELPER_VERSION"
  printf '  "createdAt": "%s",\n' "$created_at"
  printf '  "forwardFixForVersions": [],\n'
  printf '  "preservePreviousSnapshot": true,\n'
  printf '  "files": [\n'
  first=1
  for filename in "${BIN_FILES[@]}"; do
    digest="$(/usr/bin/shasum -a 256 "${OUTPUT_DIR}/bin/${filename}" | /usr/bin/awk '{print $1}')"
    [[ "$first" == "1" ]] || printf ',\n'
    first=0
    printf '    {"role":"appSupportBin","sourceRelativePath":"bin/%s","installRelativePath":"%s","sha256":"%s","mode":493,"signing":null}' \
      "$filename" "$filename" "$digest"
  done
  for filename in "${LAUNCH_AGENT_FILES[@]}"; do
    digest="$(/usr/bin/shasum -a 256 "${OUTPUT_DIR}/LaunchAgents/${filename}" | /usr/bin/awk '{print $1}')"
    [[ "$first" == "1" ]] || printf ',\n'
    first=0
    printf '    {"role":"launchAgentTemplate","sourceRelativePath":"LaunchAgents/%s","installRelativePath":"%s","sha256":"%s","mode":420,"signing":null}' \
      "$filename" "$filename" "$digest"
  done
  printf '\n  ]\n}\n'
} >"$MANIFEST_PATH"
/bin/chmod 644 "$MANIFEST_PATH"

/usr/bin/plutil -lint "${OUTPUT_DIR}/LaunchAgents/"*.plist >/dev/null
printf '%s\n' "$MANIFEST_PATH"
