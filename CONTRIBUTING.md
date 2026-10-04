# Contributing

Thanks for your interest! Small, focused PRs are the easiest to merge.

## Getting started

```bash
git clone https://github.com/sylpht/WindowLayout.git
cd WindowLayout
./build.sh       # builds (universal arm64+x86_64), signs, installs to /Applications
./build.sh --no-install  # build/sign only; do not stop, install or launch the app
./make_dmg.sh    # package the current signed dev app; build it with --no-install if absent
./run_tests.sh   # application, storage, sync and packaging regressions
```

Requirements: macOS 13+, Xcode Command Line Tools.

## Cutting a release (notarised .dmg)

`build.sh` uses `WL_SIGN_IDENTITY` from the environment first, then
`.signing.local`, and otherwise ad-hoc signing (`-`). It builds in a unique
temporary directory, enables Hardened Runtime, and adds a secure timestamp for
certificate-based signatures. The resulting `WindowLayout.app` retains that
signature. `make_dmg.sh` packages this app without re-signing it and verifies the
copy inside the DMG. Rebuild explicitly after source changes; an existing app is
not automatically rebuilt by the packager.

An ad-hoc or Apple Development signature is not a substitute for notarization.
For outside-App-Store distribution under normal Gatekeeper policy, use a
**Developer ID Application** certificate and Apple's notarization service.
This requires the appropriate Apple Developer Program credentials and network
access. See Apple's [notarization requirements](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
and [custom workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

```bash
# 1. Store notarization credentials interactively in Keychain; do not commit secrets.
xcrun notarytool store-credentials WL-NOTARY

# 2. Build and package without changing the running/installed app.
WL_DISTRIBUTION_IDENTITY="Developer ID Application: Your Name (TEAMID)"
WL_SIGN_IDENTITY="$WL_DISTRIBUTION_IDENTITY" ./build.sh --no-install
./make_dmg.sh

# 3. Sign the container and submit the exact DMG.
codesign --force --sign "$WL_DISTRIBUTION_IDENTITY" --timestamp WindowLayout.dmg
codesign --verify --verbose=2 WindowLayout.dmg
xcrun notarytool submit WindowLayout.dmg --keychain-profile WL-NOTARY --wait
```

Continue only when the submission reports **Accepted**. For a rejection, inspect
its log with `xcrun notarytool log <submission-id> --keychain-profile WL-NOTARY`.

```bash
# 4. Attach and validate the notarization ticket.
xcrun stapler staple WindowLayout.dmg
xcrun stapler validate WindowLayout.dmg
hdiutil verify WindowLayout.dmg
shasum -a 256 WindowLayout.dmg
```

Test the final downloaded artifact on a separate Mac or test account before
publishing it. Compute distribution checksums after stapling; do not rebuild or
replace the DMG under an existing release. The separate `make_release.sh --tag …`
flow produces an **ad-hoc-signed, unnotarized** test release and does not guarantee
Gatekeeper acceptance. The exact warning depends on macOS and the download path.

## Ground rules

1. **One feature or fix per PR.** Split cleanup and features into separate PRs.
2. **Tests must pass.** `./run_tests.sh` should exit 0.
3. **No new runtime dependencies.** The app should stay small (universal binary
   ~1 MB; no third-party frameworks bundled).
4. **Localize user-facing strings.** Any new `L.s()` call needs Russian and Chinese
   arguments. See `WindowLayout/Localization.swift`.
5. **No comments for obvious code.** Only add comments when a reader would otherwise
   be confused about *why* something is written a certain way.

## Code style

- Follow the existing style — 4-space indent, Swift-standard naming
- Prefer AppKit over SwiftUI for menu-bar UI (smaller binary, finer control)
- Use SF Symbols for icons via `NSImage(systemSymbolName:)`
- Keep files under ~300 lines; split if growing

## Adding a new language

1. In `Localization.swift`, extend `Lang` enum
2. Add branches in `timeAgo`, `layoutsCount`, `displaysCount`
3. Grep for `L.s(` and add the new argument everywhere
4. Add a plural test to `Tests/main.swift`

## Reporting bugs

Open an issue via the template. Include:

- macOS version (e.g., 14.4)
- Monitor configuration (built-in + 1 external? DisplayPort / HDMI / Thunderbolt?)
- Steps to reproduce, expected vs actual behavior
- If relevant: contents of `~/Library/Application Support/WindowLayout/profiles.json`

## License

By contributing, you agree that your contributions will be licensed under the MIT
license (see [LICENSE](LICENSE)).
