#!/usr/bin/env bash
# Copies the frames an open shot out of a test run into a folder the sheet reads.
#
# A test run clones the destination simulator, so the app's own container belongs to a clone
# that xcodebuild throws away: `simctl get_app_container` on the runner's device comes back
# empty. The test therefore attaches every frame to the result bundle as well, and this reads
# them from there. The container is still searched as a fallback, for a run that did not
# clone — it costs a find and covers a different Xcode.
#
# usage: shot_frames.sh <result.xcresult> <output-dir> <shot-folder>
set -uo pipefail

BUNDLE="${1:?result bundle}"
OUT="${2:?output directory}"
FOLDER="${3:?shot folder}"

mkdir -p "$OUT"
RAW=$(mktemp -d)

if [ -d "$BUNDLE" ]; then
  xcrun xcresulttool export attachments --path "$BUNDLE" --output-path "$RAW" >/dev/null 2>&1 \
    || echo "could not export attachments from $BUNDLE"
fi

for NAME in 01-open 02-connected; do
  FILE=$(find "$RAW" -type f -iname "${NAME}*" 2>/dev/null | head -1)
  if [ -n "$FILE" ]; then
    cp "$FILE" "$OUT/$NAME.png"
  fi
done

NOTES=$(find "$RAW" -type f -iname "notes*" 2>/dev/null | head -1)
if [ -n "$NOTES" ]; then
  cp "$NOTES" "$OUT/notes.json"
fi

if [ ! -f "$OUT/01-open.png" ]; then
  CONTAINER=$(find "$HOME/Library/Developer/CoreSimulator/Devices" -type d -path "*/tmp/$FOLDER" 2>/dev/null | head -1)
  echo "container fallback: ${CONTAINER:-none}"
  if [ -n "${CONTAINER:-}" ]; then
    cp "$CONTAINER"/*.png "$OUT/" 2>/dev/null || true
    [ -f "$CONTAINER/notes.json" ] && cp "$CONTAINER/notes.json" "$OUT/" 2>/dev/null || true
  fi
fi

ls -l "$OUT" || true
if [ ! -f "$OUT/01-open.png" ]; then
  echo "::warning::no frames for $OUT: neither the result bundle nor a device container had them"
  exit 1
fi
