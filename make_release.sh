#!/bin/bash
# Build a distribution-grade .dmg using AD-HOC signing (no paid Developer Program needed).
#
# The resulting DMG triggers macOS Gatekeeper's "unidentified developer" warning on first
# launch (mild, has an Open button) instead of the scary "App is damaged" warning that
# Apple Development certs produce after download.
#
# Output:
#   release/WindowLayout.app   — universal binary, ad-hoc signed, Hardened Runtime
#   release/WindowLayout.dmg   — drag-to-Applications DMG
#   SHA256 printed for Homebrew cask formula
#
# Does NOT touch /Applications or your dev build — those stay as-is.

set -e
cd "$(dirname "$0")"

OUT="release"
DMG="$OUT/WindowLayout.dmg"
# Everything happens in /tmp because ~/Documents has a file-provider extension that
# auto-adds com.apple.FinderInfo to bundles, which codesign --strict rejects.
WORKDIR="/tmp/WindowLayoutRelease"
APP="$WORKDIR/WindowLayout.app"
STAGE="$WORKDIR/stage.app"
SDK=$(xcrun --show-sdk-path --sdk macosx)

SOURCES=(
  WindowLayout/Log.swift
  WindowLayout/Localization.swift
  WindowLayout/Geometry.swift
  WindowLayout/WindowSnapshot.swift
  WindowLayout/DisplayProfile.swift
  WindowLayout/iCloudSync.swift
  WindowLayout/LayoutManager.swift
  WindowLayout/HotKeyManager.swift
  WindowLayout/OnboardingWindowController.swift
  WindowLayout/StatusBarController.swift
  WindowLayout/AppDelegate.swift
  WindowLayout/main.swift
)

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" WindowLayout/Info.plist)
echo "▶ Building WindowLayout v$VERSION (release / ad-hoc signed)"

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

# Auto-update the homebrew tap cask only when the version actually bumped.
# Rebuilding the SAME version with a different binary produces a different SHA,
# but the cask must still point at the SHA of the DMG that's actually published
# on GitHub Releases — overwriting it during dev rebuilds would break `brew install`
# until a new release is uploaded.
CASK="homebrew-tap/Casks/windowlayout.rb"
if [ -f "$CASK" ]; then
    CASK_VERSION=$(grep -E '^\s*version ' "$CASK" | sed 's/.*"\(.*\)".*/\1/')
    if [ "$CASK_VERSION" != "$VERSION" ]; then
        sed -i '' "s/sha256 \".*\"/sha256 \"$SHA\"/" "$CASK"
        sed -i '' "s/version \".*\"/version \"$VERSION\"/" "$CASK"
        echo "▶ Updated $CASK: $CASK_VERSION → $VERSION (SHA $SHA)"
        echo "  Don't forget to commit + push the tap, AND upload the new DMG to GitHub Release."
    else
        echo "▶ Cask version unchanged ($VERSION) — left alone."
        echo "  When you're ready to ship, bump CFBundleShortVersionString in Info.plist first,"
        echo "  then re-run this script."
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo "  ✓ RELEASE BUILD READY"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  DMG:     $DMG ($SIZE)"
echo "  SHA256:  $SHA"
echo ""
echo "  Verify signing:"
echo "    codesign --verify --deep --strict --verbose=2 $APP"
echo ""
echo "  Test install:"
echo "    open $DMG  # drag WindowLayout to Applications"
echo "    open /Applications/WindowLayout.app  # macOS 15+: approve in System Settings → Privacy"
echo ""
if [ -f "$CASK" ]; then
    echo "════════════════════════════════════════════════════════"
    echo "  HOMEBREW TAP UPDATED — commit & push:"
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "    cd homebrew-tap"
    echo "    git add Casks/windowlayout.rb"
    echo "    git commit -m \"Bump windowlayout to v$VERSION\""
    echo "    git push"
    echo ""
    echo "  Then create the GitHub Release:"
    echo "    gh release create v$VERSION $DMG --title \"v$VERSION\" --notes \"…\""
fi
