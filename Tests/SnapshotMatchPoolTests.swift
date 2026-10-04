import CoreGraphics
import Foundation

private func savedWindow(_ target: Int, bundleID: String = "example.app", title: String = "Untitled") -> WindowSnapshot {
    let frame = CGRect(x: target, y: 0, width: 800, height: 600)
    return WindowSnapshot(bundleID: bundleID, windowTitle: title, frame: frame,
                          normalizedFrame: frame, screenIndex: 0)
}

private func matchedTargets(_ matches: [SnapshotMatchPool.Match]) -> [Int] {
    matches.compactMap { match in
        if case .matched(let snapshot) = match { return Int(snapshot.frame.minX) }
        return nil
    }
}

func runSnapshotMatchPoolTests(_ test: (String, () -> Bool) -> Void) {
    test("Snapshot matching — duplicate titles consume distinct records across PIDs") {
        var pool = SnapshotMatchPool(snapshots: [savedWindow(10), savedWindow(20)])
        let pid101 = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Untitled")])
        let pid202 = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Untitled")])
        let pid303 = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Untitled")])
        guard pid303.count == 1, case .noRemainingSaved = pid303[0] else { return false }
        return matchedTargets(pid101) == [10] && matchedTargets(pid202) == [20]
            && pool.remainingCount(for: "example.app") == 0
    }

    test("Snapshot matching — privacy fallback is shared across PIDs") {
        var pool = SnapshotMatchPool(snapshots: [savedWindow(10, title: ""), savedWindow(20, title: "")])
        let pid101 = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "First document")])
        let pid202 = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Second document")])
        return matchedTargets(pid101) == [10] && matchedTargets(pid202) == [20]
            && pool.remainingCount(for: "example.app") == 0
    }

    test("Snapshot matching — different bundles cannot consume each other's records") {
        var pool = SnapshotMatchPool(snapshots: [savedWindow(10, bundleID: "app.a"), savedWindow(20, bundleID: "app.b")])
        let a = pool.matchProcess(bundleID: "app.a", windows: [.eligible(title: "Untitled"), .eligible(title: "Untitled")])
        guard a.count == 2, case .noRemainingSaved = a[1], pool.remainingCount(for: "app.b") == 1 else { return false }
        let b = pool.matchProcess(bundleID: "app.b", windows: [.eligible(title: "Untitled")])
        return matchedTargets(a) == [10] && matchedTargets(b) == [20]
    }

    test("Snapshot matching — exact title takes priority over an earlier empty title") {
        var pool = SnapshotMatchPool(snapshots: [savedWindow(10, title: ""), savedWindow(20, title: "Report")])
        let first = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Report")])
        let second = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Other")])
        return matchedTargets(first) == [20] && matchedTargets(second) == [10]
    }

    test("Snapshot matching — mismatches preserve records for a later process") {
        var pool = SnapshotMatchPool(snapshots: [savedWindow(10, title: "Saved document")])
        let first = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Changed document")])
        guard first.count == 1, case .titleMismatch = first[0], pool.remainingCount(for: "example.app") == 1 else { return false }
        let second = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Saved document")])
        return matchedTargets(second) == [10]
    }

    test("Snapshot matching — live titles retain the capture's 64-character truncation") {
        let prefix = String(repeating: "界", count: 64)
        var pool = SnapshotMatchPool(snapshots: [savedWindow(10, title: prefix)])
        let matches = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: prefix + " suffix")])
        return matchedTargets(matches) == [10]
    }

    test("Snapshot matching — failed AX enumeration does not consume another PID's target") {
        var pool = SnapshotMatchPool(snapshots: [savedWindow(10)])
        let failedPID = pool.matchProcess(bundleID: "example.app", windows: nil)
        guard failedPID.isEmpty, pool.remainingCount(for: "example.app") == 1 else { return false }
        let nextPID = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Untitled")])
        return matchedTargets(nextPID) == [10]
    }

    test("Snapshot matching — minimized and fullscreen windows leave records available") {
        var pool = SnapshotMatchPool(snapshots: [savedWindow(10)])
        let skipped = pool.matchProcess(bundleID: "example.app", windows: [.minimized, .fullscreen])
        guard skipped.count == 2, case .minimized = skipped[0], case .fullscreen = skipped[1],
              pool.remainingCount(for: "example.app") == 1 else { return false }
        let eligible = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Untitled")])
        return matchedTargets(eligible) == [10]
    }

    test("Snapshot matching — an empty process leaves the shared pool intact") {
        var pool = SnapshotMatchPool(snapshots: [savedWindow(10)])
        return pool.matchProcess(bundleID: "example.app", windows: []).isEmpty
            && pool.remainingCount(for: "example.app") == 1
    }

    test("Snapshot matching — a new restore starts with a fresh pool") {
        let saved = [savedWindow(10)]
        var first = SnapshotMatchPool(snapshots: saved)
        _ = first.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Untitled")])
        var second = SnapshotMatchPool(snapshots: saved)
        return first.remainingCount(for: "example.app") == 0
            && matchedTargets(second.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Untitled")])) == [10]
    }

    test("Snapshot matching — diagnostics report consumed records even when no setter ran") {
        let saved = [savedWindow(10), savedWindow(20)]
        var pool = SnapshotMatchPool(snapshots: saved)
        let matches = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Untitled")])
        guard matches.count == 1, case .matched(let matched) = matches[0] else { return false }
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let savedIdentity = DisplayIdentity(uuid: nil, vendor: 1, model: 2, serial: 1, isBuiltin: false)
        let replacementIdentity = DisplayIdentity(uuid: nil, vendor: 1, model: 2, serial: 2, isBuiltin: false)
        let profile = LayoutProfile(id: UUID(), displaySignature: "fixture", name: "Fixture",
                                    capturedAt: Date(timeIntervalSince1970: 1000), windows: saved,
                                    screenFrames: [screen], placementVersion: DisplayPlacement.currentVersion,
                                    displayIdentities: [savedIdentity])
        let current = DisplayLayout(appKitFrames: [screen], identities: [replacementIdentity])
        // The production placement helper rejects this already-consumed match before AX writes.
        guard case .failure = DisplayPlacement.target(snapshot: matched, profile: profile, current: current) else {
            return false
        }
        var counts = RestoreAppCounts(saved: 2)
        counts.processes = 1
        counts.placementUnresolved = 1
        let summary = counts.logDescription(unconsumedSaved: pool.remainingCount(for: "example.app"))
        let laterPID = pool.matchProcess(bundleID: "example.app", windows: [.eligible(title: "Untitled")])
        return summary.contains("attempted=0") && summary.contains("unconsumedSaved=1")
            && summary.contains("placementUnresolved=1")
            && matchedTargets(laterPID) == [20] && pool.remainingCount(for: "example.app") == 0
    }
}
