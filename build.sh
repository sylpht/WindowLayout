#!/bin/bash
# Build universal (arm64 + x86_64) .app, sign, install to /Applications.
# Signing happens in /tmp because iCloud Drive adds xattrs codesign rejects.
#
# Signing identity:
#   1. Set $WL_SIGN_IDENTITY in env, or
#   2. Put `WL_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"` into
#      .signing.local (gitignored), or
#   3. Falls back to ad-hoc "-" (Accessibility permission resets every build).

set -e
cd "$(dirname "$0")"

[ -f .signing.local ] && source .signing.local
IDENTITY="${WL_SIGN_IDENTITY:--}"

SDK=$(xcrun --show-sdk-path --sdk macosx)
APP="WindowLayout.app"
STAGE="/tmp/WindowLayout.app"

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

pkill -x WindowLayout 2>/dev/null || true
sleep 0.3

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ Compiling arm64…"
swiftc "${SOURCES[@]}" -sdk "$SDK" -target arm64-apple-macos13.0 -o /tmp/WindowLayout_arm64

echo "▶ Compiling x86_64…"
swiftc "${SOURCES[@]}" -sdk "$SDK" -target x86_64-apple-macos13.0 -o /tmp/WindowLayout_x86_64

echo "▶ Creating universal binary…"
lipo -create /tmp/WindowLayout_arm64 /tmp/WindowLayout_x86_64 \
  -output "$APP/Contents/MacOS/WindowLayout"
rm -f /tmp/WindowLayout_arm64 /tmp/WindowLayout_x86_64

cp WindowLayout/Info.plist "$APP/Contents/"
cp WindowLayout/AppIcon.icns "$APP/Contents/Resources/"

echo "▶ Signing as: $IDENTITY"
rm -rf "$STAGE"
cp -R "$APP" "$STAGE"
xattr -cr "$STAGE" 2>/dev/null || true
# --options runtime enables Hardened Runtime, which is a prerequisite for notarisation.
# (Notarisation itself requires a paid Developer ID Application cert + `xcrun notarytool` —
# see CONTRIBUTING.md for the public-release flow.)
codesign --force --deep --sign "$IDENTITY" \
  --options runtime \
  --entitlements WindowLayout/WindowLayout.entitlements \
  "$STAGE"

echo "▶ Installing to /Applications…"
rm -rf /Applications/WindowLayout.app
ditto "$STAGE" /Applications/WindowLayout.app

open /Applications/WindowLayout.app
sleep 1.5

if pgrep -x WindowLayout >/dev/null; then
    echo "✓ Running (PID $(pgrep -x WindowLayout))"
    codesign -dv /Applications/WindowLayout.app 2>&1 | grep -E "Identifier|TeamIdentifier"
    echo "✓ Architectures: $(lipo -archs /Applications/WindowLayout.app/Contents/MacOS/WindowLayout)"
else
    echo "✗ Failed to launch"
    exit 1
fi
