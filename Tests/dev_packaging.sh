#!/bin/bash
# Regression tests for dev signing/packaging; tool stubs never touch real apps.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/WindowLayoutPackagingTests.XXXXXX) || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT
PASSED=0
FAILED=0

fixture() {
    FIXTURE=$(mktemp -d "$TEST_ROOT/case.XXXXXX") || return 1
    mkdir -p "$FIXTURE/bin" "$FIXTURE/tmp" "$FIXTURE/WindowLayout" || return 1
    cp "$REPO/build.sh" "$REPO/make_dmg.sh" "$FIXTURE/" || return 1
    printf 'plist fixture\n' > "$FIXTURE/WindowLayout/Info.plist"
    printf 'icon fixture\n' > "$FIXTURE/WindowLayout/AppIcon.icns"
    printf 'entitlements fixture\n' > "$FIXTURE/WindowLayout/WindowLayout.entitlements"
    cat > "$FIXTURE/bin/tool" <<'STUB'
#!/bin/bash
set -eo pipefail
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$DEV_TEST_CASE/calls"
map_path() {
    case "$1" in
        /Applications/*) printf '%s%s' "$DEV_TEST_CASE" "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}
fingerprint() {
    cat "$1/Contents/MacOS/WindowLayout" "$1/Contents/Info.plist" "$1/Contents/Resources/AppIcon.icns" \
        | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}
case "$name" in
    mktemp)
        template=${@: -1}
        /usr/bin/mktemp -d "$DEV_TEST_CASE/tmp/${template##*/}"
        ;;
    xcrun) printf '/fake-sdk\n' ;;
    swiftc|lipo)
        [ "${DEV_TEST_FAIL_COMPILE:-0}" != 1 ] || exit 91
        target=universal
        output=''
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -target) target=$2; shift 2 ;;
                -o|-output) output=$2; shift 2 ;;
                -archs) printf 'x86_64 arm64\n'; exit 0 ;;
                *) shift ;;
            esac
        done
        printf 'binary %s\n' "$target" > "$output"
        ;;
    xattr) /usr/bin/xattr "$@" ;;
    ditto)
        [ "$1" = --noextattr ] && [ "$2" = --noacl ] || exit 92
        /usr/bin/ditto --noextattr --noacl "$(map_path "$3")" "$(map_path "$4")"
        ;;
    codesign)
        app=$(map_path "${@: -1}")
        if [ "$1" = --verify ]; then
            [ -f "$app/Contents/_CodeSignature/identity" ] || exit 93
            [ "$(cat "$app/Contents/_CodeSignature/payload")" = "$(fingerprint "$app")" ] || exit 94
            if /usr/bin/xattr -p com.apple.FinderInfo "$app" >/dev/null 2>&1; then exit 95; fi
        elif [ "$1" = -dv ]; then
            printf 'Identifier=com.windowlayout.app\nTeamIdentifier=FAKE\n'
        else
            [ "${DEV_TEST_FAIL_SIGN:-0}" != 1 ] || exit 96
            identity=''
            timestamp=default
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --sign) identity=$2; shift 2 ;;
                    --timestamp) timestamp=1; shift ;;
                    --timestamp=none) timestamp=0; shift ;;
                    *) shift ;;
                esac
            done
            [ -n "$identity" ] || exit 97
            case "$identity" in
                'Developer ID Application:'*) [ "$timestamp" = 1 ] || exit 98 ;;
            esac
            if [ "${DEV_TEST_OFFLINE:-0}" = 1 ] && [ "$timestamp" = 1 ]; then exit 103; fi
            mkdir -p "$app/Contents/_CodeSignature"
            printf '%s\n' "$identity" > "$app/Contents/_CodeSignature/identity"
            printf '%s\n' "$timestamp" > "$app/Contents/_CodeSignature/timestamp"
            fingerprint "$app" > "$app/Contents/_CodeSignature/payload"
        fi
        ;;
    hdiutil)
        operation=$1; shift
        case "$operation" in
            create)
                image=${@: -1}
                source=''
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = -srcfolder ]; then source=$2; shift 2; else shift; fi
                done
                /usr/bin/ditto "$source" "$image.contents"
                /usr/bin/ditto "$source/WindowLayout.app" "$DEV_TEST_CASE/packaged.app"
                printf 'DMG\n' > "$image"
                cat "$source/WindowLayout.app/Contents/_CodeSignature/identity" >> "$image"
                ;;
            verify) [ "${DEV_TEST_FAIL_IMAGE_VERIFY:-0}" != 1 ] || exit 99 ;;
            attach)
                image=${@: -1}
                mount=''
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = -mountpoint ]; then mount=$2; shift 2; else shift; fi
                done
                /usr/bin/ditto "$image.contents" "$mount"
                if [ "${DEV_TEST_TAMPER_IMAGE:-0}" = 1 ]; then
                    printf 'changed\n' >> "$mount/WindowLayout.app/Contents/MacOS/WindowLayout"
                elif [ "${DEV_TEST_TAMPER_IMAGE:-0}" = 2 ]; then
                    printf 'different signing identity\n' > "$mount/WindowLayout.app/Contents/_CodeSignature/identity"
                fi
                ;;
            detach) : ;;
            *) exit 100 ;;
        esac
        ;;
    rm)
        args=()
        for arg in "$@"; do
            mapped=$(map_path "$arg")
            case "$mapped" in
                /*) [[ "$mapped" == "$DEV_TEST_CASE/"* ]] || exit 101 ;;
            esac
            args+=("$mapped")
        done
        /bin/rm "${args[@]}"
        ;;
    pkill|open|sleep) printf '%s\n' "$name" >> "$DEV_TEST_CASE/lifecycle" ;;
    pgrep) printf '%s\n' "$name" >> "$DEV_TEST_CASE/lifecycle"; printf '12345\n' ;;
    *) exit 102 ;;
esac
STUB
    chmod +x "$FIXTURE/bin/tool" || return 1
    local name
    for name in mktemp xcrun swiftc lipo xattr ditto codesign hdiutil rm pkill open pgrep sleep; do
        ln -s tool "$FIXTURE/bin/$name" || return 1
    done
}

run_script() (
    unset WL_SIGN_TIMESTAMP
    if [ "${TEST_TIMESTAMP+x}" = x ]; then export WL_SIGN_TIMESTAMP="$TEST_TIMESTAMP"; fi
    PATH="$FIXTURE/bin:$PATH" DEV_TEST_CASE="$FIXTURE" \
        WL_SIGN_IDENTITY="${TEST_IDENTITY:--}" \
        DEV_TEST_OFFLINE="${OFFLINE:-0}" \
        DEV_TEST_FAIL_SIGN="${FAIL_SIGN:-0}" \
        DEV_TEST_FAIL_IMAGE_VERIFY="${FAIL_IMAGE_VERIFY:-0}" \
        DEV_TEST_TAMPER_IMAGE="${TAMPER_IMAGE:-0}" \
        /bin/bash "$FIXTURE/$1" "${@:2}"
)

assert_no_lifecycle() { [ ! -e "$FIXTURE/lifecycle" ]; }
assert_old_dmg() { [ "$(cat "$FIXTURE/WindowLayout.dmg")" = 'previous DMG' ]; }

build_only() {
    fixture || return 1
    TEST_IDENTITY='Developer ID Application: Explicit Test (FAKE)'
    printf 'WL_SIGN_IDENTITY="Apple Development: Local Default (OTHER)"\n' > "$FIXTURE/.signing.local"
    run_script build.sh --no-install || return 1
    [ "$(cat "$FIXTURE/WindowLayout.app/Contents/_CodeSignature/identity")" = "$TEST_IDENTITY" ] \
        && assert_no_lifecycle && [ -z "$(ls -A "$FIXTURE/tmp")" ]
}

development_offline() {
    fixture || return 1
    TEST_IDENTITY='Apple Development: Offline Test (FAKE)'
    OFFLINE=1
    run_script build.sh --no-install || return 1
    [ "$(cat "$FIXTURE/WindowLayout.app/Contents/_CodeSignature/timestamp")" = 0 ] \
        && assert_no_lifecycle
}

timestamp_override() {
    fixture || return 1
    TEST_IDENTITY='Apple Development: Offline Test (FAKE)'
    TEST_TIMESTAMP=0
    OFFLINE=1
    printf 'WL_SIGN_TIMESTAMP=1\n' > "$FIXTURE/.signing.local"
    run_script build.sh --no-install || return 1
    [ "$(cat "$FIXTURE/WindowLayout.app/Contents/_CodeSignature/timestamp")" = 0 ] \
        && assert_no_lifecycle
}

fingerprint_timestamp() {
    fixture || return 1
    TEST_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567
    # The certificate name is unavailable when selecting it by fingerprint.
    printf 'WL_SIGN_TIMESTAMP=1\n' > "$FIXTURE/.signing.local"
    run_script build.sh --no-install || return 1
    [ "$(cat "$FIXTURE/WindowLayout.app/Contents/_CodeSignature/timestamp")" = 1 ] \
        && assert_no_lifecycle
}

invalid_timestamp() {
    fixture || return 1
    TEST_TIMESTAMP=$1
    TEST_IDENTITY=${2:--}
    if run_script build.sh --no-install; then return 1; fi
    [ ! -e "$FIXTURE/calls" ] && assert_no_lifecycle
}

package_signed() {
    fixture || return 1
    TEST_IDENTITY='Developer ID Application: Test (FAKE)'
    run_script build.sh --no-install || return 1
    # Cloud-provider metadata must be discarded without stripping the signature.
    /usr/bin/xattr -wx com.apple.FinderInfo 0000000000000000000000000000000000000000000000000000000000000001 \
        "$FIXTURE/WindowLayout.app" || return 1
    run_script make_dmg.sh || return 1
    cmp "$FIXTURE/WindowLayout.app/Contents/_CodeSignature/identity" \
        "$FIXTURE/packaged.app/Contents/_CodeSignature/identity" || return 1
    cmp "$FIXTURE/WindowLayout.app/Contents/_CodeSignature/payload" \
        "$FIXTURE/packaged.app/Contents/_CodeSignature/payload" || return 1
    [ "$(grep -c '^codesign --force' "$FIXTURE/calls")" = 1 ] \
        && grep -q '^hdiutil attach -readonly -nobrowse' "$FIXTURE/calls" \
        && grep -q '^hdiutil detach ' "$FIXTURE/calls" \
        && assert_no_lifecycle && [ -z "$(ls -A "$FIXTURE/tmp")" ]
}

package_missing() {
    fixture || return 1
    run_script make_dmg.sh || return 1
    [ -f "$FIXTURE/WindowLayout.dmg" ] \
        && [ -f "$FIXTURE/WindowLayout.app/Contents/_CodeSignature/identity" ] \
        && assert_no_lifecycle
}

reject_app() {
    fixture || return 1
    run_script build.sh --no-install || return 1
    if [ "$1" = unsigned ]; then
        rm -rf "$FIXTURE/WindowLayout.app/Contents/_CodeSignature"
    else
        printf 'tampered\n' >> "$FIXTURE/WindowLayout.app/Contents/MacOS/WindowLayout"
    fi
    printf 'previous DMG\n' > "$FIXTURE/WindowLayout.dmg"
    if run_script make_dmg.sh; then return 1; fi
    assert_old_dmg && ! grep -q '^hdiutil create ' "$FIXTURE/calls" && assert_no_lifecycle
}

reject_image() {
    fixture || return 1
    run_script build.sh --no-install || return 1
    printf 'previous DMG\n' > "$FIXTURE/WindowLayout.dmg"
    case "$1" in
        checksum) FAIL_IMAGE_VERIFY=1 ;;
        signature) TAMPER_IMAGE=2 ;;
        *) TAMPER_IMAGE=1 ;;
    esac
    if run_script make_dmg.sh; then return 1; fi
    assert_old_dmg && assert_no_lifecycle && [ -z "$(ls -A "$FIXTURE/tmp")" ]
}

sign_failure() {
    fixture || return 1
    run_script build.sh --no-install || return 1
    cp "$FIXTURE/WindowLayout.app/Contents/_CodeSignature/payload" "$FIXTURE/old-signature" || return 1
    FAIL_SIGN=1
    if run_script build.sh --no-install; then return 1; fi
    cmp "$FIXTURE/old-signature" "$FIXTURE/WindowLayout.app/Contents/_CodeSignature/payload" \
        && assert_no_lifecycle && [ -z "$(ls -A "$FIXTURE/tmp")" ]
}

default_install() {
    fixture || return 1
    run_script build.sh || return 1
    [ -f "$FIXTURE/Applications/WindowLayout.app/Contents/_CodeSignature/identity" ] \
        && grep -q '^pkill$' "$FIXTURE/lifecycle" && grep -q '^open$' "$FIXTURE/lifecycle"
}

invalid_option() {
    fixture || return 1
    if run_script build.sh --invalid; then return 1; fi
    [ ! -e "$FIXTURE/calls" ] && assert_no_lifecycle
}

test_case() {
    local label=$1
    shift
    local log="$TEST_ROOT/test-$((PASSED + FAILED)).log"
    if ( "$@" ) > "$log" 2>&1; then
        PASSED=$((PASSED + 1))
        printf 'PASS %s\n' "$label"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL %s\n' "$label" >&2
        cat "$log" >&2
    fi
}

test_case 'build-only exports verified signed app and honors explicit identity' build_only
test_case 'Apple Development builds disable secure timestamps and work offline' development_offline
test_case 'explicit offline timestamp mode overrides local defaults' timestamp_override
test_case 'certificate fingerprints support secure timestamp opt-in from local defaults' fingerprint_timestamp
test_case 'invalid timestamp mode fails before build tools or lifecycle changes' invalid_timestamp invalid
test_case 'named Developer ID cannot disable its required secure timestamp' invalid_timestamp 0 'Developer ID Application: Test (FAKE)'
test_case 'ad-hoc signing rejects a secure timestamp request before building' invalid_timestamp 1
test_case 'DMG preserves signature, removes inherited metadata and verifies mounted app' package_signed
test_case 'missing dev app is built without installation or app lifecycle changes' package_missing
test_case 'unsigned dev app is rejected without replacing an existing DMG' reject_app unsigned
test_case 'modified dev app is rejected without replacing an existing DMG' reject_app tampered
test_case 'DMG integrity failure preserves prior output and cleans staging' reject_image checksum
test_case 'tampered app inside DMG is rejected and cleaned up' reject_image app
test_case 'DMG with a different signed payload is rejected' reject_image signature
test_case 'signing failure preserves old dev app and leaves running apps alone' sign_failure
test_case 'default build still installs and launches through isolated stubs' default_install
test_case 'unknown build option fails before tools or lifecycle changes' invalid_option
printf '\nDev packaging: %s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]
