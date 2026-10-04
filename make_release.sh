#!/bin/bash
# Build an ad-hoc-signed .dmg for testing (no paid Developer Program needed).
# This is not notarized and does not guarantee Gatekeeper acceptance. For normal
# outside-App-Store distribution, use Developer ID signing and notarization;
# see CONTRIBUTING.md.
#
# Output:
#   release/WindowLayout.dmg   — drag-to-Applications DMG
#   SHA256 printed for Homebrew cask formula
#
# Does NOT touch /Applications or your dev build — those stay as-is.

set -eo pipefail
cd "$(dirname "$0")"

source scripts/release_policy.sh

usage() {
    echo "Usage: $0 --tag vX.Y.Z[-prerelease] [--dry-run] [--update-cask]"
    echo "  --tag          Required GitHub release tag, separate from the numeric bundle version."
    echo "  --dry-run      Validate and print the plan without building or changing files."
    echo "  --update-cask  Opt in to updating a local stable Homebrew cask; forbidden for prereleases."
}

tag=""
update_cask=0
dry_run=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag)
            if [ "$#" -lt 2 ] || [ -n "$tag" ]; then usage >&2; exit 1; fi
            tag="$2"
            shift 2
            ;;
        --update-cask) update_cask=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
bundle_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" WindowLayout/Info.plist)
configure_release "$tag" "$bundle_version" "$update_cask"
CASK="homebrew-tap/Casks/windowlayout.rb"
if [ "$UPDATE_CASK" = 1 ] && [ ! -f "$CASK" ]; then
    echo "Error: --update-cask requires $CASK." >&2
    exit 1
fi

OUT="release"
DMG="$OUT/WindowLayout.dmg"
echo "▶ Release tag: $RELEASE_TAG; bundle version: $BUNDLE_VERSION; prerelease: $IS_PRERELEASE"
echo "▶ Update stable Homebrew cask: $UPDATE_CASK"
print_release_command "$DMG"
if [ "$dry_run" = 1 ]; then exit 0; fi

# Everything happens in /tmp because ~/Documents has a file-provider extension that
# auto-adds com.apple.FinderInfo to bundles, which codesign --strict rejects.
WORKDIR="/tmp/WindowLayoutRelease"
APP="$WORKDIR/WindowLayout.app"
SDK=$(xcrun --show-sdk-path --sdk macosx)

SOURCES=(
  WindowLayout/Log.swift
  WindowLayout/Localization.swift
  WindowLayout/Geometry.swift
  WindowLayout/DisplayPlacement.swift
  WindowLayout/WindowSnapshot.swift
  WindowLayout/SnapshotMatchPool.swift
  WindowLayout/ProfileFileStore.swift
  WindowLayout/DisplayProfile.swift
  WindowLayout/iCloudSync.swift
  WindowLayout/RestoreDiagnostics.swift
  WindowLayout/RestoreScheduler.swift
  WindowLayout/RestoreLifecycle.swift
  WindowLayout/LayoutManager.swift
  WindowLayout/HotKeyManager.swift
  WindowLayout/OnboardingWindowController.swift
  WindowLayout/StatusBarController.swift
  WindowLayout/AppDelegate.swift
  WindowLayout/main.swift
)

echo "▶ Building WindowLayout $RELEASE_TAG (ad-hoc signed)"

rm -rf "$OUT" "$WORKDIR"
mkdir -p "$OUT" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ Compiling arm64…"
swiftc "${SOURCES[@]}" -O -sdk "$SDK" -target arm64-apple-macos13.0 -o "$WORKDIR/WL_arm64"

echo "▶ Compiling x86_64…"
swiftc "${SOURCES[@]}" -O -sdk "$SDK" -target x86_64-apple-macos13.0 -o "$WORKDIR/WL_x86_64"

echo "▶ Creating universal binary…"
lipo -create "$WORKDIR/WL_arm64" "$WORKDIR/WL_x86_64" \
  -output "$APP/Contents/MacOS/WindowLayout"
rm -f "$WORKDIR/WL_arm64" "$WORKDIR/WL_x86_64"

cp WindowLayout/Info.plist "$APP/Contents/"
cp WindowLayout/AppIcon.icns "$APP/Contents/Resources/"

echo "▶ Ad-hoc signing with Hardened Runtime…"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - \
  --options runtime \
  --entitlements WindowLayout/WindowLayout.entitlements \
  "$APP"

echo "▶ Verifying…"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

echo "▶ Building DMG…"
DMG_STAGE="$WORKDIR/dmg-stage"
mkdir -p "$DMG_STAGE"
ditto --noextattr --noacl "$APP" "$DMG_STAGE/WindowLayout.app"
ln -s /Applications "$DMG_STAGE/Applications"
# DMG itself is created in /tmp first, then moved to release/ (single file move
# doesn't trigger fileprovider's bundle-xattr behavior).
TMP_DMG="$WORKDIR/WindowLayout.dmg"
hdiutil create \
  -volname "WindowLayout" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$TMP_DMG" >/dev/null
mv "$TMP_DMG" "$DMG"
rm -rf "$WORKDIR"

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
SIZE=$(du -h "$DMG" | awk '{print $1}')

# Stable cask updates are opt-in. RC builds never touch the stable channel.
# Rebuilding a stable version already in the cask preserves its published SHA.
update_release_cask "$CASK" "$SHA"

echo ""
echo "════════════════════════════════════════════════════════"
echo "  ✓ RELEASE BUILD READY"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  DMG:     $DMG ($SIZE)"
echo "  SHA256:  $SHA"
echo ""
echo "  Test install:"
echo "    open $DMG  # drag WindowLayout to Applications"
echo "    open /Applications/WindowLayout.app  # macOS 15+: approve in System Settings → Privacy"
echo ""
echo "  After testing, commit and tag the release sources as $RELEASE_TAG."
echo "  Publish using the exact tag (do not replace an existing release):"
print_release_command "$DMG"
if [ "$CASK_BUMPED" = "1" ]; then
    echo "════════════════════════════════════════════════════════"
    echo "  RELEASE CHECKLIST — stable cask bumped to $RELEASE_TAG:"
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "  Once the GitHub release exists, push the tap so 'brew upgrade' picks it up:"
    echo "     cd homebrew-tap && git add Casks/windowlayout.rb \\"
    echo "       && git commit -m \"Bump windowlayout to $RELEASE_TAG\" \\"
    echo "       && git push"
    echo ""
    echo "  Order matters: GitHub Release must exist BEFORE users 'brew install',"
    echo "  otherwise the cask URL 404s."
fi
