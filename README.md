# WindowLayout

> Save and restore macOS window arrangements when you (dis)connect external displays.

[![CI](https://github.com/sylpht/WindowLayout/actions/workflows/ci.yml/badge.svg)](https://github.com/sylpht/WindowLayout/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)](#)

macOS has never remembered where your windows were when you reconnect your monitor.
WindowLayout fixes this in the menu bar — pure AppKit, universal binary, no Electron.

<!-- Replace with a real screenshot: -->
<!-- ![Screenshot](docs/screenshot.png) -->

## Features

- **Save and restore** window positions with one click
- **Auto-restore** when the same monitors reconnect
- **Multiple named layouts** per display setup — "Work", "Focus", "Weekend"
- **Launch at Login** — runs silently in the menu bar
- **Localized** — English, Русский, 中文 (with live switcher)
- **Native** — AppKit, no frameworks bundled, universal arm64+x86_64
- **iCloud sync** — saved layouts follow you across all your Macs (no Developer Program needed)
- **Stage Manager aware** — auto-restore pauses gracefully when Stage Manager is on
- **Smart** — skips fullscreen/minimized windows, handles display reshuffling

## Install

WindowLayout is signed but not notarised (no $99/yr Apple Developer Program).
Pick whichever install path you're comfortable with — they're listed from
zero-friction to most-friction.

### 1. Homebrew — recommended

```bash
brew install --cask sylpht/tap/windowlayout
```

Updates are one command: `brew upgrade --cask windowlayout`.

> **macOS 15 Sequoia note**: even after brew strips the quarantine attribute,
> Sequoia tightened the rules for apps that use the Accessibility API. On first
> launch you'll see "Apple could not verify WindowLayout is free of malware".
> Click **Done**, then go to **System Settings → Privacy & Security**, scroll
> to the bottom, and click **"Open Anyway"** next to WindowLayout. After that
> macOS remembers your choice and the app launches normally.
>
> Or skip the dialog with one Terminal command:
> ```bash
> sudo spctl --add /Applications/WindowLayout.app
> ```

### 2. Build from source — also zero warnings

```bash
git clone https://github.com/sylpht/WindowLayout.git
cd WindowLayout
./build.sh
```

Takes ~30 seconds. Requires macOS 13+ and Xcode Command Line Tools
(`xcode-select --install`). Locally built apps have no quarantine attribute
to begin with, so Gatekeeper doesn't bother them.

### 3. Direct DMG download

Download the [latest release](../../releases). On first launch:

- **Right-click** WindowLayout in Applications → **Open** → click "Open" in the dialog.

Or, in Terminal once:

```bash
xattr -dr com.apple.quarantine /Applications/WindowLayout.app
```

After the first launch, double-click works normally.

## Usage

1. Arrange your windows however you like them
2. Menu bar icon → **Save New Layout…**, give it a name
3. Disconnect your monitor, reconnect later → windows snap back

Keyboard hints inside the menu:
- Hold **⌥** → each layout row becomes a delete action
- Hold **⌘** → each layout row becomes a rename action

## Why?

Windows has had this natively since Windows 11. macOS still cannot remember window
positions across monitor disconnects (verified through Ventura, Sonoma, Sequoia).
840+ "me too" clicks on [one Apple Community thread](https://discussions.apple.com/thread/253718328)
agree. This is the fix.

## Development

### Build
```bash
./build.sh       # compile, sign, install to /Applications
```

### Tests
```bash
./run_tests.sh   # 33 unit + integration tests, no XCTest dependency
```

### Project structure
```
WindowLayout/             Source files
  ├ main.swift            Entry point
  ├ AppDelegate.swift     Lifecycle + monitor observer
  ├ StatusBarController   Menu bar menu
  ├ OnboardingWindowCtrl  First-run welcome
  ├ LayoutManager         Save / restore / persist
  ├ DisplayProfile        Monitor fingerprinting
  ├ WindowSnapshot        Data models
  ├ Geometry              Pure math (testable)
  └ Localization          EN / RU / ZH strings
Tests/                    Unit tests
build.sh                  Build + sign + install
run_tests.sh              Compile + run tests
```

### Code signing

The build script signs with an Apple Development certificate so that Accessibility
permission survives rebuilds. For your own setup, replace the `IDENTITY` variable
in `build.sh` with your own developer cert, or use `-` for ad-hoc signing
(permission will reset every build).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Small PRs welcome — bug fixes, new
translations, reliability improvements.

## License

MIT — see [LICENSE](LICENSE).
