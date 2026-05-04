# Security Policy

## Reporting a vulnerability

If you find a security issue in WindowLayout, please **do not** open a public
GitHub issue. Instead, email the maintainer at <shtoce@icloud.com> with:

- A description of the issue
- Steps to reproduce
- The macOS version and WindowLayout version affected

You can expect an initial response within 7 days.

## What this app handles

WindowLayout reads (via macOS Accessibility API) and persists:

- Window positions and sizes per running app
- Window titles (truncated to 64 characters)
- The bundle ID of the owning app
- Display configuration (vendor / model / serial / resolution)

It does **not** collect, transmit, or use:

- Account credentials, tokens, or API keys
- Telemetry, analytics, or crash reports
- Window contents (screenshots, text within apps)
- Personal data beyond what's listed above

## Where this data lives

- `~/Library/Application Support/WindowLayout/profiles.json` — local copy, mode `600` (owner read/write only)
- `~/Library/Mobile Documents/com~apple~CloudDocs/WindowLayout/profiles.json` — iCloud copy when sync is enabled, mode `600`
- `~/Library/Logs/WindowLayout/WindowLayout.log` — info log, auto-rotated at 1 MB

When iCloud sync is on, your `profiles.json` is uploaded by macOS via your iCloud
Drive account. Apple encrypts it in transit and at rest; only Macs signed in to
the same Apple ID can read it.

## Distribution integrity

WindowLayout releases are ad-hoc signed (no Apple Developer Program). To verify
you have an unmodified release:

1. Download via Homebrew (`brew install --cask sylpht/tap/windowlayout`) — brew
   verifies the SHA256 against the cask formula automatically.
2. Or compare the SHA256 of the `.dmg` against the value in the GitHub release notes:
   ```bash
   shasum -a 256 WindowLayout.dmg
   ```

If you obtained the app from a source other than github.com/sylpht/WindowLayout
or `sylpht/tap`, **don't trust it** — re-download from the official channels.
