#!/bin/zsh
# Builds "Tablero.app" (native board window + daily notification) from notifier.swift + icon.png.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Applications/Tablero.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Build in a scratch dir and swap at the end: a failed build never leaves you without the app.
APP="$WORK/Tablero.app"
ICONSET="$WORK/icon.iconset"
VERSION="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo dev)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/Tablero" "$DIR/notifier.swift"

mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$DIR/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$DIR/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp /System/Library/Sounds/Glass.aiff "$APP/Contents/Resources/"

sed "s/__VERSION__/$VERSION/" > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.darwin-elegiga.tablero</string>
  <key>CFBundleName</key><string>Tablero</string>
  <key>CFBundleDisplayName</key><string>Tablero</string>
  <key>CFBundleExecutable</key><string>Tablero</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0 (__VERSION__)</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$DEST.old"
[[ -d "$DEST" ]] && mv "$DEST" "$DEST.old"
mv "$APP" "$DEST"
rm -rf "$DEST.old"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "Built $DEST ($VERSION)"
