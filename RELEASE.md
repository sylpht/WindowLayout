# Release procedure

How to ship a new version of WindowLayout. The numeric app bundle version and
the GitHub release tag are separate: app `1.1.3`, build `7` can be distributed as
`v1.1.3-rc.3`. The builder requires an explicit `--tag`; it never infers a stable
release from `Info.plist`.

`v1.1.3-rc.1` and `v1.1.3-rc.2` are already published. Use a new tag and build number for their
successor; do not replace existing tags or release assets.

## 0. Pre-flight: 30-second manual smoke test

Unit tests cover sync, JSON, geometry, naming. They do **not** cover the
core feature — actually moving windows. AX permission and runtime windows
make that untestable in unit tests, so a quick human pass before each
release catches what CI cannot.

**Run before every release:**

1. Open three apps you don't normally use that way: e.g. **Safari**,
   **Notes**, **Calendar**. Arrange them as three non-overlapping
   windows on whichever monitor.
2. Click the WindowLayout menu bar icon → **Save New Layout…** → name it `smoke`.
3. Drag each window to a new corner — anywhere different.
4. Menu bar → click `smoke` row to restore.
5. **Verify all three windows snapped back** to your saved positions.
   - If any window stayed put → restore is broken.
   - If you see an alert about empty layouts → save is broken.
   - If the icon flashed but placement is wrong → inspect the AX/readback
     diagnostics and Accessibility permission; a resize or later rearrangement
     does not prove the requested position persisted.
6. Open a document in TextEdit with a long filename
   (`This_is_a_very_long_filename_test_for_window_titles.txt`),
   save another layout, restore it. **TextEdit window must move too** —
   regression guard for the title-truncation bug from v1.0 ↔ v1.1.

For a stable release, fix any failure before tagging. If a diagnostic prerelease
is needed to investigate a setup you cannot reproduce, explicitly list the
unperformed live checks and unresolved issues in its release notes. Passing unit
tests or CI is not a substitute for confirming live restoration.

---

## 1. Set bundle version and choose the release tag

```bash
plutil -replace CFBundleShortVersionString -string "1.1.3" WindowLayout/Info.plist
plutil -replace CFBundleVersion -string "7" WindowLayout/Info.plist
```

Choose a tag such as `v1.1.3-rc.3` for the next candidate. Its numeric part must
match `CFBundleShortVersionString`. Increment `CFBundleVersion` for every new
distributed build, even when its numeric version is unchanged. The examples
below prepare that candidate, not a stable `v1.1.3`.

Before publishing, date the matching `CHANGELOG.md` entry and prepare
`release-notes.md` with the changes, validation and unresolved limitations.

## 2. Tests + release build

```bash
./run_tests.sh
./make_release.sh --tag v1.1.3-rc.3 --dry-run
./make_release.sh --tag v1.1.3-rc.3
(cd release && shasum -a 256 WindowLayout.dmg > SHA256SUMS)
(cd release && shasum -a 256 -c SHA256SUMS)
```

The dry run validates the tag and prints the same publish command as the build,
without invoking the SDK/build tools or changing files. A prerelease never edits
`homebrew-tap/Casks/windowlayout.rb`; requesting `--update-cask` for it is an error.

For an intentionally stable release use `--tag v1.1.3`. Cask changes remain
disabled unless `--update-cask` is also supplied and a local tap checkout exists.
Rebuilding a version already in the cask preserves its published checksum.

Verify the resulting DMG with `hdiutil verify release/WindowLayout.dmg`. Mount it
read-only and check the enclosed app's strict signature, bundle/build versions
and both architectures. The build script does not install or launch the app.

## 3. Commit, tag, push

```bash
git add WindowLayout/Info.plist CHANGELOG.md release-notes.md
git commit -m "Prepare v1.1.3-rc.3"
```

Push the change through a pull request. Wait for CI **and the repository's code
review** to finish before merging. Then tag the exact merged, tested source
commit; verify that the packaged app was built from the same source tree.

```bash
git tag -a v1.1.3-rc.3 -m "WindowLayout v1.1.3-rc.3" <tested-commit-sha>
git push origin v1.1.3-rc.3
```

## 4. GitHub Release

```bash
gh release create v1.1.3-rc.3 release/WindowLayout.dmg release/SHA256SUMS \
  --verify-tag --prerelease --latest=false \
  --title "v1.1.3-rc.3" --notes-file release-notes.md
```

The builder prints the base publish command using the complete supplied tag even
if no Homebrew checkout exists. Include the checksum asset as shown above. For a
stable tag the builder omits the prerelease flags.

## 5. Stable releases only: publish the Homebrew update

Skip this entire step for RCs. For a tested stable release, build with
`./make_release.sh --tag v1.1.3 --update-cask`, publish that exact DMG under the
stable tag first, then review and push the generated cask diff.

**Order matters:** the stable GitHub release and asset must exist before the tap
update is pushed, otherwise `brew install` will fail. Do not rebuild or change
the checksum after publishing an asset under that version.

```bash
cd homebrew-tap
git add Casks/windowlayout.rb
git commit -m "Bump windowlayout to v1.1.3"
git push
```

## 6. Post-release sanity check

```bash
gh release view v1.1.3-rc.3 --json isDraft,isPrerelease,tagName,assets
RC_CHECK_DIR=$(mktemp -d /tmp/WindowLayout-rc-check.XXXXXX)
curl -fL --output "$RC_CHECK_DIR/WindowLayout.dmg" \
  https://github.com/sylpht/WindowLayout/releases/download/v1.1.3-rc.3/WindowLayout.dmg
curl -fL --output "$RC_CHECK_DIR/SHA256SUMS" \
  https://github.com/sylpht/WindowLayout/releases/download/v1.1.3-rc.3/SHA256SUMS
(cd "$RC_CHECK_DIR" && shasum -a 256 -c SHA256SUMS)
cmp release/WindowLayout.dmg "$RC_CHECK_DIR/WindowLayout.dmg"
```

Checksums must match. An RC must show `isPrerelease: true`; the latest stable
release and the stable Homebrew cask should remain unchanged. For a stable
release, additionally run `brew update` and inspect `brew info --cask sylpht/tap/windowlayout`.

## After-shipping

- Reset `defaults write com.windowlayout.app hasLaunched -bool true`
  if you opened the welcome window during testing
- Watch GitHub Issues for early adopters' bug reports for ~48 hours
- If a regression slips through, prepare a new version/tag and build number;
  do not overwrite the old release.
