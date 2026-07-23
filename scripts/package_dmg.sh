#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo "usage: package_dmg.sh <app-path> <output.dmg> [volume-name] [app-name]" >&2
  exit 64
fi

APP_PATH="$1"
OUTPUT_DMG="$2"
VOLUME_NAME="${3:-Clipth}"
APP_NAME="${4:-$(basename "$APP_PATH" .app)}"

if [ ! -d "$APP_PATH" ]; then
  echo "App not found at $APP_PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ICON_PATH="$ROOT_DIR/Clipth/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"
if [ ! -f "$ICON_PATH" ]; then
  ICON_PATH="$ROOT_DIR/Clipth/Assets.xcassets/AppIcon.appiconset/icon_512x512.png"
fi

WORK_DIR="$(mktemp -d)"
MOUNT_DIR=""
RW_DMG="$WORK_DIR/$VOLUME_NAME.rw.dmg"
BACKGROUND_NAME="dmg-background.png"
BACKGROUND_PATH="$WORK_DIR/$BACKGROUND_NAME"
DEVICE=""

cleanup() {
  if [ -n "$DEVICE" ] && hdiutil info | grep -q "$DEVICE"; then
    hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

swift "$ROOT_DIR/scripts/render_dmg_background.swift" "$BACKGROUND_PATH" "$APP_NAME" "$ICON_PATH"

APP_SIZE_KB="$(du -sk "$APP_PATH" | awk '{print $1}')"
IMAGE_SIZE_MB="$((APP_SIZE_KB / 1024 + 160))"
if [ "$IMAGE_SIZE_MB" -lt 240 ]; then
  IMAGE_SIZE_MB=240
fi

hdiutil create \
  -size "${IMAGE_SIZE_MB}m" \
  -fs HFS+ \
  -volname "$VOLUME_NAME" \
  -ov \
  "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
DEVICE="$(printf "%s\n" "$ATTACH_OUTPUT" | awk -F '\t' '/Apple_HFS|Apple_APFS/ {gsub(/^ +| +$/, "", $1); print $1; exit}')"
MOUNT_DIR="$(printf "%s\n" "$ATTACH_OUTPUT" | awk -F '\t' '/Apple_HFS|Apple_APFS/ {gsub(/^ +| +$/, "", $NF); print $NF; exit}')"
if [ -z "$DEVICE" ]; then
  echo "Failed to attach writable DMG" >&2
  exit 1
fi
if [ -z "$MOUNT_DIR" ] || [ ! -d "$MOUNT_DIR" ]; then
  echo "Failed to find DMG mount point" >&2
  exit 1
fi

cp -R "$APP_PATH" "$MOUNT_DIR/$APP_NAME.app"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"
cp "$BACKGROUND_PATH" "$MOUNT_DIR/.background/$BACKGROUND_NAME"
chflags hidden "$MOUNT_DIR/.background"

sync

osascript - "$VOLUME_NAME" "$APP_NAME" "$MOUNT_DIR/.background/$BACKGROUND_NAME" <<'APPLESCRIPT'
on run argv
  set diskName to item 1 of argv
  set appName to item 2 of argv
  set backgroundPath to item 3 of argv
  set appItemName to appName & ".app"

  tell application "Finder"
    try
      close window diskName
    end try

    set targetDisk to disk diskName
    open targetDisk
    delay 1

    set diskWindow to container window of targetDisk
    set current view of diskWindow to icon view
    set toolbar visible of diskWindow to false
    set statusbar visible of diskWindow to false
    set the bounds of diskWindow to {100, 100, 820, 540}

    set viewOptions to the icon view options of diskWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 16
    set background picture of viewOptions to (POSIX file backgroundPath as alias)

    set position of item appItemName of targetDisk to {180, 220}
    set position of item "Applications" of targetDisk to {540, 220}

    update targetDisk without registering applications
    delay 1
    close diskWindow
  end tell
end run
APPLESCRIPT

sync
hdiutil detach "$DEVICE" >/dev/null
DEVICE=""

mkdir -p "$(dirname "$OUTPUT_DMG")"
rm -f "$OUTPUT_DMG"
hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT_DMG" >/dev/null

echo "Created $OUTPUT_DMG"
