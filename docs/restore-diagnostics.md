# Diagnose a restore failure

Diagnostics were introduced in `v1.1.3-rc.1` for [issue #2](https://github.com/sylpht/WindowLayout/issues/2).
The diagnostic build does not yet fix Space assignment, startup/wake triggering, display index mapping,
or the AX/AppKit coordinate mismatch. Candidate `v1.1.3-rc.2` uses
app bundle version 1.1.3, build 6, and corrects the missing-read counter.

## Controlled reproduction

1. Back up `~/Library/Application Support/WindowLayout/profiles.json` and keep the
   original layout. Check Accessibility permission for the build you are running;
   replacing an ad-hoc-signed build may require granting it again.
2. With Stage Manager off, use one ordinary, unminimized window from a different
   app on each physical display. Keep window titles unchanged. For this first
   experiment, keep the windows on the currently active desktops.
3. Save a separate `issue-2-control` layout. Check that the saved window count
   matches the number of test windows. Move them and select that layout manually.
4. If manual restore works, test app restart with displays already attached,
   then sleep/wake and display reconnect separately. After each automatic failure,
   wait for displays and apps to settle and try the same manual restore.
5. Repeat with multiple Spaces only after the physical-display test. Record
   timestamps, affected apps, primary display and vertical alignment, connection/dock
   details, and the “Displays have separate Spaces” setting.

WindowLayout only operates on existing AX windows; it does not reopen closed
documents or store or restore Space membership. A profile containing two window
records cannot restore an entire workspace with more windows. This does not
establish why capture included only two records: apps, exclusions, window states
and Accessibility availability need to be checked.

## Read the log

The file is `~/Library/Logs/WindowLayout/WindowLayout.log` (with one rotated `.log.1`).

| Field/message | Meaning |
|---|---|
| `autoRestore using … (N windows)` | A profile with N saved records was selected; no movement has been verified yet |
| `captureWindows` | Counts of available, skipped and captured windows, with captured counts by app |
| `capture screens` / `apply screens` | Screen array order, hardware identity and AppKit frames |
| `Auto-restore attempt` | Planned delay and actual elapsed wall-clock time for each of the three existing retries |
| `notRunning`, `notRegular`, `excluded`, `axWindowsUnavailable` | Why saved records for an app were not processed |
| `titleMismatch` | No remaining snapshot matched the live title; this can also reflect a failed AXTitle read |
| `unconsumedSaved` | Saved records not matched to a live window across all running processes with this bundle ID; a matched record stays consumed even if placement or an AX write subsequently fails |
| `sizeAX`, `positionAX` | AX write return codes; zero means the request returned success, not that the target was reached |
| `immediateChanged` | Frame changed by more than one point between reads immediately before/after the writes; unknown if either read is missing |
| `immediateTargetMatch` | Immediate frame readback matches the requested target within one point; unknown if unavailable |
| `immediateReadbackMissing` | Number of attempted windows with a missing before or after frame read; a window missing both counts once |

An observed change can be partial or off target. An unchanged immediate readback
can precede a delayed move. Observe the final window positions as well as the log.
The added reads and logs can affect timing, so this build is intended for diagnosis.
The existing three restore attempts at 2.5, 6 and 14 seconds are intentional.

`apply app=… scope=bundle` summaries combine all running processes of one app;
`saved` is counted once, `processes` counts inspected processes, and
`axWindowFailures` counts processes whose windows could not be enumerated.
Per-window lines still include the PID. A saved record is consumed at most once
per restore, including when several processes share a bundle ID.

The new messages omit window titles and document paths. Existing profile-name
messages remain, and display identities and app bundle IDs are included. Before
sharing a log or a **copy** of the profile JSON, redact private names and titles;
preserve geometry, screen indices and signatures, and note whether titles were
blank or changed. Do not edit the working profile as part of redaction.

## Validation scope

The Swift tests cover storage, sync, geometry helpers and interpretation of
restore outcomes; shell tests check release policy without publishing. A universal
app is compiled for arm64 and x86_64. These checks
do not reproduce a multi-display sleep/wake failure or prove successful live AX
restoration. Keep issue #2 open until results on the affected configuration confirm
the relevant fixes.
