#!/bin/sh
# Builds Huecast.app into macos/build/. Needs macOS 14+ and Xcode or the
# Command Line Tools (xcode-select --install).
#
#   ./build-app.sh          release build
#   open build/Huecast.app
set -eu
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Huecast"

APP=build/Huecast.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Huecast"
cp Support/Info.plist "$APP/Contents/Info.plist"

# App icon from the web app's icon
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size ../icons/icon-512.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double ../icons/icon-512.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Ad-hoc signature, so macOS remembers the location permission
codesign --force --sign - "$APP"

echo "Built $APP"
