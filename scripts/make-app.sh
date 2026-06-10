#!/bin/zsh
# Build a release binary and wrap it in Clippy.app. The bundle (with a stable
# bundle id and an ad-hoc signature) is what makes the Accessibility
# permission grant survive rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Clippy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Clippy "$APP/Contents/MacOS/Clippy"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Clippy</string>
    <key>CFBundleIdentifier</key>
    <string>com.jerry.clippy</string>
    <key>CFBundleName</key>
    <string>Clippy</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Local-only clipboard manager.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
