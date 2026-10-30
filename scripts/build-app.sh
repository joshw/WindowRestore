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

# tccutil looks the bundle ID up through Launch Services, which only knows
# apps it has seen, so register the fresh build first.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

# An ad-hoc signature changes on every build, which leaves the old
# Accessibility approval showing as on but no longer applying. Clear it so
# the app asks again on launch.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    tccutil reset Accessibility local.windowrestore >/dev/null 2>&1 || true
    echo "Cleared the old Accessibility approval; approve the app again when it asks."
fi

echo "Built $APP"
