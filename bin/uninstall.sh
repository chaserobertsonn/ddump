#!/bin/bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

LABEL="com.ddump"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
uid="$(id -u)"

launchctl bootout "gui/${uid}" "$PLIST_PATH" >/dev/null 2>&1 || true
/bin/rm -f "$PLIST_PATH"

echo "DDump launch agent removed."
echo "App data retained at: ${HOME}/Library/Application Support/DDump"
