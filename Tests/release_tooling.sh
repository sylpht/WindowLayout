#!/bin/bash
# Exercise release policy and CLI planning in temporary fixtures; never build or publish.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/windowlayout-release-tests.XXXXXX") || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT
PASSED=0
FAILED=0
OLD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEW_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

fail() { printf '    %s\n' "$*" >&2; return 1; }

write_cask() {
    cat > "$1" <<EOF
cask "windowlayout" do
  version "$2"
  sha256 "$OLD_SHA"
  url "https://github.com/sylpht/WindowLayout/releases/download/v#{version}/WindowLayout.dmg"
end
EOF
}

make_fixture() {
    FIXTURE=$(mktemp -d "$TEST_ROOT/case.XXXXXX") || return 1
    mkdir -p "$FIXTURE/scripts" "$FIXTURE/WindowLayout" "$FIXTURE/homebrew-tap/Casks" \
        "$FIXTURE/release" "$FIXTURE/bin" || return 1
    cp "$REPO_ROOT/make_release.sh" "$FIXTURE/" || return 1
    cp "$REPO_ROOT/scripts/release_policy.sh" "$FIXTURE/scripts/" || return 1
    cat > "$FIXTURE/WindowLayout/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.1.3</string>
<key>CFBundleVersion</key><string>6</string>
</dict></plist>
EOF
    CASK="$FIXTURE/homebrew-tap/Casks/windowlayout.rb"
    write_cask "$CASK" 1.1.2 || return 1
    cp "$CASK" "$FIXTURE/original-cask" || return 1
    printf 'keep existing release asset\n' > "$FIXTURE/release/WindowLayout.dmg"
    cp "$FIXTURE/release/WindowLayout.dmg" "$FIXTURE/original-dmg" || return 1
    local tool
    for tool in xcrun swiftc lipo codesign hdiutil gh git; do
        cat > "$FIXTURE/bin/$tool" <<'EOF'
#!/bin/bash
printf '%s\n' "$0" >> "$RELEASE_TEST_TOOL_LOG"
exit 97
EOF
        chmod +x "$FIXTURE/bin/$tool" || return 1
    done
    CLI_OUTPUT="$FIXTURE/output"
}

execute_cli() {
    if PATH="$FIXTURE/bin:$PATH" RELEASE_TEST_TOOL_LOG="$FIXTURE/tool-calls" \
        /bin/bash "$FIXTURE/make_release.sh" "$@" > "$CLI_OUTPUT" 2>&1; then
        CLI_STATUS=0
    else
        CLI_STATUS=$?
    fi
}

assert_untouched() {
    [ ! -e "$FIXTURE/tool-calls" ] || fail "Planning invoked a build/publication tool" || return 1
    cmp -s "$FIXTURE/original-dmg" "$FIXTURE/release/WindowLayout.dmg" \
        || fail "Planning changed an existing release asset" || return 1
    cmp -s "$FIXTURE/original-cask" "$CASK" \
        || fail "Planning changed the stable cask" || return 1
}

reject_cli() {
    make_fixture || return 1
    execute_cli "$@"
    [ "$CLI_STATUS" -ne 0 ] || fail "Expected invalid arguments to fail: $*" || return 1
    assert_untouched
}

plan_release() {
    local tag="$1"
    shift
    make_fixture || return 1
    execute_cli --tag "$tag" --dry-run "$@"
    [ "$CLI_STATUS" -eq 0 ] || { cat "$CLI_OUTPUT" >&2; fail "Dry-run failed"; return 1; }
    assert_untouched || return 1
    local command
    command=$(grep 'gh release create' "$CLI_OUTPUT") || fail "No release command in plan" || return 1
    case "$command" in
        *"$tag"*) ;;
        *) fail "Release plan lost its explicit tag"; return 1 ;;
    esac
    case "$tag" in
        *-*)
            [[ "$command" == *--prerelease* && "$command" == *--latest=false* ]] \
                || fail "Prerelease flags missing" || return 1
            ;;
        *)
            [[ "$command" != *--prerelease* ]] || fail "Stable release marked prerelease" || return 1
            ;;
    esac
}

missing_cask() {
    make_fixture || return 1
    rm "$CASK" || return 1
    execute_cli --tag v1.1.3 --update-cask --dry-run
    [ "$CLI_STATUS" -ne 0 ] || fail "Missing opt-in cask was accepted" || return 1
    [ ! -e "$CASK" ] && [ ! -e "$FIXTURE/tool-calls" ] \
        && cmp -s "$FIXTURE/original-dmg" "$FIXTURE/release/WindowLayout.dmg" \
        || fail "Missing-cask validation had side effects"
}

plan_without_cask() {
    make_fixture || return 1
    mv "$CASK" "$FIXTURE/saved-cask" || return 1
    execute_cli --tag v1.1.3-rc.2 --dry-run
    [ "$CLI_STATUS" -eq 0 ] && [ ! -e "$CASK" ] && [ ! -e "$FIXTURE/tool-calls" ] \
        && cmp -s "$FIXTURE/original-dmg" "$FIXTURE/release/WindowLayout.dmg" \
        && cmp -s "$FIXTURE/original-cask" "$FIXTURE/saved-cask" \
        || fail "RC planning without a cask failed or changed files" || return 1
    grep -F 'gh release create "v1.1.3-rc.2"' "$CLI_OUTPUT" \
        | grep -F -- '--prerelease --latest=false' >/dev/null \
        || fail "No complete prerelease command without a tap checkout"
}

helper_skips_cask() {
    make_fixture || return 1
    source "$FIXTURE/scripts/release_policy.sh" || return 1
    configure_release "$1" 1.1.3 0 || return 1
    update_release_cask "$CASK" "$NEW_SHA" || return 1
    [ "$CASK_BUMPED" = 0 ] && cmp -s "$FIXTURE/original-cask" "$CASK" \
        || fail "Non-opt-in release changed the cask"
}

helper_rejects_prerelease_opt_in() {
    make_fixture || return 1
    source "$FIXTURE/scripts/release_policy.sh" || return 1
    if configure_release v1.1.3-rc.2 1.1.3 1; then
        fail "Helper allowed prerelease stable-cask opt-in"; return 1
    fi
    cmp -s "$FIXTURE/original-cask" "$CASK" || fail "Rejected configuration changed the cask"
}

helper_stable_update() {
    make_fixture || return 1
    source "$FIXTURE/scripts/release_policy.sh" || return 1
    configure_release v1.1.3 1.1.3 1 || return 1
    update_release_cask "$CASK" "$NEW_SHA" || return 1
    [ "$CASK_BUMPED" = 1 ] || fail "Stable opt-in did not report an update" || return 1
    write_cask "$FIXTURE/expected-cask" 1.1.3 || return 1
    sed "s/$OLD_SHA/$NEW_SHA/" "$FIXTURE/expected-cask" > "$FIXTURE/expected-updated-cask" || return 1
    cmp -s "$FIXTURE/expected-updated-cask" "$CASK" \
        || fail "Stable update changed unexpected content or omitted version/SHA"
}

helper_same_version() {
    make_fixture || return 1
    write_cask "$CASK" 1.1.3 || return 1
    cp "$CASK" "$FIXTURE/same-version-cask" || return 1
    source "$FIXTURE/scripts/release_policy.sh" || return 1
    configure_release v1.1.3 1.1.3 1 || return 1
    update_release_cask "$CASK" "$NEW_SHA" || return 1
    [ "$CASK_BUMPED" = 0 ] && cmp -s "$FIXTURE/same-version-cask" "$CASK" \
        || fail "Same-version rebuild replaced the published cask SHA"
}

helper_write_failure() {
    make_fixture || return 1
    source "$FIXTURE/scripts/release_policy.sh" || return 1
    configure_release v1.1.3 1.1.3 1 || return 1
    cat > "$FIXTURE/bin/sed" <<'EOF'
#!/bin/bash
if [ "$1" = -i ]; then exit 96; fi
exec /usr/bin/sed "$@"
EOF
    chmod +x "$FIXTURE/bin/sed" || return 1
    if PATH="$FIXTURE/bin:$PATH" update_release_cask "$CASK" "$NEW_SHA"; then
        fail "Cask write failure reported success"; return 1
    fi
    [ "$CASK_BUMPED" = 0 ] && cmp -s "$FIXTURE/original-cask" "$CASK" \
        || fail "Failed write reported an update or changed the cask"
}

helper_invalid_sha() {
    make_fixture || return 1
    case "$1" in
        missing) sed '/sha256/d' "$CASK" > "$FIXTURE/invalid-cask" || return 1 ;;
        duplicate) awk '/sha256/ { print } { print }' "$CASK" > "$FIXTURE/invalid-cask" || return 1 ;;
    esac
    cp "$FIXTURE/invalid-cask" "$CASK" || return 1
    source "$FIXTURE/scripts/release_policy.sh" || return 1
    configure_release v1.1.3 1.1.3 1 || return 1
    if update_release_cask "$CASK" "$NEW_SHA"; then
        fail "Cask with $1 SHA field was accepted"; return 1
    fi
    [ "$CASK_BUMPED" = 0 ] && cmp -s "$FIXTURE/invalid-cask" "$CASK" \
        || fail "Invalid cask was changed"
}

test_case() {
    local name="$1"
    shift
    if ( "$@" ); then
        PASSED=$((PASSED + 1))
        printf 'PASS %s\n' "$name"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL %s\n' "$name" >&2
    fi
}

test_case "tag is required" reject_cli --dry-run
test_case "tag value is required" reject_cli --tag --dry-run
test_case "tag requires v prefix" reject_cli --tag 1.1.3-rc.2 --dry-run
test_case "malformed tag rejected" reject_cli --tag 'v1.1.3;invalid' --dry-run
test_case "leading-zero numeric prerelease identifier rejected" reject_cli --tag v1.1.3-rc.02 --dry-run
test_case "mismatched numeric bundle version rejected" reject_cli --tag v1.1.4-rc.2 --dry-run
test_case "unknown options rejected" reject_cli --tag v1.1.3 --unknown --dry-run
test_case "prerelease plan preserves tag and leaves stable cask untouched" plan_release v1.1.3-rc.2
test_case "prerelease stable-cask opt-in rejected before work" reject_cli --tag v1.1.3-rc.2 --update-cask --dry-run
test_case "stable plan requires no cask mutation by default" plan_release v1.1.3
test_case "stable opt-in dry-run still leaves files untouched" plan_release v1.1.3 --update-cask
test_case "stable opt-in requires an existing cask" missing_cask
test_case "prerelease plan works without a local cask" plan_without_cask
test_case "helper leaves prerelease cask untouched" helper_skips_cask v1.1.3-rc.2
test_case "helper leaves stable cask untouched without opt-in" helper_skips_cask v1.1.3
test_case "helper rejects prerelease stable-cask opt-in" helper_rejects_prerelease_opt_in
test_case "stable opt-in updates only cask version and SHA" helper_stable_update
test_case "same-version rebuild preserves existing cask SHA" helper_same_version
test_case "cask write failure does not report success" helper_write_failure
test_case "missing cask SHA rejected before mutation" helper_invalid_sha missing
test_case "duplicate cask SHA rejected before mutation" helper_invalid_sha duplicate

printf '\nRelease tooling: %s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
