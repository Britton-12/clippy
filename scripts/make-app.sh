#!/bin/zsh
# Build a release binary and wrap it in Clippy.app. The bundle (with a stable
# bundle id and an ad-hoc signature) is what makes the Accessibility
# permission grant survive rebuilds.
#
# Usage: make-app.sh [version]
#   version defaults to $VERSION or 0.0.0-dev. CI passes the git tag value.
#   REQUIRE_SPARKLE=1 makes a missing Sparkle public key a hard error (CI).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${VERSION:-0.0.0-dev}}"
# CI sets GITHUB_REPOSITORY; the fallback covers local builds.
REPO_SLUG="${GITHUB_REPOSITORY:-w159/clippy}"
FEED_URL="https://raw.githubusercontent.com/${REPO_SLUG}/main/appcast.xml"
PUBLIC_KEY_FILE="scripts/sparkle-public-key.txt"

swift build -c release

APP="build/Clippy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp .build/release/Clippy "$APP/Contents/MacOS/Clippy"

# Sparkle ships as a binary xcframework inside the SwiftPM artifacts dir; the
# app bundle needs its own embedded copy plus an rpath that points at it.
SPARKLE_FRAMEWORK="$(find .build/artifacts -type d -name 'Sparkle.framework' -path '*macos*' | head -n 1)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "error: Sparkle.framework not found under .build/artifacts" >&2
    exit 1
fi
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Clippy"

# The Sparkle plist keys only go in when a real public key is committed;
# without them the in-app updater stays inert (local dev builds).
SPARKLE_KEYS=""
PUBLIC_KEY="$( [[ -f "$PUBLIC_KEY_FILE" ]] && tr -d '[:space:]' < "$PUBLIC_KEY_FILE" || true )"
if [[ -n "$PUBLIC_KEY" && "$PUBLIC_KEY" != REPLACE_* ]]; then
    SPARKLE_KEYS=$(cat <<KEYS
    <key>SUFeedURL</key>
    <string>${FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
KEYS
    )
elif [[ "${REQUIRE_SPARKLE:-0}" == "1" ]]; then
    echo "error: $PUBLIC_KEY_FILE missing or placeholder; run Sparkle generate_keys and commit the public key" >&2
    exit 1
else
    echo "warning: no Sparkle public key in $PUBLIC_KEY_FILE; building without auto-update" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Local-only clipboard manager.</string>
${SPARKLE_KEYS}
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP (version ${VERSION})"
