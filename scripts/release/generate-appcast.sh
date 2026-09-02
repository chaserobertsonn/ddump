#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "usage: $0 <manifest-json> <output-appcast-xml>" >&2
}

if [[ "$#" -ne 2 ]]; then
  usage
  exit 2
fi

manifest="$1"
output_xml="$2"
require_file "$manifest"

/usr/bin/python3 - "$manifest" "$output_xml" <<'PY'
import html
import json
import sys

manifest_path, output_path = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

artifact = manifest["artifact"]
sparkle = manifest["sparkle"]
version = manifest["version"]
build = manifest["build"]
channel = manifest["channel"]
url = artifact.get("url", "")
if not url.startswith("https://"):
    raise SystemExit("manifest artifact.url must be https")
notes = manifest.get("release_notes_url", "")
if notes and not notes.startswith("https://"):
    raise SystemExit("release_notes_url must be https when set")

minimum = manifest.get("minimum_macos", "13.0")
ed_signature = sparkle["sparkle_ed_signature"]
length = int(sparkle.get("sparkle_length", artifact["size"]))
channel_tag = "" if channel == "stable" else f"\n      <sparkle:channel>{html.escape(channel)}</sparkle:channel>"
rollout = manifest.get("phased_rollout_interval")
rollout_tag = "" if rollout in (None, "") else f"\n      <sparkle:phasedRolloutInterval>{int(rollout)}</sparkle:phasedRolloutInterval>"
body = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>DDump {html.escape(channel)} Updates</title>
    <link>https://updates.ddump.app/{html.escape(channel)}/appcast.xml</link>
    <description>DDump {html.escape(channel)} update feed</description>
    <item>
      <title>DDump {html.escape(version)}</title>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(minimum)}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{html.escape(notes)}</sparkle:releaseNotesLink>{channel_tag}{rollout_tag}
      <enclosure url="{html.escape(url)}" sparkle:edSignature="{html.escape(ed_signature)}" length="{length}" type="{html.escape(artifact.get("content_type", "application/x-apple-diskimage"))}" />
    </item>
  </channel>
</rss>
'''
with open(output_path, "w", encoding="utf-8") as handle:
    handle.write(body)
PY

note "appcast generated: ${output_xml}"
