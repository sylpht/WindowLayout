# Contributing

Thanks for your interest! Small, focused PRs are the easiest to merge.

## Getting started

```bash
git clone https://github.com/sylpht/WindowLayout.git
cd WindowLayout
./build.sh       # builds (universal arm64+x86_64), signs, installs to /Applications
./run_tests.sh   # 33 unit + integration tests
```

Requirements: macOS 13+, Xcode Command Line Tools.

## Cutting a release (notarised .dmg)

The build script signs with `Apple Development` and enables Hardened Runtime, but
that's not enough for Gatekeeper to accept a downloaded `.dmg` — you need a paid
Apple Developer Program membership for `Developer ID Application` + `notarytool`:

```bash
# 1. One-time: store credentials in keychain
xcrun notarytool store-credentials WL-NOTARY \
    --apple-id you@example.com \
    --team-id YOUR_TEAM_ID \
    --password APP_SPECIFIC_PASSWORD

# 2. Build with your Developer ID cert
WL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
./make_dmg.sh

# 3. Submit for notarisation
xcrun notarytool submit WindowLayout.dmg --keychain-profile WL-NOTARY --wait

# 4. Staple the ticket so Gatekeeper accepts offline
xcrun stapler staple WindowLayout.dmg
```

Without notarisation, end users will see "WindowLayout is damaged" or "unidentified
developer" alerts. They can bypass with `xattr -d com.apple.quarantine WindowLayout.app`
but it's a bad UX — notarise for any public release.

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
