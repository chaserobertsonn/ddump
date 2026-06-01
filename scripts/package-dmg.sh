#!/bin/bash
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_VERSION="${DDUMP_VERSION:-0.3.0}"
DIST_DIR="${PROJECT_DIR}/dist"
ROOT_DIR="${DIST_DIR}/dmg-root"
DMG_PATH="${DIST_DIR}/DDump-${APP_VERSION}.dmg"
INSTALLER_DIR="${ROOT_DIR}/.DDumpInstaller"

"${SCRIPT_DIR}/build-app.sh"

rm -rf "$ROOT_DIR" "$DMG_PATH"
mkdir -p "$ROOT_DIR" "$INSTALLER_DIR"

cp -R "${DIST_DIR}/DDump.app" "$ROOT_DIR/DDump.app"
mkdir -p "${INSTALLER_DIR}/bin" "${INSTALLER_DIR}/config" "${INSTALLER_DIR}/app"
cp -R "${PROJECT_DIR}/bin/." "${INSTALLER_DIR}/bin/"
cp -R "${PROJECT_DIR}/config/." "${INSTALLER_DIR}/config/"
cp "${PROJECT_DIR}/app/DDumpApp.swift" "${INSTALLER_DIR}/app/DDumpApp.swift"
cp -R "${PROJECT_DIR}/app/Assets" "${INSTALLER_DIR}/app/Assets"
cp "${PROJECT_DIR}/README.md" "${INSTALLER_DIR}/README.md"
cp "${PROJECT_DIR}/LICENSE" "${INSTALLER_DIR}/LICENSE"

cat >"${ROOT_DIR}/Install DDump.command" <<'SCRIPT'
#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="${DIR}/.DDumpInstaller/bin/install.sh"

if [[ ! -x "$INSTALLER" ]]; then
  echo "Could not find the DDump installer payload next to this command."
  read -r -p "Press Return to close."
  exit 1
fi

echo "Installing DDump for this Mac user..."
/bin/bash "$INSTALLER"
echo ""
echo "Done. You can open DDump from ~/Applications/DDump.app"
read -r -p "Press Return to close."
SCRIPT
chmod +x "${ROOT_DIR}/Install DDump.command"

cat >"${ROOT_DIR}/README_FIRST.txt" <<TXT
DDump ${APP_VERSION}

1. Double-click "Install DDump.command".
2. Open DDump from ~/Applications/DDump.app.
3. Cloud uploads are optional. Turn them on in Settings > Cloud if you want Google Drive syncing.

This early release is unsigned and not notarized. macOS may ask you to approve it in System Settings > Privacy & Security.
TXT

hdiutil create \
  -volname "DDump ${APP_VERSION}" \
  -srcfolder "$ROOT_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Packaged ${DMG_PATH}"
