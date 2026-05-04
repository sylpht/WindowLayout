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

# Auto-update the homebrew tap cask if it's a sibling directory.
CASK="homebrew-tap/Casks/windowlayout.rb"
if [ -f "$CASK" ]; then
    sed -i '' "s/sha256 \".*\"/sha256 \"$SHA\"/" "$CASK"
    sed -i '' "s/version \".*\"/version \"$VERSION\"/" "$CASK"
    echo "▶ Updated $CASK with new version + SHA"
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
echo "    open $DMG  # then drag WindowLayout to Applications"
echo "    open /Applications/WindowLayout.app  # right-click → Open on first launch"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  HOMEBREW CASK SNIPPET (paste into Casks/windowlayout.rb):"
echo "════════════════════════════════════════════════════════"
cat <<EOF

cask "windowlayout" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/sylpht/WindowLayout/releases/download/v#{version}/WindowLayout.dmg"
  name "WindowLayout"
  desc "Save and restore macOS window arrangements when you reconnect external displays"
  homepage "https://github.com/sylpht/WindowLayout"

  depends_on macos: ">= :ventura"

  app "WindowLayout.app"

  zap trash: [
    "~/Library/Application Support/WindowLayout",
    "~/Library/Logs/WindowLayout",
    "~/Library/Mobile Documents/com~apple~CloudDocs/WindowLayout",
    "~/Library/Preferences/com.windowlayout.app.plist",
  ]
end

EOF
