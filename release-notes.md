Diagnostic candidate for [issue #2](https://github.com/sylpht/WindowLayout/issues/2).
App version **1.1.3, build 7**. The reported failure on a MacBook with two external
monitors remains unverified; this is a prerelease for controlled testing.

### Changes since RC2

- Correct AX/AppKit coordinate conversion and identify displays by hardware serial
  or UUID in newly saved layouts. Skip missing or ambiguous targets safely.
  If a sole serial-zero model changes UUID, a logged unique-model fallback is used;
  this inference cannot distinguish replacement by another unit of the same model.
- Share saved-window matches across all processes of an app, with accurate bundle totals.
- Trigger automatic restore after launch and wake even without a display-signature change;
  cancel obsolete retries on sleep, permission loss, manual restore or disabling automatic restore.
- Let the restore hotkey follow explicit manual policy with Stage Manager, and warn
  when some target displays cannot be identified.
- Preserve profiles on storage failures, merge queued cloud writes against the
  latest replica, and retain deletion history while sync is paused.
- Verify the signed development bundle and DMG payload; allow packaging without
  installing or launching. Wait for the previous app to exit before development installation.

### Test this candidate

Back up `~/Library/Application Support/WindowLayout/profiles.json`. Confirm
Accessibility permission after installing, then **save a fresh control layout**
with one ordinary window on each connected display. First move and manually restore
those windows. If that works, enable automatic restore and test app restart,
sleep/wake and reconnect separately. Compare final positions with the logs; profile
selection or a successful AX return code alone does not prove restoration.

Legacy layouts retain their data, but lack display identity. They restore only
when their saved screen geometry still has a unique match; resave after a topology
change. Identical serial-zero displays remain ambiguous even when their connector
UUIDs differ, including in a new layout. WindowLayout does not reopen documents or restore Space membership.

See the [reproduction and log guide](https://github.com/sylpht/WindowLayout/blob/v1.1.3-rc.3/docs/restore-diagnostics.md).
Before sharing logs, redact private profile names; do not share an unredacted profile JSON.

### Validation and distribution

146 Swift checks and 46 shell regressions pass. The universal app builds for
Apple Silicon and Intel; the DMG, strict app signature and versions are checked
before upload. `SHA256SUMS` is included for download verification. **Live AX smoke tests, Stage Manager,
restart, sleep/wake and two-external-monitor reconnect have not been performed
for this build.** Issue #2 remains open until the affected configuration confirms the result.

This DMG is **ad-hoc signed and not notarized**; macOS may require approval in
Privacy & Security and a renewed Accessibility grant. It is not a stable release.
RC1/RC2 assets, the latest stable release and the Homebrew cask are unchanged.
