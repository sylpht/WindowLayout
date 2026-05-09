# Release procedure

How to ship a new version of WindowLayout. Sequential, ~10 minutes.

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
   - If the icon flashed but nothing moved → AX permission issue
     (this is expected after `brew upgrade`; re-grant in System Settings).
6. Open a document in TextEdit with a long filename
   (`This_is_a_very_long_filename_test_for_window_titles.txt`),
   save another layout, restore it. **TextEdit window must move too** —
   regression guard for the title-truncation bug from v1.0 ↔ v1.1.

If any of those fail, fix before tagging.

---

## 1. Bump version

```bash
plutil -replace CFBundleShortVersionString -string "1.1.2" WindowLayout/Info.plist
plutil -replace CFBundleVersion -string "4" WindowLayout/Info.plist
```

Edit `CHANGELOG.md`: rename `## [Unreleased]` → `## [1.1.2] — YYYY-MM-DD`,
add a new empty `## [Unreleased]` section above it.

## 2. Tests + release build

```bash
./run_tests.sh         # must show "X passed, 0 failed"
./make_release.sh      # auto-bumps cask SHA + version since version changed
```

`make_release.sh` will tell you the new SHA was written into
`homebrew-tap/Casks/windowlayout.rb` and remind you to upload + push.

## 3. Commit, tag, push

```bash
git add WindowLayout/Info.plist CHANGELOG.md
git commit -m "Release v1.1.2"
git tag v1.1.2
git push && git push --tags
```

## 4. GitHub Release

```bash
gh release create v1.1.2 release/WindowLayout.dmg \
  --title "v1.1.2" \
  --notes "$(awk '/^## \[1\.1\.2\]/{flag=1;next} /^## \[/{flag=0} flag' CHANGELOG.md)"
```

**Order matters:** the GitHub Release must exist BEFORE the tap is updated,
otherwise `brew install` will 404.

## 5. Push the Homebrew tap

```bash
cd homebrew-tap
git add Casks/windowlayout.rb
git commit -m "Bump windowlayout to v1.1.2"
git push
```

## 6. Post-release sanity check

```bash
brew update
brew info --cask sylpht/tap/windowlayout    # version should match
curl -sIL "https://github.com/sylpht/WindowLayout/releases/download/v1.1.2/WindowLayout.dmg" | head -2
# Expected: HTTP/2 302 → HTTP/2 200
```

## After-shipping

- Reset `defaults write com.windowlayout.app hasLaunched -bool true`
  if you opened the welcome window during testing
- Watch GitHub Issues for early adopters' bug reports for ~48 hours
- If a critical regression slips through → bump patch (1.1.2 → 1.1.3)
  and re-run from step 1, no shame
