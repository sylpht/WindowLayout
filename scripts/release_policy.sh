#!/bin/bash
# Shared by the release builder and its offline regression tests.

configure_release() {
    local tag="$1" bundle="$2" update_cask="$3"
    local number='(0|[1-9][0-9]*)'
    local identifier="($number|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    local pattern="^v$number\\.$number\\.$number(-$identifier(\\.$identifier)*)?$"
    if [[ ! "$tag" =~ $pattern ]]; then
        echo "Error: --tag must be explicit, e.g. v1.1.3-rc.2 or v1.1.3." >&2
        return 1
    fi
    RELEASE_TAG="$tag"
    RELEASE_VERSION="${tag#v}"
    BUNDLE_VERSION="$bundle"
    if [ "${RELEASE_VERSION%%-*}" != "$BUNDLE_VERSION" ]; then
        echo "Error: tag $tag does not match bundle version $BUNDLE_VERSION." >&2
        return 1
    fi
    IS_PRERELEASE=0
    case "$RELEASE_VERSION" in *-*) IS_PRERELEASE=1 ;; esac
    UPDATE_CASK="$update_cask"
    if [ "$IS_PRERELEASE" = 1 ] && [ "$UPDATE_CASK" = 1 ]; then
        echo "Error: prereleases cannot update the stable Homebrew cask." >&2
        return 1
    fi
}

print_release_command() {
    local dmg="$1"
    printf '  gh release create "%s" "%s" --verify-tag --title "%s" --notes-file release-notes.md' \
        "$RELEASE_TAG" "$dmg" "$RELEASE_TAG"
    if [ "$IS_PRERELEASE" = 1 ]; then
        printf ' --prerelease --latest=false'
    fi
    printf '\n'
}

update_release_cask() {
    local cask="$1" sha="$2" current_version current_sha
    CASK_BUMPED=0
    # Keep this guard here as well as at argument validation, so the mutating
    # operation cannot accidentally promote an RC when reused by other scripts.
    if [ "$IS_PRERELEASE" = 1 ] || [ "$UPDATE_CASK" != 1 ]; then
        echo "▶ Stable Homebrew cask unchanged (no stable --update-cask request)."
        return 0
    fi
    if [ ! -f "$cask" ]; then
        echo "Error: cask not found: $cask" >&2
        return 1
    fi
    current_version=$(sed -nE 's/^[[:space:]]*version[[:space:]]+"([^"]+)".*/\1/p' "$cask")
    if [ -z "$current_version" ] || [[ "$current_version" == *$'\n'* ]]; then
        echo "Error: expected one version field in $cask." >&2
        return 1
    fi
    current_sha=$(sed -nE 's/^[[:space:]]*sha256[[:space:]]+"([^"]+)".*/\1/p' "$cask")
    if [ -z "$current_sha" ] || [[ "$current_sha" == *$'\n'* ]]; then
        echo "Error: expected one quoted sha256 field in $cask." >&2
        return 1
    fi
    if [ "$current_version" = "$RELEASE_VERSION" ]; then
        echo "▶ Cask version unchanged ($RELEASE_VERSION); preserving its published SHA."
        return 0
    fi
    sed -i '' -E \
        -e "s/^([[:space:]]*)sha256[[:space:]]+\"[^\"]*\"/\\1sha256 \"$sha\"/" \
        -e "s/^([[:space:]]*)version[[:space:]]+\"[^\"]*\"/\\1version \"$RELEASE_VERSION\"/" \
        "$cask" || return 1
    CASK_BUMPED=1
    echo "▶ Updated $cask: $current_version → $RELEASE_VERSION (SHA $sha)"
}
