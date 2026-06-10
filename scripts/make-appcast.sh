#!/bin/zsh
# Write a single-item Sparkle appcast for the given release. Sparkle only
# needs one entry newer than the installed version, so the feed carries just
# the latest release and no history.
#
# Usage: make-appcast.sh <version> <download-url> <signature-fragment> [output]
#   signature-fragment is the raw sign_update output:
#     sparkle:edSignature="..." length="..."
set -euo pipefail

VERSION="${1:?usage: make-appcast.sh <version> <download-url> <signature-fragment> [output]}"
DOWNLOAD_URL="${2:?missing download url}"
SIGNATURE_FRAGMENT="${3:?missing sign_update signature fragment}"
OUTPUT="${4:-appcast.xml}"
# CI sets GITHUB_REPOSITORY; the fallback covers local runs.
REPO_SLUG="${GITHUB_REPOSITORY:-w159/clippy}"

if [[ "$SIGNATURE_FRAGMENT" != *sparkle:edSignature=* || "$SIGNATURE_FRAGMENT" != *length=* ]]; then
    echo "error: signature fragment must contain sparkle:edSignature and length attributes" >&2
    exit 1
fi

PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

cat > "$OUTPUT" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Clippy</title>
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <link>https://github.com/${REPO_SLUG}/releases/tag/v${VERSION}</link>
            <enclosure
                url="${DOWNLOAD_URL}"
                ${SIGNATURE_FRAGMENT}
                type="application/octet-stream" />
        </item>
    </channel>
</rss>
APPCAST

# Catch malformed output (bad signature fragment quoting, etc.) right here
# instead of letting Sparkle clients choke on it.
xmllint --noout "$OUTPUT"
echo "Wrote $OUTPUT for version ${VERSION}"
