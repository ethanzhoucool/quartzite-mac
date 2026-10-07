#!/bin/bash
# Builds Quartzite.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=Quartzite.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Quartzite "$APP/Contents/MacOS/Quartzite"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
if [ ! -f Packaging/AppIcon.icns ]; then
  TMP=$(mktemp -d)
  swift Packaging/make_icon.swift "$TMP/icon.png"
  mkdir "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o Packaging/AppIcon.icns
fi
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP"
echo "Built $(pwd)/$APP"
