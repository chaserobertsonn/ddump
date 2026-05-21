#!/bin/bash
# DDump time-clustering helper.
#
# Given a list of file paths (one per line on stdin) and a gap threshold
# (in minutes), groups the files by capture-time clusters and prints a TSV:
#
#   <file_path>\t<cluster_id>\t<cluster_start_iso>\t<cluster_end_iso>
#
# Capture time is read from EXIF (DateTimeOriginal) if exiftool is available,
# otherwise falls back to filesystem mtime. Files without any usable time
# are emitted with cluster_id "unknown".
#
# Usage:
#   ddump-cluster.sh --gap-minutes 45 < files.txt
#
# Configurable via env:
#   DDUMP_CLUSTER_TIME_SOURCE   "exif" (default), "mtime", or "auto"

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

GAP_MIN="45"
TIME_SOURCE="${DDUMP_CLUSTER_TIME_SOURCE:-auto}"

while [[ "${1:-}" ]]; do
  case "$1" in
    --gap-minutes) GAP_MIN="$2"; shift 2 ;;
    --time-source) TIME_SOURCE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--gap-minutes N] [--time-source exif|mtime|auto] < files.txt"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Default to exiftool if available and TIME_SOURCE=auto
have_exiftool=0
if command -v exiftool >/dev/null 2>&1; then
  have_exiftool=1
fi

use_exif=0
case "$TIME_SOURCE" in
  exif) use_exif=1 ;;
  mtime) use_exif=0 ;;
  auto) [[ "$have_exiftool" -eq 1 ]] && use_exif=1 ;;
esac

# Stage 1: gather (epoch, path) lines for all input files.
TMP_TIMES="$(mktemp)"
trap 'rm -f "$TMP_TIMES" "$TMP_SORTED" 2>/dev/null' EXIT

while IFS= read -r src_file; do
  [[ -z "$src_file" ]] && continue
  [[ -f "$src_file" ]] || continue

  epoch=""
  if [[ "$use_exif" -eq 1 ]]; then
    # Try DateTimeOriginal (the actual capture time), fall back to CreateDate.
    epoch="$(exiftool -s3 -d '%s' -DateTimeOriginal -CreateDate "$src_file" 2>/dev/null \
              | grep -m1 -E '^[0-9]+$' || true)"
  fi
  if [[ -z "$epoch" ]]; then
    # Filesystem mtime (Mac stat -f %m or Linux stat -c %Y)
    if epoch="$(stat -f '%m' "$src_file" 2>/dev/null)"; then
      :
    else
      epoch="$(stat -c '%Y' "$src_file" 2>/dev/null || true)"
    fi
  fi

  # Emit "epoch<TAB>path" with epoch="unknown" if no time at all.
  if [[ -n "$epoch" && "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s\t%s\n' "$epoch" "$src_file"
  else
    printf 'unknown\t%s\n' "$src_file"
  fi
done >"$TMP_TIMES"

# Stage 2: sort by epoch (unknown rows go to the end), then walk to assign clusters.
TMP_SORTED="$(mktemp)"
{
  ( grep -v '^unknown\t' "$TMP_TIMES" 2>/dev/null || true ) | sort -n
  grep '^unknown\t' "$TMP_TIMES" 2>/dev/null || true
} >"$TMP_SORTED"

GAP_SEC=$(( GAP_MIN * 60 ))

awk -v gap="$GAP_SEC" 'BEGIN {
  FS = "\t"; OFS = "\t"
  cluster_id = 0
  prev_epoch = -1
  cluster_start = ""
  cluster_end = ""
  buf_count = 0
}
{
  epoch = $1
  path = $2

  if (epoch == "unknown") {
    # Emit all buffered rows first with their cluster meta
    for (i = 0; i < buf_count; i++) {
      print buf_paths[i], buf_clusters[i], buf_starts[i], buf_ends[i]
    }
    buf_count = 0
    # Now emit this unknown row
    print path, "unknown", "", ""
    next
  }

  if (prev_epoch < 0 || (epoch - prev_epoch) > gap) {
    # Flush previous cluster if any
    for (i = 0; i < buf_count; i++) {
      print buf_paths[i], buf_clusters[i], buf_starts[i], buf_ends[i]
    }
    buf_count = 0

    cluster_id++
    cluster_start = epoch
  }
  cluster_end = epoch

  buf_paths[buf_count] = path
  buf_clusters[buf_count] = cluster_id
  buf_starts[buf_count] = cluster_start
  buf_ends[buf_count] = cluster_end
  buf_count++

  # Update all rows in current cluster with the latest end
  for (i = 0; i < buf_count; i++) {
    buf_ends[i] = cluster_end
  }

  prev_epoch = epoch
}
END {
  for (i = 0; i < buf_count; i++) {
    print buf_paths[i], buf_clusters[i], buf_starts[i], buf_ends[i]
  }
}' "$TMP_SORTED" | while IFS=$'\t' read -r path cid cstart cend; do
  if [[ "$cid" == "unknown" || -z "$cstart" ]]; then
    printf '%s\t%s\t\t\n' "$path" "$cid"
  else
    cstart_iso="$(date -j -f '%s' "$cstart" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d "@$cstart" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "$cstart")"
    cend_iso="$(date -j -f '%s' "$cend" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d "@$cend" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "$cend")"
    printf '%s\t%s\t%s\t%s\n' "$path" "$cid" "$cstart_iso" "$cend_iso"
  fi
done
