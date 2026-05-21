#!/bin/bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

APP_SUPPORT_DIR="${HOME}/Library/Application Support/DDump"
STATE_DIR="${APP_SUPPORT_DIR}/state"
TRUSTED_UUID_FILE="${STATE_DIR}/trusted_uuids.txt"

mkdir -p "$STATE_DIR"
[[ -f "$TRUSTED_UUID_FILE" ]] || : > "$TRUSTED_UUID_FILE"

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") <volume-name-or-/Volumes/path>

Example:
  $(basename "$0") DFP_MAIN_CARD
USAGE
}

if [[ "${1:-}" == "" ]]; then
  usage
  exit 1
fi

input="$1"
if [[ "$input" == /Volumes/* ]]; then
  vol_path="$input"
else
  vol_path="/Volumes/$input"
fi

if [[ ! -d "$vol_path" ]]; then
  echo "Volume not found: $vol_path" >&2
  exit 1
fi

uuid="$(/usr/sbin/diskutil info "$vol_path" 2>/dev/null | /usr/bin/awk -F': *' '/Volume UUID/ {print $2; exit}' | /usr/bin/xargs)"
if [[ -z "$uuid" ]]; then
  echo "No Volume UUID found for $vol_path" >&2
  exit 1
fi

if /usr/bin/grep -Fxq "$uuid" "$TRUSTED_UUID_FILE"; then
  echo "Already trusted: $uuid"
  exit 0
fi

echo "$uuid" >>"$TRUSTED_UUID_FILE"
echo "Trusted volume UUID added: $uuid"
