#!/bin/bash
# Build a distributable .dmg with drag-to-Applications UX.
# Requires a signed .app at WindowLayout.app (run ./build.sh first).

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
