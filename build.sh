#!/bin/bash
# Build a signed universal app. By default, also install and launch it.
# --no-install only writes WindowLayout.app; it never stops or launches the app.
# Signing happens in a unique /tmp directory to avoid cloud-provider metadata.
#
# Signing identity:
#   1. Set $WL_SIGN_IDENTITY in env, or
#   2. Put `WL_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"` into
#      .signing.local (gitignored), or
#   3. Falls back to ad-hoc "-" (Accessibility permission resets every build).
# Secure timestamps default on for named Developer ID Application identities.
# Set WL_SIGN_TIMESTAMP=1 for distribution certificates selected by fingerprint;
# other local builds use --timestamp=none and need no timestamp service.

set -eo pipefail
cd "$(dirname "$0")"

INSTALL=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-install) INSTALL=0; shift ;;
        --help|-h) echo "Usage: $0 [--no-install]"; exit 0 ;;
        *) echo "Usage: $0 [--no-install]" >&2; exit 1 ;;
    esac
done

# An explicit environment identity must win over a developer's local defaults.
ENV_IDENTITY="${WL_SIGN_IDENTITY:-}"
ENV_TIMESTAMP_SET="${WL_SIGN_TIMESTAMP+x}"
ENV_TIMESTAMP="${WL_SIGN_TIMESTAMP-}"
[ -f .signing.local ] && source .signing.local
IDENTITY="${ENV_IDENTITY:-${WL_SIGN_IDENTITY:--}}"
TIMESTAMP_MODE="${WL_SIGN_TIMESTAMP-auto}"
if [ "$ENV_TIMESTAMP_SET" = x ]; then TIMESTAMP_MODE="$ENV_TIMESTAMP"; fi
case "$TIMESTAMP_MODE" in
    auto)
        case "$IDENTITY" in
            'Developer ID Application:'*) TIMESTAMP_MODE=1 ;;
            *) TIMESTAMP_MODE=0 ;;
        esac
        ;;
    0|1) ;;
    *) echo 'WL_SIGN_TIMESTAMP must be auto, 0 or 1.' >&2; exit 1 ;;
esac
case "$IDENTITY:$TIMESTAMP_MODE" in
    'Developer ID Application:'*:0)
        echo 'Developer ID distribution requires a secure timestamp; use WL_SIGN_TIMESTAMP=1 or auto.' >&2
        exit 1 ;;
    -:1)
        echo 'Ad-hoc signing cannot use a secure timestamp; use WL_SIGN_TIMESTAMP=0 or auto.' >&2
        exit 1 ;;
esac

SDK=$(xcrun --show-sdk-path --sdk macosx)
APP="WindowLayout.app"
WORKDIR=$(mktemp -d /tmp/WindowLayoutBuild.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
STAGE="$WORKDIR/WindowLayout.app"

SOURCES=(
  WindowLayout/Log.swift
  WindowLayout/Localization.swift
  WindowLayout/Geometry.swift
  WindowLayout/DisplayPlacement.swift
  WindowLayout/WindowSnapshot.swift
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

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

echo "▶ Compiling arm64…"
swiftc "${SOURCES[@]}" -sdk "$SDK" -target arm64-apple-macos13.0 -o "$WORKDIR/WindowLayout_arm64"

echo "▶ Compiling x86_64…"
swiftc "${SOURCES[@]}" -sdk "$SDK" -target x86_64-apple-macos13.0 -o "$WORKDIR/WindowLayout_x86_64"

echo "▶ Creating universal binary…"
lipo -create "$WORKDIR/WindowLayout_arm64" "$WORKDIR/WindowLayout_x86_64" \
  -output "$STAGE/Contents/MacOS/WindowLayout"
rm -f "$WORKDIR/WindowLayout_arm64" "$WORKDIR/WindowLayout_x86_64"

cp WindowLayout/Info.plist "$STAGE/Contents/"
cp WindowLayout/AppIcon.icns "$STAGE/Contents/Resources/"

echo "▶ Signing as: $IDENTITY"
xattr -cr "$STAGE"
SIGN_ARGS=(--force --deep --sign "$IDENTITY" --options runtime
    --entitlements WindowLayout/WindowLayout.entitlements)
# Only distribution signing needs Apple's network-backed timestamp service.
if [ "$TIMESTAMP_MODE" = 1 ]; then
    SIGN_ARGS+=(--timestamp)
else
    SIGN_ARGS+=(--timestamp=none)
fi
codesign "${SIGN_ARGS[@]}" "$STAGE"
codesign --verify --deep --strict --verbose=2 "$STAGE"

# Keep the signed bundle as the dev artifact used by make_dmg.sh. Clean metadata
# again after copying because a cloud provider can add FinderInfo in this folder.
rm -rf "$APP"
ditto --noextattr --noacl "$STAGE" "$APP"
xattr -cr "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "✓ Signed app: $APP"
if [ "$INSTALL" = 0 ]; then exit 0; fi

# Termination can drain pending iCloud writes. Never replace the installed bundle
# while that process is still running, and leave it intact if it will not exit.
windowlayout_is_running() {
    local status=0
    pgrep -x WindowLayout >/dev/null || status=$?
    case "$status" in
        0) return 0 ;;
        1) return 1 ;;
        *) echo 'Could not check whether WindowLayout is running; installation cancelled.' >&2
           exit "$status" ;;
    esac
}
if windowlayout_is_running; then
    pkill -TERM -x WindowLayout 2>/dev/null || true
    for ((attempt=0; attempt<50; attempt++)); do
        if ! windowlayout_is_running; then break; fi
        sleep 0.2
    done
    if windowlayout_is_running; then
        echo 'Timed out waiting for WindowLayout to exit; the installed app was not changed.' >&2
        exit 1
    fi
fi

echo "▶ Installing to /Applications…"
rm -rf /Applications/WindowLayout.app
ditto --noextattr --noacl "$STAGE" /Applications/WindowLayout.app
codesign --verify --deep --strict --verbose=2 /Applications/WindowLayout.app

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
