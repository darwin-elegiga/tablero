#!/bin/zsh
# Builds the board app (native window + daily notification) from notifier.swift + icon.png.
# Its name comes from config.json ("name", set by clicking the board title); default "Tablero".
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="io.github.darwin-elegiga.tablero"
NAME="$(plutil -extract name raw -o - "$DIR/config.json" 2>/dev/null || true)"
[[ -n "$NAME" ]] || NAME="Tablero"
DEST="$HOME/Applications/${NAME//[\/:]/-}.app" # "/" and ":" are not allowed in file names
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Build in a scratch dir and swap at the end: a failed build never leaves you without the app.
APP="$WORK/app.app"
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

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>__BUNDLE_ID__</string>
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

# plutil escapes the name properly (it may contain &, <, quotes...).
plutil -replace CFBundleName -string "$NAME" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$NAME" "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP"

# Move aside every previous build of this app (same bundle id, maybe under an old name), then swap in.
mkdir -p "$HOME/Applications"
OLD="$WORK/old"
mkdir -p "$OLD"
for existing in "$HOME/Applications"/*.app(N); do
  [[ "$(plutil -extract CFBundleIdentifier raw -o - "$existing/Contents/Info.plist" 2>/dev/null)" == "$BUNDLE_ID" ]] &&
    mv "$existing" "$OLD/"
done
if ! mv "$APP" "$DEST"; then
  mv "$OLD"/*.app(N) "$HOME/Applications/" # put the previous build back
  exit 1
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "Built $DEST ($NAME, $VERSION)"
