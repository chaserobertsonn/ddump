#!/usr/bin/env python3
"""Native Google Calendar OAuth and event lookup helper for DDump.

This helper intentionally uses only Python's standard library so the public app
does not require gcalcli, Homebrew, or Terminal setup. It uses the installed-app
OAuth flow with PKCE and stores the read-only calendar token in DDump's app
support state folder.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import http.server
import json
import os
import secrets
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path


SCOPE = "https://www.googleapis.com/auth/calendar.readonly"
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
API_ROOT = "https://www.googleapis.com/calendar/v3"
DEFAULT_CLIENT_ID = "570098546449-737pvkselaqtncp2e6kdmhkf55eemche.apps.googleusercontent.com"


def app_support_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "DDump"


def default_token_file() -> Path:
    return app_support_dir() / "state" / "google-calendar-token.json"


def fail(message: str, code: int = 1) -> None:
    print(f"error={shell_value(message)}")
    print(f"status=error")
    sys.exit(code)


def shell_value(value: str) -> str:
    return str(value).replace("\n", " ").replace("\r", " ")


def load_token(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def save_token(path: Path, token: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if "expires_in" in token:
        token["expires_at"] = int(time.time()) + int(token.get("expires_in", 0)) - 60
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(token, indent=2, sort_keys=True), encoding="utf-8")
    os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
    tmp.replace(path)


def form_post(url: str, payload: dict) -> dict:
    data = urllib.parse.urlencode(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        fail(f"Google OAuth request failed ({exc.code}): {body}", 4)
    except Exception as exc:
        fail(f"Google OAuth request failed: {exc}", 4)


def api_get(token: dict, path: str, params: dict | None = None) -> dict:
    query = urllib.parse.urlencode(params or {}, doseq=True)
    url = f"{API_ROOT}{path}"
    if query:
        url = f"{url}?{query}"
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token['access_token']}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        fail(f"Google Calendar API failed ({exc.code}): {body}", 5)
    except Exception as exc:
        fail(f"Google Calendar API failed: {exc}", 5)


def oauth_payload(client_id: str, client_secret: str = "") -> dict:
    payload = {"client_id": client_id}
    if client_secret:
        payload["client_secret"] = client_secret
    return payload


def refresh_if_needed(client_id: str, client_secret: str, token_file: Path) -> dict:
    token = load_token(token_file)
    if not token:
        print("status=not_authorized")
        sys.exit(3)
    if token.get("access_token") and int(token.get("expires_at", 0)) > int(time.time()):
        return token
    refresh_token = token.get("refresh_token")
    if not refresh_token:
        print("status=not_authorized")
        print("error=missing_refresh_token")
        sys.exit(3)
    payload = oauth_payload(client_id, client_secret)
    payload.update({"grant_type": "refresh_token", "refresh_token": refresh_token})
    refreshed = form_post(TOKEN_URL, payload)
    refreshed["refresh_token"] = refresh_token
    save_token(token_file, refreshed)
    return refreshed


def code_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


class OAuthServer(http.server.HTTPServer):
    auth_code: str | None = None
    auth_error: str | None = None
    expected_state: str = ""


class OAuthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        state = params.get("state", [""])[0]
        if state != self.server.expected_state:
            self.server.auth_error = "OAuth state mismatch. Return to DDump and try again."
            self._respond("DDump Calendar setup failed", self.server.auth_error)
            return
        if "error" in params:
            self.server.auth_error = params["error"][0]
            self._respond("DDump Calendar setup failed", self.server.auth_error)
            return
        self.server.auth_code = params.get("code", [""])[0]
        if self.server.auth_code:
            self._respond("DDump Calendar connected", "You can close this tab and return to DDump.")
        else:
            self.server.auth_error = "Missing OAuth code."
            self._respond("DDump Calendar setup failed", self.server.auth_error)

    def log_message(self, *_args: object) -> None:
        return

    def _respond(self, title: str, message: str) -> None:
        body = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{title}</title>
<style>body{{font:16px -apple-system,BlinkMacSystemFont,sans-serif;margin:48px;line-height:1.45}}</style>
</head><body><h1>{title}</h1><p>{message}</p></body></html>"""
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def cmd_auth(args: argparse.Namespace) -> None:
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).decode("ascii").rstrip("=")
    state = secrets.token_urlsafe(24)
    server = OAuthServer(("127.0.0.1", 0), OAuthHandler)
    server.expected_state = state
    redirect_uri = f"http://127.0.0.1:{server.server_port}/"
    params = {
        "client_id": args.client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": SCOPE,
        "access_type": "offline",
        "prompt": "consent",
        "code_challenge": code_challenge(verifier),
        "code_challenge_method": "S256",
        "state": state,
    }
    url = f"{AUTH_URL}?{urllib.parse.urlencode(params)}"
    print("status=browser_opening")
    print(f"auth_url={shell_value(url)}")
    sys.stdout.flush()
    webbrowser.open(url)

    deadline = time.time() + int(args.timeout)
    while time.time() < deadline and not server.auth_code and not server.auth_error:
        server.handle_request()
    server.server_close()
    if server.auth_error:
        fail(server.auth_error, 6)
    if not server.auth_code:
        print("status=timeout")
        sys.exit(7)

    payload = oauth_payload(args.client_id, args.client_secret)
    payload.update(
        {
            "code": server.auth_code,
            "code_verifier": verifier,
            "redirect_uri": redirect_uri,
            "grant_type": "authorization_code",
        }
    )
    token = form_post(TOKEN_URL, payload)
    save_token(args.token_file, token)
    checked = refresh_if_needed(args.client_id, args.client_secret, args.token_file)
    api_get(checked, "/users/me/calendarList", {"maxResults": 1})
    print("status=authorized")
    print(f"token_file={shell_value(args.token_file)}")


def cmd_status(args: argparse.Namespace) -> None:
    token = refresh_if_needed(args.client_id, args.client_secret, args.token_file)
    api_get(token, "/users/me/calendarList", {"maxResults": 1})
    print("status=authorized")
    print(f"token_file={shell_value(args.token_file)}")


def parse_event_time(value: dict, local_tz: dt.tzinfo) -> int:
    if "dateTime" in value:
        raw = value["dateTime"].replace("Z", "+00:00")
        return int(dt.datetime.fromisoformat(raw).timestamp())
    day = dt.date.fromisoformat(value["date"])
    return int(dt.datetime.combine(day, dt.time.min, tzinfo=local_tz).timestamp())


def local_day_bounds(date_text: str, window_hours: int) -> tuple[str, str]:
    local_tz = dt.datetime.now().astimezone().tzinfo
    day = dt.date.fromisoformat(date_text)
    start = dt.datetime.combine(day, dt.time.min, tzinfo=local_tz) - dt.timedelta(hours=window_hours)
    end = dt.datetime.combine(day, dt.time.max, tzinfo=local_tz) + dt.timedelta(hours=window_hours)
    return start.isoformat(), end.isoformat()


def resolve_calendar_id(token: dict, calendar_name: str) -> str:
    name = calendar_name.strip()
    if not name:
        return "primary"
    calendars = api_get(token, "/users/me/calendarList", {"maxResults": 250}).get("items", [])
    for item in calendars:
        if item.get("id") == name or item.get("summary", "").lower() == name.lower():
            return item["id"]
    partial_matches = [
        item for item in calendars if name.lower() in item.get("summary", "").lower()
    ]
    if len(partial_matches) == 1:
        return partial_matches[0]["id"]
    fail(f"Calendar not found or ambiguous: {name}", 8)


def cmd_events(args: argparse.Namespace) -> None:
    token = refresh_if_needed(args.client_id, args.client_secret, args.token_file)
    calendar_id = resolve_calendar_id(token, args.calendar or "")
    time_min, time_max = local_day_bounds(args.date, int(args.day_window))
    data = api_get(
        token,
        f"/calendars/{urllib.parse.quote(calendar_id, safe='')}/events",
        {
            "timeMin": time_min,
            "timeMax": time_max,
            "singleEvents": "true",
            "orderBy": "startTime",
            "maxResults": 2500,
        },
    )
    local_tz = dt.datetime.now().astimezone().tzinfo
    for item in data.get("items", []):
        title = item.get("summary", "Untitled event").replace("\t", " ").replace("\n", " ")
        start = parse_event_time(item.get("start", {}), local_tz)
        end = parse_event_time(item.get("end", item.get("start", {})), local_tz)
        print(f"{start}\t{end}\t{title}")


def cmd_disconnect(args: argparse.Namespace) -> None:
    try:
        args.token_file.unlink()
    except FileNotFoundError:
        pass
    print("status=not_authorized")


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="DDump Google Calendar OAuth helper")
    p.add_argument("--client-id", default=os.environ.get("GOOGLE_CALENDAR_CLIENT_ID", DEFAULT_CLIENT_ID))
    p.add_argument("--client-secret", default=os.environ.get("GOOGLE_CALENDAR_CLIENT_SECRET", ""))
    p.add_argument("--token-file", type=Path, default=default_token_file())
    sub = p.add_subparsers(dest="command", required=True)

    auth = sub.add_parser("auth")
    auth.add_argument("--timeout", type=int, default=300)
    auth.set_defaults(func=cmd_auth)

    status = sub.add_parser("status")
    status.set_defaults(func=cmd_status)

    events = sub.add_parser("events")
    events.add_argument("--date", required=True)
    events.add_argument("--calendar", default="")
    events.add_argument("--day-window", type=int, default=1)
    events.set_defaults(func=cmd_events)

    disconnect = sub.add_parser("disconnect")
    disconnect.set_defaults(func=cmd_disconnect)
    return p


def main() -> None:
    args = parser().parse_args()
    try:
        args.func(args)
    except KeyboardInterrupt:
        print("status=cancelled")
        sys.exit(130)


if __name__ == "__main__":
    main()
