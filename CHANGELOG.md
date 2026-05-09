# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `flashIconSuccess` race — rapid back-to-back flashes (save+restore in <0.7s)
  could leave the menu bar icon stuck on the checkmark; now uses a generation
  counter so only the latest scheduled revert fires
- `revealSyncFolder` silently failed when the iCloud folder didn't exist
  (sync just disabled / folder manually deleted) — now creates on demand so
  Finder always opens
- Menu-click save / restore now flash the icon for visual feedback (was
  inconsistent with the hotkey path which already did)
- `saveCurrentLayout` refuses to save layouts with zero captured windows
  (AX denied or all apps excluded) — surfaces a clear alert instead of
  silently creating a non-restorable profile
- Hotkey ⌘⇧⌥S no longer flashes "success" on empty capture
- AutoRestore now triggers on display **signature** change, not just count
  change — hot-swapping one external monitor for another (count unchanged)
  was previously missed
- iCloud file deleted externally (Finder / another Mac) now triggers a
  re-push of local state instead of leaving other Macs stranded with empty data
- `make_release.sh` no longer corrupts the homebrew cask SHA on dev rebuilds —
  the cask only updates when CFBundleShortVersionString actually bumps
- CI workflow: macos-15 runner + match release signing (Hardened Runtime
  + entitlements + strict verify) so signing regressions surface in CI
- **Long window titles (>64 chars) now restore correctly** — earlier privacy fix
  truncated titles at save time but `apply()` compared against full live titles,
  causing silent restore failures for documents/tabs with long names
- `suggestedNameForNewLayout` is now gap-aware — deleting a middle layout (e.g.
  "Layout 2" out of [1,2,3]) no longer suggests a colliding name on next save
- `apply()` skips silently when Accessibility is denied + new
  `lastApplyMovedWindows` flag — restore paths only flash success when something
  actually moved, was previously misleading on revoked AX
- Onboarding window: `Esc` closes; observer leak fixed (each language switch
  no longer leaves a dead observer in NotificationCenter)
- `applicationWillTerminate` drains the iCloud push queue with a sync barrier —
  save → quit no longer loses the push if the closure hadn't run yet
- `captureAutoSnapshot` skips when Stage Manager is active (would have captured
  off-screen sidebar positions); manual Save warns + asks confirmation

## [1.1.0] — 2026-04-25

### Added
- **Stage Manager awareness** — auto-restore is skipped when Stage Manager is active
  (the OS would just rearrange windows on top of our restore). Menu bar shows a warning
  row when Stage Manager is on. Manual restore still works
- **More-stable display fingerprinting** — signature now includes vendor + model + serial
  per display (was just serial + model + position). Position no longer included →
  rotating monitors in System Settings doesn't orphan your layouts. Built-in displays
  (which often report all-zero IDs) get a stable `builtin:WxH` marker
- **Backward-compat profile lookup** — v1.0 layouts saved under the old signature
  format are still found via `DisplayConfiguration.matchingSignatures` (canonical + legacy)
- **iCloud sync** — your saved layouts now follow you between Macs via
  `~/Library/Mobile Documents/com~apple~CloudDocs/WindowLayout/`. No
  Apple Developer Program or entitlements required; macOS handles the
  upload. Toggle in the menu bar
- Tombstone-based delete propagation — deleting a layout on one Mac removes
  it from the other within seconds. Tombstones garbage-collected after 30 days
- Conflict resolution: same-id profiles merge by `capturedAt`; tombstones win
- Auto-snapshot before display disconnect — saves the current layout to a hidden
  backup so reconnecting restores it even if you never pressed Save
- Retry auto-restore at 2.5 s / 6 s / 14 s to catch apps that are still launching
- Global hotkeys: ⌘⇧⌥S save, ⌘⇧⌥R restore (via Carbon `RegisterEventHotKey`)
- Status bar icon flashes a checkmark after save/restore as visual confirmation
- Per-app exclusions — "Excluded Apps" submenu with toggle per running app
- File log at `~/Library/Logs/WindowLayout/WindowLayout.log` for troubleshooting
- Accessibility permission polling — menu reflects grant/revoke without restart
- Universal binary (arm64 + x86_64) — runs on both Apple Silicon and Intel
- `make_dmg.sh` — one-command `.dmg` builder with drag-to-Applications UX

### Changed
- `LayoutProfile.isAutoSnapshot` added (optional, backwards-compatible)
- `LayoutProfile.deletedAt` added for sync tombstones (optional, backwards-compatible)
- `profilesForCurrentSetup()` now hides auto-snapshots and tombstones from the UI;
  `autoRestore()` still falls back to auto-snapshots
- `deleteProfile` writes a tombstone when iCloud sync is on; hard-deletes when off

### Fixed
- Compile warning in `Log.swift` (unused `try?` result)
- `kickPush()` was pushing local state BEFORE merging remote — a fresh Mac with empty
  layouts could overwrite an iCloud file already populated by another Mac. Now pulls
  and merges first, then pushes the merged result
- Renames now propagate via iCloud — added `LayoutProfile.modifiedAt`, used as merge
  tie-break alongside `capturedAt`. Previously a rename on one Mac was lost when the
  other Mac's identical-time copy won the merge
- Tombstones (deletion markers for sync) are purged when iCloud sync is turned off,
  so they don't accumulate forever in local storage
- Race on `iCloudSync.lastSyncedAt` (written from file-coordinator queue, read from
  main thread for menu) — now guarded by `NSLock`
- Corrupt iCloud `profiles.json` now logs an explicit error instead of silently failing
- App version now sourced from `Info.plist` instead of being hardcoded to "1.0" in logs
- Window-matching collision: two windows with identical titles (e.g. two "New Tab")
  no longer both restored to the same position — each snapshot consumed at most once
- Removed random index fallback in `apply()` — windows with no title match are now
  left in place instead of being moved to a pseudo-random snapshot
- Window-to-screen assignment uses the window's center point, not the first intersecting
  screen — fixes straddling-window snapshots being assigned non-deterministically
- `Geometry.clamp` pulls off-screen / oversized restored windows back into visible bounds
- `setFrame` now sets size BEFORE position — avoids macOS clamping the position to keep
  the old (larger) size on-screen
- iCloud JSON now compact (not pretty-printed) — smaller diffs, faster sync
- `accommodatePresentedItemDeletion` implemented — external deletion of the iCloud
  file triggers a re-merge instead of being silently ignored
- `NSFileCoordinator.removeFilePresenter` called on app termination and when sync is
  disabled — no more dangling registrations in the process-wide presenter registry
- `autoRestore()` now filters out tombstones — a deleted profile would otherwise out-rank
  a real one (newer `capturedAt`) and silently make autoRestore a no-op
- Date encoding now includes fractional seconds — two renames within the same second
  no longer tie at merge time (the `>=` tie-break used to leave a permanent divergence
  between Macs). Decoder accepts both new fractional and legacy plain-second formats
- `saveToDisk()` push to iCloud now runs on a background queue — large or slow iCloud
  writes no longer freeze the menu bar UI when saving a layout
- `RegisterEventHotKey` failures (e.g. another app holds ⌘⇧⌥S) are now logged instead
  of silently dropped
- Onboarding window footer reads version from `Info.plist` (was hardcoded "v1.0")

### Fixed (runtime smoke audit)
- **Privacy: window titles truncated to 64 chars before persisting.** Window titles
  often contain confidential data (email subjects, document paths, browser tab titles,
  Slack channel names). 64 chars is enough to disambiguate sibling windows but too short
  to leak full subject lines
- **Privacy: `profiles.json` now written with mode 600** (was default 644 = world-readable).
  Other local user-level processes can no longer enumerate your window history. Applied
  in iCloud `mergeAndPush`, iCloud `push`, local `saveToDisk`, local `saveLocalOnly`
- **Log rotation** at 1 MB — keeps one `.log.1` backup, then overwrites. Previously the
  log grew unbounded
- **DoS guard**: refuses to parse iCloud files larger than 5 MB. A normal user has at
  most a few KB; a 100k-profile pathological file would consume ~16 MB RAM and ~0.5s CPU
- Verified at runtime: writing arbitrary JSON to the iCloud file triggers
  `presentedItemDidChange` → `mergeRemoteIntoLocal` → push-back when local contributed
  (the R5 fix actually fires on a real file change, not just in tests)

### Fixed (post-audit round 5)
- **Lost-update bug under concurrent two-Mac saves.** `saveToDisk()` was doing a blind
  push (write without read-merge), so if Mac A and Mac B saved different new profiles
  in the same window, whoever's push landed second in iCloud overwrote the other's
  contribution. Mac A's data survived locally on Mac A but was missing from iCloud
  (and from Mac B) until the next user-initiated save. Fix: new `iCloudSync.mergeAndPush`
  does the read-merge-write atomically inside a single `NSFileCoordinator.coordinate(writingItemAt:)`
  block — the file system serialises writes across all coordinator clients (this process,
  finderd, other Macs), guaranteeing no other writer can race against us mid-merge.
- `mergeRemoteIntoLocal()` now pushes back when local contributed items the remote
  didn't have (catches the symmetric race triggered by an external file change).
- New stress test: A and B both add a profile from a shared base concurrently — both
  profiles survive in iCloud after the dust settles (would have failed on previous build).

### Fixed (post-audit round 4)
- **Concurrent push race**: `saveToDisk()` was dispatching pushes onto the global
  `.utility` queue (concurrent), so two rapid saves could be reordered — an older
  snapshot could overwrite a newer one in iCloud. Now uses `iCloudSync.syncDispatchQueue`
  (serial), guaranteeing FIFO push order. New stress test: 20 rapid saves all land
- `kickPush()` was running NSFileCoordinator coordinated writes synchronously on the
  main thread when sync was first toggled on — could freeze the menu bar on slow iCloud.
  Now pushes async on the serial queue after the merge
- Test storage dirs (`/tmp/WindowLayoutTest-*`) are now tracked and cleaned up alongside
  the sync sandboxes — previously `tempStorageURL()` leaked one dir per test invocation

### Fixed (post-audit round 3)
- Auto-snapshot dedup: a v1.0↔v1.1 downgrade/upgrade round-trip could leave both a
  legacy- and canonical-signature auto-snapshot for the same display setup. The newer
  one now removes its sibling
- Stage Manager detection switched from `UserDefaults(suiteName:)` to
  `CFPreferencesCopyAppValue` — the suite-name approach silently returned nil on some
  macOS versions for the `com.apple.WindowManager` system pref domain
- Auto-restore menu toggle is now disabled (greyed) and shown OFF when Stage Manager
  is active — previously the toggle showed ON while a warning row beneath it said
  auto-restore was being skipped
- `matchingSignatures` now deduplicates when canonical and legacy formats are equal
- Two-Mac integration tests no longer use blind `Thread.sleep` after async pushes —
  `waitForFile` and `waitForFileMtime` poll the iCloud file with a 2s deadline,
  eliminating CI flakiness on slow runners
- Test temp folders (`WindowLayoutSync-*`) are now cleaned up at the end of the
  test run instead of accumulating in `/tmp`

### Tests
- 31 unit + integration tests (was 10 in v1.0) including:
  - Two-Mac sync simulation: push → pull, A renames → B sees, A deletes → B's tombstone, simultaneous-rename race
  - Display signature backward compat (v1.0 legacy match)
  - iCloud date encoder/decoder fractional-second round-trip + legacy parse
  - Geometry clamp for off-screen and oversized restored frames
  - Tombstone garbage collection at 30-day cutoff

## [1.0.0] — 2026-04-19

First release.

### Added
- Save and restore window layouts per display configuration
- Multiple named profiles per monitor setup
- Auto-restore when the same monitors reconnect
- Launch at Login toggle (`SMAppService`)
- Localization: English, Русский, 中文
- Live language switcher in the Welcome window and status bar menu
- Welcome window with real-time Accessibility permission status
- Custom app icon
- Stable code signing with Apple Development identity (permission persists across rebuilds)
- 10 unit tests covering plurals, Codable round-trip, geometry, persistence

### Fixed
- Skip fullscreen and minimized windows in capture/restore
- Built-in vs external display detection using `CGDisplayIsBuiltin` instead of `NSScreen` identity
- Menu refreshes when opened (relative timestamps always accurate)
