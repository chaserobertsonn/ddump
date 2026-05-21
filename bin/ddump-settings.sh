#!/bin/bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

APP_SUPPORT_DIR="${HOME}/Library/Application Support/DDump"
CONFIG_PATH="${APP_SUPPORT_DIR}/config.env"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Config file not found: $CONFIG_PATH"
  exit 1
fi

get_value() {
  local key="$1"
  /usr/bin/awk -F'=' -v k="$key" '$1 == k { val = $2 } END { gsub(/^"|"$/, "", val); print val }' "$CONFIG_PATH"
}

set_value() {
  local key="$1"
  local value="$2"
  local escaped
  escaped="${value//\"/\\\"}"
  if /usr/bin/grep -q "^${key}=" "$CONFIG_PATH"; then
    /usr/bin/sed -i '' "s#^${key}=.*#${key}=\"${escaped}\"#" "$CONFIG_PATH"
  else
    /bin/echo "${key}=\"${escaped}\"" >>"$CONFIG_PATH"
  fi
}

toggle_key() {
  local key="$1"
  local current
  current="$(get_value "$key")"
  if [[ "$current" == "1" ]]; then
    set_value "$key" "0"
  else
    set_value "$key" "1"
  fi
}

while true; do
  choice="$(/usr/bin/osascript <<'OSA' 2>/dev/null || true
set options to {"Change Destination Folder", "Toggle Google Drive Move", "Change Google Drive Folder", "Toggle Notifications", "Toggle Start Prompt", "Toggle Completion Popup", "Toggle Progress Window", "Toggle Unknown Card Action Prompt", "Toggle Internal Volume Auto Ignore", "Open Raw Config", "Done"}
set picked to choose from list options with prompt "DDump Settings" default items {item 1 of options}
if picked is false then
  return "Done"
end if
return item 1 of picked
OSA
)"

  case "$choice" in
    "Change Destination Folder")
      dest="$(/usr/bin/osascript <<'OSA' 2>/dev/null || true
try
  set f to choose folder with prompt "Choose destination folder for imports"
  return POSIX path of f
on error number -128
  return ""
end try
OSA
)"
      dest="${dest%/}"
      [[ -n "$dest" ]] && set_value "DEST_ROOT" "$dest"
      ;;
    "Toggle Google Drive Move")
      toggle_key "ENABLE_POST_EJECT_MOVE"
      ;;
    "Change Google Drive Folder")
      move_root="$(/usr/bin/osascript <<'OSA' 2>/dev/null || true
try
  set f to choose folder with prompt "Choose Google Drive destination folder"
  return POSIX path of f
on error number -128
  return ""
end try
OSA
)"
      move_root="${move_root%/}"
      [[ -n "$move_root" ]] && set_value "POST_MOVE_ROOT" "$move_root"
      ;;
    "Toggle Notifications")
      toggle_key "ENABLE_NOTIFICATIONS"
      ;;
    "Toggle Start Prompt")
      toggle_key "PROMPT_NO_EJECT_ON_START"
      ;;
    "Toggle Completion Popup")
      toggle_key "SHOW_RUN_SUMMARY_DIALOG"
      ;;
    "Toggle Progress Window")
      toggle_key "SHOW_PROGRESS_WINDOW"
      ;;
    "Toggle Unknown Card Action Prompt")
      toggle_key "PROMPT_FOR_UNKNOWN_CARD_ACTION"
      ;;
    "Toggle Internal Volume Auto Ignore")
      toggle_key "SKIP_INTERNAL_VOLUMES"
      ;;
    "Open Raw Config")
      /usr/bin/open -e "$CONFIG_PATH"
      ;;
    "Done"|"")
      break
      ;;
  esac
done

/usr/bin/osascript -e 'display notification "Settings saved. Next import will use the new values." with title "DDump"' >/dev/null 2>&1 || true
