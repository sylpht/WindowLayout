#!/bin/bash
# Build a quick .dmg from your local dev build (Apple Development signed).
# Useful for sharing a test build with a teammate on the same machine setup.
#
# For PUBLIC distribution use ./make_release.sh — it produces an ad-hoc-signed
# DMG that survives Gatekeeper download checks. Apple Development-signed DMGs
# trigger the "App is damaged" warning when downloaded by anyone else.

set -e
cd "$(dirname "$0")"

APP="WindowLayout.app"
DMG="WindowLayout.dmg"
VOLNAME="WindowLayout"

if [ ! -d "$APP" ]; then
    echo "▶ No $APP — running ./build.sh first"
    ./build.sh
fi

echo "▶ Staging…"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Make sure no old .dmg is in the way
rm -f "$DMG"

echo "▶ Creating $DMG"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG"

rm -rf "$STAGE"

echo "✓ $DMG ready"
ls -lh "$DMG"
