#!/bin/bash
# DDump notification wrapper.
#
# Tries (in order) `alerter`, `terminal-notifier`, then `osascript` for sending
# native macOS notifications. Action-button mode requires `alerter` or
# `terminal-notifier`; if only osascript is available, plain notifications
# work but action buttons fall back to "no answer" (the script returns ""
# and the caller proceeds with safe defaults).
#
# Subcommands:
#   info    <title> <message>
#       Plain notification, no buttons, no return value.
#
#   ask     <title> <message> <button1> [<button2> [<button3> [<button4>]]]
#       Action-button notification. Prints (to stdout) the clicked button text,
#       or "" if no button was clicked / timed out / fell back to osascript.
#
#   warn    <title> <message>
#       Same as info, but with a warning sound.
#
#   done    <title> <message>
#       Same as info, but with a success sound.
#
# Configurable via env:
#   DDUMP_NOTIFIER_TIMEOUT      seconds to wait for action click (default 60)
#   DDUMP_NOTIFIER_SENDER       app bundle id used as sender icon (default com.ddump.app)
#   DDUMP_NOTIFIER_APP_ID       app bundle id used for osascript notifications
#   DDUMP_NOTIFIER_FORCE        force "alerter" / "terminal-notifier" / "osascript"

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

TIMEOUT="${DDUMP_NOTIFIER_TIMEOUT:-60}"
SENDER="${DDUMP_NOTIFIER_SENDER:-com.ddump.app}"
APP_ID="${DDUMP_NOTIFIER_APP_ID:-$SENDER}"
FORCE="${DDUMP_NOTIFIER_FORCE:-}"

resolve_tool() {
  if [[ -n "$FORCE" ]]; then
    printf '%s' "$FORCE"
    return
  fi
  # For "ask" (action-button prompts): use osascript dialog. It's modal/intrusive
  # but guaranteed to deliver and unblock the script. terminal-notifier with -actions
  # silently hangs forever if Notification Center permission isn't granted, which is
  # worse than a brief dialog.
  if [[ "${RESOLVE_FOR:-info}" == "ask" ]]; then
    printf 'osascript'
  else
    # Plain notifications: osascript display notification is non-intrusive and
    # delivers reliably from a LaunchAgent's GUI session.
    printf 'osascript'
  fi
}

notify_plain() {
  local title="$1"
  local message="$2"
  local sound="${3:-}"
  local tool
  tool="$(resolve_tool)"

  case "$tool" in
    alerter)
      local args=(-title "$title" -message "$message" -sender "$SENDER" -timeout 5)
      [[ -n "$sound" ]] && args+=(-sound "$sound")
      alerter "${args[@]}" >/dev/null 2>&1 || true
      ;;
    terminal-notifier)
      local args=(-title "$title" -message "$message" -sender "$SENDER")
      [[ -n "$sound" ]] && args+=(-sound "$sound")
      terminal-notifier "${args[@]}" >/dev/null 2>&1 || true
      ;;
    *)
      local msg_esc="${message//\\/\\\\}"
      msg_esc="${msg_esc//\"/\\\"}"
      local title_esc="${title//\\/\\\\}"
      title_esc="${title_esc//\"/\\\"}"
      local app_id_esc="${APP_ID//\\/\\\\}"
      app_id_esc="${app_id_esc//\"/\\\"}"
      if [[ -n "$app_id_esc" ]]; then
        if [[ -n "$sound" ]]; then
          osascript -e "tell application id \"${app_id_esc}\" to display notification \"${msg_esc}\" with title \"${title_esc}\" sound name \"${sound}\"" >/dev/null 2>&1 || true
        else
          osascript -e "tell application id \"${app_id_esc}\" to display notification \"${msg_esc}\" with title \"${title_esc}\"" >/dev/null 2>&1 || true
        fi
      else
        if [[ -n "$sound" ]]; then
          osascript -e "display notification \"${msg_esc}\" with title \"${title_esc}\" sound name \"${sound}\"" >/dev/null 2>&1 || true
        else
          osascript -e "display notification \"${msg_esc}\" with title \"${title_esc}\"" >/dev/null 2>&1 || true
        fi
      fi
      ;;
  esac
}

notify_ask() {
  local title="$1"
  local message="$2"
  shift 2
  local buttons=("$@")
  local tool
  tool="$(resolve_tool)"

  case "$tool" in
    alerter)
      # alerter returns the clicked button text on stdout, or "@TIMEOUT" / "@CLOSED"
      local actions
      actions="$(IFS=,; echo "${buttons[*]}")"
      local default_btn="${buttons[0]}"
      local result
      result="$(alerter \
        -title "$title" \
        -message "$message" \
        -actions "$actions" \
        -defaultButton "$default_btn" \
        -timeout "$TIMEOUT" \
        -sender "$SENDER" 2>/dev/null || true)"
      case "$result" in
        @TIMEOUT|@CLOSED|@CONTENTCLICKED|"") printf '' ;;
        *) printf '%s' "$result" ;;
      esac
      ;;
    terminal-notifier)
      # terminal-notifier supports -actions (comma-separated) and prints the chosen action
      local actions
      actions="$(IFS=,; echo "${buttons[*]}")"
      local result
      result="$(terminal-notifier \
        -title "$title" \
        -message "$message" \
        -actions "$actions" \
        -closeLabel "Skip" \
        -timeout "$TIMEOUT" \
        -sender "$SENDER" 2>/dev/null || true)"
      printf '%s' "$result"
      ;;
    *)
      # osascript can do a non-banner dialog with buttons (intrusive — a window),
      # but not a true notification with buttons. Use display dialog as fallback.
      local buttons_list=""
      local b
      for b in "${buttons[@]}"; do
        if [[ -z "$buttons_list" ]]; then
          buttons_list="\"${b//\"/\\\"}\""
        else
          buttons_list="${buttons_list}, \"${b//\"/\\\"}\""
        fi
      done
      local default_btn="${buttons[0]}"
      local title_esc="${title//\"/\\\"}"
      local msg_esc="${message//\"/\\\"}"
      local result
      result="$(osascript <<OSA 2>/dev/null || true
tell application "System Events"
  activate
  try
    set d to display dialog "$msg_esc" buttons {$buttons_list} default button "$default_btn" with title "$title_esc" giving up after $TIMEOUT
    return button returned of d
  on error
    return ""
  end try
end tell
OSA
)"
      printf '%s' "$result"
      ;;
  esac
}

cmd="${1:-}"
case "$cmd" in
  info)
    RESOLVE_FOR=info notify_plain "${2:-DDump}" "${3:-}" ""
    ;;
  warn)
    RESOLVE_FOR=info notify_plain "${2:-DDump}" "${3:-}" "Basso"
    ;;
  done)
    RESOLVE_FOR=info notify_plain "${2:-DDump}" "${3:-}" "Glass"
    ;;
  ask)
    shift
    title="${1:-DDump}"
    message="${2:-}"
    shift 2 || true
    RESOLVE_FOR=ask notify_ask "$title" "$message" "$@"
    ;;
  which)
    resolve_tool
    echo
    ;;
  *)
    echo "Usage: $(basename "$0") {info|warn|done|ask|which} <title> <message> [<button1> ...]" >&2
    exit 2
    ;;
esac
