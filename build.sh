#!/bin/zsh
# Builds "Local Demo.app" and installs it in ~/Applications (replacing any previous version).
set -euo pipefail
cd "$(dirname "$0")"

NAME="Local Demo"
BUILD=".build"
APP="$BUILD/$NAME.app"
DEST="$HOME/Applications"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/AppIcon.iconset"

echo "→ Compilando…"
swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  LocalDemoApp.swift -o "$APP/Contents/MacOS/LocalDemoApp"

cp Info.plist "$APP/Contents/Info.plist"

echo "→ Generando icono…"
swift make_icon.swift logo.png "$BUILD/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon_1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon_1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "→ Firmando (ad-hoc)…"
codesign --force --deep -s - "$APP"

echo "→ Instalando en $DEST…"
osascript -e "quit app \"$NAME\"" 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/$NAME.app"
mv "$APP" "$DEST/"
touch "$DEST/$NAME.app"

rm -rf "$BUILD"
echo "✓ Listo: $DEST/$NAME.app"
