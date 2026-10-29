#!/bin/bash
# Builds build/WindowRestore.app. Set SIGN_IDENTITY to a codesigning identity
# (e.g. "Apple Development: you@example.com") so the Accessibility grant
# survives rebuilds; the default ad-hoc signature changes on every build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/WindowRestore.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/WindowRestore "$APP/Contents/MacOS/WindowRestore"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>WindowRestore</string>
    <key>CFBundleIdentifier</key><string>local.windowrestore</string>
    <key>CFBundleName</key><string>Window Restore</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
