#!/bin/bash
# Package the signed local dev app without changing its signing identity.
# A missing app is built with --no-install; packaging never installs or launches it.
# Signing alone does not provide notarization or guarantee Gatekeeper acceptance.

set -eo pipefail
cd "$(dirname "$0")"

if [ "$#" -gt 0 ]; then
    if [ "$#" = 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
        echo "Usage: $0"
        exit 0
    fi
    echo "Usage: $0" >&2
    exit 1
fi

APP="WindowLayout.app"
DMG="WindowLayout.dmg"
if [ ! -d "$APP" ]; then
    echo "▶ No $APP — building without installing or launching"
    ./build.sh --no-install
fi

WORKDIR=$(mktemp -d /tmp/WindowLayoutDMG.XXXXXX)
MOUNT="$WORKDIR/mounted"
MOUNTED=0
PUBLISH_DMG=""
cleanup() {
    local result=$?
    if [ -n "$PUBLISH_DMG" ]; then rm -f "$PUBLISH_DMG"; fi
    if [ "$MOUNTED" = 1 ]; then
        if ! hdiutil detach "$MOUNT" >/dev/null 2>&1; then
            echo "Could not detach $MOUNT; temporary files retained in $WORKDIR." >&2
            exit 1
        fi
    fi
    rm -rf "$WORKDIR"
    exit "$result"
}
trap cleanup EXIT

STAGE="$WORKDIR/stage"
mkdir -p "$STAGE" "$MOUNT"
echo "▶ Staging signed app…"
ditto --noextattr --noacl "$APP" "$STAGE/WindowLayout.app"
xattr -cr "$STAGE/WindowLayout.app"
# This checks the clean copy rather than cloud-provider metadata on the source.
codesign --verify --deep --strict --verbose=2 "$STAGE/WindowLayout.app"
ln -s /Applications "$STAGE/Applications"

TMP_DMG="$WORKDIR/WindowLayout.dmg"
echo "▶ Creating $DMG"
hdiutil create -volname "WindowLayout" -srcfolder "$STAGE" -format UDZO "$TMP_DMG" >/dev/null
hdiutil verify "$TMP_DMG" >/dev/null

# Verify what will actually be distributed, then replace the previous DMG only
# after every check succeeds. Nothing in this path launches the contained app.
MOUNTED=1
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$TMP_DMG" >/dev/null
codesign --verify --deep --strict --verbose=2 "$MOUNT/WindowLayout.app"
diff -qr "$STAGE/WindowLayout.app" "$MOUNT/WindowLayout.app"
hdiutil detach "$MOUNT" >/dev/null
MOUNTED=0
# The checkout can be on another filesystem from /tmp. Copy to a temporary file
# beside the destination first, so the final rename cannot fall back to copying.
PUBLISH_DMG=$(mktemp "./.${DMG}.XXXXXX")
cp "$TMP_DMG" "$PUBLISH_DMG"
cmp "$TMP_DMG" "$PUBLISH_DMG"
chmod 644 "$PUBLISH_DMG"
if [ -d "$DMG" ]; then
    echo "Cannot replace $DMG: the destination is a directory." >&2
    exit 1
fi
mv -f "$PUBLISH_DMG" "$DMG"
PUBLISH_DMG=""

echo "✓ $DMG ready (embedded app signature verified)"
ls -lh "$DMG"
