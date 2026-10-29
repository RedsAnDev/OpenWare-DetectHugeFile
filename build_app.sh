#!/bin/bash
# Compila e crea DetectHugeFile.app (firma ad-hoc). Uso: ./build_app.sh [--open]
set -e
cd "$(dirname "$0")"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
# ARCHS="arm64 x86_64" → binario universale
ARCH_FLAGS=""
for a in ${ARCHS:-}; do ARCH_FLAGS="$ARCH_FLAGS --arch $a"; done
swift build -c release $ARCH_FLAGS
BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)/DetectHugeFile"
APP=DetectHugeFile.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources"
[ -f Tools/AppIcon.icns ] || swift Tools/make_icon.swift Tools/AppIcon.icns
cp Tools/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>DetectHugeFile</string>
<key>CFBundleDisplayName</key><string>DetectHugeFile</string>
<key>CFBundleIdentifier</key><string>dev.rossiandrea.DetectHugeFile</string>
<key>CFBundleExecutable</key><string>DetectHugeFile</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Serve per svuotare il Cestino tramite Finder.</string>
</dict></plist>
PL
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "Creata $PWD/$APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
