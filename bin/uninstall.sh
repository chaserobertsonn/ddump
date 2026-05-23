#!/bin/bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

LABEL="com.ddump"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
NETWORK_WATCH_LABEL="com.ddump.network-watch"
NETWORK_WATCH_PLIST_PATH="${HOME}/Library/LaunchAgents/${NETWORK_WATCH_LABEL}.plist"
uid="$(id -u)"

launchctl bootout "gui/${uid}" "$PLIST_PATH" >/dev/null 2>&1 || true
/bin/rm -f "$PLIST_PATH"
launchctl bootout "gui/${uid}" "$NETWORK_WATCH_PLIST_PATH" >/dev/null 2>&1 || true
/bin/rm -f "$NETWORK_WATCH_PLIST_PATH"

echo "DDump launch agent removed."
echo "App data retained at: ${HOME}/Library/Application Support/DDump"
