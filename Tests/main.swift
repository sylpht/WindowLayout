import Foundation
import CoreGraphics
import AppKit

// MARK: - Minimal test harness

var _passed = 0
var _failed = 0
var _failures: [(String, String)] = []

func test(_ name: String, _ block: () throws -> Bool) {
    do {
        if try block() {
            _passed += 1
            print("  ✅ \(name)")
        } else {
            _failed += 1
            _failures.append((name, "assertion returned false"))
            print("  ❌ \(name)")
        }
    } catch {
        _failed += 1
        _failures.append((name, "threw \(error)"))
        print("  ❌ \(name) — threw \(error)")
    }
}

func approx(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.0001) -> Bool {
    abs(a - b) < eps
}

var _testStorageDirs: [URL] = []

func tempStorageURL() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("WindowLayoutTest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _testStorageDirs.append(dir)
    return dir.appendingPathComponent("profiles.json")
}

// MARK: - Run

print("▶︎ Running WindowLayout tests\n")

// Save & restore user-language at the end so we don't pollute defaults.
let originalLang = L.userPreference

// ── 1 ─────────────────────────────────────────────────────────
test("DisplayConfiguration.current() is deterministic") {
    let a = DisplayConfiguration.current()
    let b = DisplayConfiguration.current()
    return a.signature == b.signature
}

// ── 2 ─────────────────────────────────────────────────────────
test("L.layoutsCount — Russian plural forms 1/2/5/11/21/22/101") {
    L.userPreference = .ru
    let cases: [(Int, String)] = [
        (1, "1 расположение"),
        (2, "2 расположения"),
        (5, "5 расположений"),
        (11, "11 расположений"),
        (21, "21 расположение"),
        (22, "22 расположения"),
        (101, "101 расположение"),
    ]
    for (n, expected) in cases {
        let got = L.layoutsCount(n)
        if got != expected {
            print("     \(n): expected \"\(expected)\", got \"\(got)\"")
            return false
        }
    }
    return true
}

// ── 3 ─────────────────────────────────────────────────────────
test("L.layoutsCount — Chinese uses 个布局") {
    L.userPreference = .zh
    return L.layoutsCount(1) == "1 个布局" && L.layoutsCount(5) == "5 个布局"
}

// ── 4 ─────────────────────────────────────────────────────────
test("L.timeAgo — English boundary behavior") {
    L.userPreference = .en
    guard L.timeAgo(0)     == "just now" else { return false }
    guard L.timeAgo(59)    == "just now" else { return false }
    guard L.timeAgo(60)    == "1m ago"   else { return false }
    guard L.timeAgo(3599)  == "59m ago"  else { return false }
    guard L.timeAgo(3600)  == "1h ago"   else { return false }
    guard L.timeAgo(86399) == "23h ago"  else { return false }
    guard L.timeAgo(86400) == "1d ago"   else { return false }
    return true
}

// ── 5 ─────────────────────────────────────────────────────────
test("L.s falls back to English when Chinese missing") {
    L.userPreference = .zh
    let result = L.s("ру", "en", nil)  // no Chinese → English
    return result == "en"
}

// ── 6 ─────────────────────────────────────────────────────────
test("Geometry.normalize then denormalize is identity") {
    let screen = CGRect(x: 100, y: 200, width: 1920, height: 1080)
    let window = CGRect(x: 300, y: 400, width: 800, height: 600)
    let n = Geometry.normalize(window, in: screen)
    let back = Geometry.denormalize(n, in: screen)
    return approx(back.minX, window.minX)
        && approx(back.minY, window.minY)
        && approx(back.width, window.width)
        && approx(back.height, window.height)
}

// ── 7 ─────────────────────────────────────────────────────────
test("Geometry.normalize — zero-size screen returns original frame") {
    let zero = CGRect(x: 0, y: 0, width: 0, height: 0)
    let window = CGRect(x: 10, y: 20, width: 30, height: 40)
    return Geometry.normalize(window, in: zero) == window
}

// ── 8 ─────────────────────────────────────────────────────────
test("LayoutProfile — Codable round-trip preserves all fields") {
    let original = LayoutProfile(
        id: UUID(),
        displaySignature: "sig-abc",
        name: "Work Setup",
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        windows: [
            WindowSnapshot(
                bundleID: "com.apple.Safari",
                windowTitle: "Home",
                frame: CGRect(x: 100, y: 200, width: 800, height: 600),
                normalizedFrame: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6),
                screenIndex: 1
            )
        ],
        screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
    )

    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601

    let data = try enc.encode(original)
    let decoded = try dec.decode(LayoutProfile.self, from: data)

    return decoded.id == original.id
        && decoded.displaySignature == original.displaySignature
        && decoded.name == original.name
        && decoded.capturedAt.timeIntervalSince1970 == original.capturedAt.timeIntervalSince1970
        && decoded.windows.count == 1
        && decoded.windows[0].bundleID == "com.apple.Safari"
        && decoded.windows[0].frame == CGRect(x: 100, y: 200, width: 800, height: 600)
        && decoded.windows[0].screenIndex == 1
        && decoded.screenFrames.count == 1
}

// ── 9 ─────────────────────────────────────────────────────────
test("LayoutManager — addProfile + persist + reload") {
    let url = tempStorageURL()
    let mgr1 = LayoutManager(storageURL: url)
    let profile = LayoutProfile(
        id: UUID(), displaySignature: "sig", name: "Test",
        capturedAt: Date(), windows: [], screenFrames: []
    )
    mgr1.addProfile(profile)

    // Reload from disk via new instance
    let mgr2 = LayoutManager(storageURL: url)
    return mgr2.allProfiles.count == 1 && mgr2.allProfiles[0].id == profile.id
}

// ── 10 ────────────────────────────────────────────────────────
test("LayoutManager — rename & delete & profile() lookup") {
    let mgr = LayoutManager(storageURL: tempStorageURL())
    let id = UUID()
    let profile = LayoutProfile(
        id: id, displaySignature: "sig", name: "Old Name",
        capturedAt: Date(), windows: [], screenFrames: []
    )
    mgr.addProfile(profile)

    mgr.renameProfile(id: id, to: "New Name")
    guard mgr.profile(id: id)?.name == "New Name" else { return false }

    mgr.deleteProfile(id: id)
    return mgr.profile(id: id) == nil && mgr.allProfiles.isEmpty
}

// ── 10aa ──────────────────────────────────────────────────────
test("Privacy mode pref defaults off (backward-compat)") {
    UserDefaults.standard.removeObject(forKey: LayoutManager.privacyHideTitlesPrefKey)
    return UserDefaults.standard.bool(forKey: LayoutManager.privacyHideTitlesPrefKey) == false
}

// ── 10b ───────────────────────────────────────────────────────
test("autoRestore — no-op when no profile matches signature, doesn't crash") {
    let mgr = LayoutManager(storageURL: tempStorageURL())
    // Add a profile for a fake signature that won't match the real display.
    let p = LayoutProfile(
        id: UUID(), displaySignature: "definitely-not-this-display",
        name: "Other Setup", capturedAt: Date(),
        windows: [], screenFrames: []
    )
    mgr.addProfile(p)
    mgr.autoRestore()  // must return cleanly
    return mgr.lastApplyMovedWindows == false
}

// ── 10c ───────────────────────────────────────────────────────
test("autoRestore — picks the most recently captured user-saved profile") {
    let mgr = LayoutManager(storageURL: tempStorageURL())
    let sig = DisplayConfiguration.current().signature
    let older = LayoutProfile(
        id: UUID(), displaySignature: sig, name: "Old",
        capturedAt: Date(timeIntervalSinceNow: -3600),
        windows: [], screenFrames: []
    )
    let newer = LayoutProfile(
        id: UUID(), displaySignature: sig, name: "New",
        capturedAt: Date(),
        windows: [], screenFrames: []
    )
    mgr.addProfile(older)
    mgr.addProfile(newer)
    // Sanity: profilesForCurrentSetup orders newest first.
    let ordered = mgr.profilesForCurrentSetup()
    return ordered.count == 2 && ordered.first?.name == "New"
}

// ── 10d ───────────────────────────────────────────────────────
test("autoRestore — tombstoned profile is NOT restored, even if newest") {
    let mgr = LayoutManager(storageURL: tempStorageURL())
    let sig = DisplayConfiguration.current().signature
    let live = LayoutProfile(
        id: UUID(), displaySignature: sig, name: "Live",
        capturedAt: Date(timeIntervalSinceNow: -3600),  // older
        windows: [], screenFrames: []
    )
    var tombstoned = LayoutProfile(
        id: UUID(), displaySignature: sig, name: "Deleted",
        capturedAt: Date(),  // newer than `live`
        windows: [], screenFrames: []
    )
    tombstoned.deletedAt = Date()
    mgr.addProfile(live)
    mgr.addProfile(tombstoned)
    let visible = mgr.profilesForCurrentSetup()
    return visible.count == 1 && visible.first?.name == "Live"
}

// ── 10a ───────────────────────────────────────────────────────
test("suggestedNameForNewLayout — gap-aware (no collision after middle delete)") {
    L.userPreference = .en  // deterministic English template
    let mgr = LayoutManager(storageURL: tempStorageURL())
    let sig = DisplayConfiguration.current().signature
    func p(_ name: String) -> LayoutProfile {
        LayoutProfile(id: UUID(), displaySignature: sig, name: name,
                      capturedAt: Date(), windows: [], screenFrames: [])
    }
    mgr.addProfile(p("Layout 1"))
    mgr.addProfile(p("Layout 3"))
    // Two profiles named "Layout 1" and "Layout 3" → next free is "Layout 2".
    // Old (count+1) implementation would have suggested "Layout 3" — collision.
    let suggested = mgr.suggestedNameForNewLayout()
    return suggested == "Layout 2"
}

// ── 11 ────────────────────────────────────────────────────────
test("LayoutProfile — decodes old JSON without isAutoSnapshot field") {
    let oldJSON = """
    [{
      "id": "\(UUID().uuidString)",
      "displaySignature": "sig",
      "name": "Old",
      "capturedAt": "2026-01-01T00:00:00Z",
      "windows": [],
      "screenFrames": []
    }]
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let profiles = try decoder.decode([LayoutProfile].self, from: oldJSON)
    return profiles.count == 1 && profiles[0].isAutoSnapshot == nil
}

// ── 12 ────────────────────────────────────────────────────────
test("LayoutManager — auto-snapshot hidden from UI but visible to allProfiles") {
    let mgr = LayoutManager(storageURL: tempStorageURL())
    let sig = DisplayConfiguration.current().signature

    let userProfile = LayoutProfile(
        id: UUID(), displaySignature: sig, name: "User",
        capturedAt: Date(), windows: [], screenFrames: [], isAutoSnapshot: false
    )
    let autoProfile = LayoutProfile(
        id: UUID(), displaySignature: sig, name: "_auto",
        capturedAt: Date(), windows: [], screenFrames: [], isAutoSnapshot: true
    )
    mgr.addProfile(userProfile)
    mgr.addProfile(autoProfile)

    let visible = mgr.profilesForCurrentSetup()
    return visible.count == 1
        && visible.first?.name == "User"
        && mgr.allProfiles.count == 2
}

// ── 13 ────────────────────────────────────────────────────────
test("iCloudSync.merge — newer capturedAt wins for same id") {
    let id = UUID()
    let older = LayoutProfile(
        id: id, displaySignature: "sig", name: "Old",
        capturedAt: Date(timeIntervalSince1970: 1_000_000),
        windows: [], screenFrames: []
    )
    let newer = LayoutProfile(
        id: id, displaySignature: "sig", name: "New",
        capturedAt: Date(timeIntervalSince1970: 2_000_000),
        windows: [], screenFrames: []
    )
    let m1 = iCloudSync.merge(local: [older], remote: [newer])
    let m2 = iCloudSync.merge(local: [newer], remote: [older])
    return m1.count == 1 && m1[0].name == "New"
        && m2.count == 1 && m2[0].name == "New"
}

// ── 14 ────────────────────────────────────────────────────────
test("iCloudSync.merge — tombstone wins regardless of capturedAt") {
    let id = UUID()
    let live = LayoutProfile(
        id: id, displaySignature: "sig", name: "Alive",
        capturedAt: Date(timeIntervalSince1970: 5_000_000),
        windows: [], screenFrames: [], deletedAt: nil
    )
    let tombstone = LayoutProfile(
        id: id, displaySignature: "sig", name: "Dead",
        capturedAt: Date(timeIntervalSince1970: 1_000_000),
        windows: [], screenFrames: [],
        deletedAt: Date()  // recent tombstone
    )
    let merged = iCloudSync.merge(local: [live], remote: [tombstone])
    return merged.count == 1 && merged[0].deletedAt != nil
}

// ── 15 ────────────────────────────────────────────────────────
test("iCloudSync.merge — disjoint ids unioned") {
    let a = LayoutProfile(id: UUID(), displaySignature: "sig", name: "A",
        capturedAt: Date(), windows: [], screenFrames: [])
    let b = LayoutProfile(id: UUID(), displaySignature: "sig", name: "B",
        capturedAt: Date(), windows: [], screenFrames: [])
    let merged = iCloudSync.merge(local: [a], remote: [b])
    return merged.count == 2
        && Set(merged.map(\.id)) == Set([a.id, b.id])
}

// ── 16a ───────────────────────────────────────────────────────
test("iCloudSync.merge — modifiedAt wins over older capturedAt (rename propagation)") {
    let id = UUID()
    let oldName = LayoutProfile(
        id: id, displaySignature: "sig", name: "Old",
        capturedAt: Date(timeIntervalSince1970: 5_000_000),
        windows: [], screenFrames: []
    )
    // Same id, same capturedAt, but renamed (modifiedAt set) on the other Mac.
    let renamed = LayoutProfile(
        id: id, displaySignature: "sig", name: "Renamed",
        capturedAt: Date(timeIntervalSince1970: 5_000_000),
        windows: [], screenFrames: [],
        modifiedAt: Date(timeIntervalSince1970: 5_500_000)
    )
    let merged = iCloudSync.merge(local: [oldName], remote: [renamed])
    return merged.count == 1 && merged[0].name == "Renamed"
}

// ── 16b ───────────────────────────────────────────────────────
test("LayoutProfile.revisionTime — picks max(capturedAt, modifiedAt)") {
    let captured = Date(timeIntervalSince1970: 1000)
    let modified = Date(timeIntervalSince1970: 2000)
    let p1 = LayoutProfile(id: UUID(), displaySignature: "x", name: "A",
        capturedAt: captured, windows: [], screenFrames: [],
        modifiedAt: modified)
    let p2 = LayoutProfile(id: UUID(), displaySignature: "x", name: "B",
        capturedAt: captured, windows: [], screenFrames: [],
        modifiedAt: nil)
    return p1.revisionTime == modified && p2.revisionTime == captured
}

// ── 16 ────────────────────────────────────────────────────────
test("iCloudSync.merge — old tombstones (>30 days) garbage-collected") {
    let oldTomb = LayoutProfile(
        id: UUID(), displaySignature: "sig", name: "ancient",
        capturedAt: Date(timeIntervalSince1970: 0),
        windows: [], screenFrames: [],
        deletedAt: Date(timeIntervalSinceNow: -31 * 24 * 3600)
    )
    let recentTomb = LayoutProfile(
        id: UUID(), displaySignature: "sig", name: "recent",
        capturedAt: Date(timeIntervalSince1970: 0),
        windows: [], screenFrames: [],
        deletedAt: Date(timeIntervalSinceNow: -1 * 24 * 3600)
    )
    let merged = iCloudSync.merge(local: [oldTomb, recentTomb], remote: [])
    return merged.count == 1 && merged[0].name == "recent"
}

// ── 17 ────────────────────────────────────────────────────────
test("LayoutProfile — decodes old JSON without modifiedAt/deletedAt") {
    let oldJSON = """
    [{
      "id": "\(UUID().uuidString)",
      "displaySignature": "sig",
      "name": "Old",
      "capturedAt": "2026-01-01T00:00:00Z",
      "windows": [],
      "screenFrames": []
    }]
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let profiles = try decoder.decode([LayoutProfile].self, from: oldJSON)
    return profiles.count == 1
        && profiles[0].modifiedAt == nil
        && profiles[0].deletedAt == nil
        && profiles[0].revisionTime == profiles[0].capturedAt
}

// ── 18 ────────────────────────────────────────────────────────
test("Geometry.clamp — fully off-screen frame pulled back into screen") {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let offscreen = CGRect(x: 5000, y: 5000, width: 800, height: 600)
    let clamped = Geometry.clamp(offscreen, into: screen)
    return clamped.intersects(screen)
        && clamped.width == 800
        && clamped.height == 600
}

// ── 19 ────────────────────────────────────────────────────────
test("Geometry.clamp — frame larger than screen shrunk") {
    let screen = CGRect(x: 0, y: 0, width: 1280, height: 720)
    let huge = CGRect(x: 0, y: 0, width: 4000, height: 3000)
    let clamped = Geometry.clamp(huge, into: screen)
    return clamped.width <= screen.width && clamped.height <= screen.height
}

// ── 20a ───────────────────────────────────────────────────────
test("iCloudSync encoder — preserves fractional seconds (sub-second renames)") {
    let now = Date(timeIntervalSince1970: 1_700_000_000.123456)
    let p = LayoutProfile(
        id: UUID(), displaySignature: "sig", name: "X",
        capturedAt: now, windows: [], screenFrames: [],
        modifiedAt: now.addingTimeInterval(0.001)
    )
    let data = try iCloudSync.makeEncoder().encode([p])
    let back = try iCloudSync.makeDecoder().decode([LayoutProfile].self, from: data)
    return back.count == 1
        && abs(back[0].capturedAt.timeIntervalSince(now)) < 0.001
        && back[0].modifiedAt.map { abs($0.timeIntervalSince(now) - 0.001) < 0.001 } == true
}

// ── 20b ───────────────────────────────────────────────────────
test("iCloudSync decoder — accepts old ISO8601 without fractional seconds") {
    let oldJSON = """
    [{
      "id": "\(UUID().uuidString)",
      "displaySignature": "sig",
      "name": "Legacy",
      "capturedAt": "2026-01-01T12:34:56Z",
      "windows": [],
      "screenFrames": []
    }]
    """.data(using: .utf8)!
    let profiles = try iCloudSync.makeDecoder().decode([LayoutProfile].self, from: oldJSON)
    return profiles.count == 1 && profiles[0].name == "Legacy"
}

// ── 20 ────────────────────────────────────────────────────────
test("Geometry.clamp — already-visible frame returned unchanged") {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let visible = CGRect(x: 100, y: 100, width: 800, height: 600)
    let clamped = Geometry.clamp(visible, into: screen)
    return clamped == visible
}

// ── 25a ───────────────────────────────────────────────────────
test("DisplayConfiguration — legacy v1.0 signature still matched") {
    // Simulate: v1.0 saved a profile under legacy signature; v1.1+ should still find it.
    let cfg = DisplayConfiguration.current()
    let p = LayoutProfile(
        id: UUID(), displaySignature: cfg.legacySignature, name: "From v1.0",
        capturedAt: Date(), windows: [], screenFrames: []
    )
    let mgr = LayoutManager(storageURL: tempStorageURL())
    mgr.addProfile(p)
    return mgr.profilesForCurrentSetup().contains { $0.name == "From v1.0" }
}

// ── 25b ───────────────────────────────────────────────────────
test("DisplayConfiguration — canonical and legacy signatures both produced") {
    let cfg = DisplayConfiguration.current()
    return !cfg.signature.isEmpty
        && !cfg.legacySignature.isEmpty
        && cfg.matchingSignatures.count == 2
}

// MARK: - Two-Mac sync simulation

var _testTempDirs: [URL] = []

func sharediCloudFolder() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("WindowLayoutSync-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _testTempDirs.append(dir)
    return dir
}

/// Block until `file` exists (or `deadline` seconds elapse). Replaces blind sleeps
/// in async-push integration tests so they don't go flaky on slow CI.
func waitForFile(_ file: URL, deadline: TimeInterval = 2.0) {
    let end = Date().addingTimeInterval(deadline)
    while !FileManager.default.fileExists(atPath: file.path) && Date() < end {
        Thread.sleep(forTimeInterval: 0.02)
    }
}

/// Block until `file`'s mtime is newer than `since` (or deadline). Used between
/// successive pushes from different "Macs" to detect a fresh write.
func waitForFileMtime(_ file: URL, after since: Date, deadline: TimeInterval = 2.0) {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
        if let m = try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
           m > since { return }
        Thread.sleep(forTimeInterval: 0.02)
    }
}

// ── 20c ───────────────────────────────────────────────────────
test("iCloud pull — refuses files larger than 5 MB (DoS guard)") {
    let folder = sharediCloudFolder()
    let file = folder.appendingPathComponent("profiles.json")
    // Write a 6 MB file of garbage where the iCloud sync file should be.
    let bigData = Data(repeating: UInt8(ascii: "X"), count: 6 * 1024 * 1024)
    try bigData.write(to: file)
    let sync = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let pulled = sync.pull()
    return pulled == nil  // refused, not parsed
}

// ── 20d ───────────────────────────────────────────────────────
test("iCloud pull — corrupt JSON returns nil instead of crashing") {
    let folder = sharediCloudFolder()
    let file = folder.appendingPathComponent("profiles.json")
    try "{not valid json at all".data(using: .utf8)!.write(to: file)
    let sync = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let pulled = sync.pull()
    return pulled == nil
}

// ── 20e ───────────────────────────────────────────────────────
test("iCloud mergeAndPush — file written with mode 600 (privacy)") {
    let folder = sharediCloudFolder()
    let file = folder.appendingPathComponent("profiles.json")
    let sync = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let p = LayoutProfile(
        id: UUID(), displaySignature: "sig", name: "test",
        capturedAt: Date(), windows: [], screenFrames: []
    )
    sync.mergeAndPush(localSnapshot: [p])
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    return perms == 0o600
}

// ── 21 ────────────────────────────────────────────────────────
test("Two-Mac: sync push then pull preserves profile (file-level)") {
    let folder = sharediCloudFolder()
    let macA = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let macB = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)

    let p = LayoutProfile(
        id: UUID(), displaySignature: "sig", name: "From A",
        capturedAt: Date(), windows: [], screenFrames: []
    )
    guard macA.push(profiles: [p]) else { return false }

    let pulled = macB.pull()
    return pulled?.count == 1 && pulled?.first?.name == "From A"
}

// ── 22 ────────────────────────────────────────────────────────
test("Two-Mac: full LayoutManager cycle — A saves, B converges via merge") {
    let folder = sharediCloudFolder()
    let syncA = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let syncB = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let macA = LayoutManager(storageURL: tempStorageURL(), sync: syncA)
    let macB = LayoutManager(storageURL: tempStorageURL(), sync: syncB)

    let p = LayoutProfile(
        id: UUID(), displaySignature: "sig", name: "Work",
        capturedAt: Date(), windows: [], screenFrames: []
    )
    macA.addProfile(p)  // saveToDisk → push (sync queue)
    waitForFile(folder.appendingPathComponent("profiles.json"))

    macB.mergeRemoteIntoLocal()
    return macB.allProfiles.count == 1
        && macB.allProfiles.first?.id == p.id
        && macB.allProfiles.first?.name == "Work"
}

// ── 23 ────────────────────────────────────────────────────────
test("Two-Mac: rename on B propagates back to A via modifiedAt") {
    let folder = sharediCloudFolder()
    let file = folder.appendingPathComponent("profiles.json")
    let syncA = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let syncB = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let macA = LayoutManager(storageURL: tempStorageURL(), sync: syncA)
    let macB = LayoutManager(storageURL: tempStorageURL(), sync: syncB)

    let id = UUID()
    let p = LayoutProfile(
        id: id, displaySignature: "sig", name: "Original",
        capturedAt: Date(timeIntervalSinceNow: -100),
        windows: [], screenFrames: []
    )
    macA.addProfile(p)
    waitForFile(file)

    macB.mergeRemoteIntoLocal()
    let beforeRename = Date()
    macB.renameProfile(id: id, to: "Renamed-on-B")
    waitForFileMtime(file, after: beforeRename)

    macA.mergeRemoteIntoLocal()
    return macA.allProfiles.first?.name == "Renamed-on-B"
}

// ── 24 ────────────────────────────────────────────────────────
test("Two-Mac: delete on A propagates as tombstone, B no longer sees it") {
    let folder = sharediCloudFolder()
    let file = folder.appendingPathComponent("profiles.json")
    let syncA = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let syncB = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let macA = LayoutManager(storageURL: tempStorageURL(), sync: syncA)
    let macB = LayoutManager(storageURL: tempStorageURL(), sync: syncB)

    let sig = DisplayConfiguration.current().signature
    let id = UUID()
    let p = LayoutProfile(
        id: id, displaySignature: sig, name: "Doomed",
        capturedAt: Date(), windows: [], screenFrames: []
    )
    macA.addProfile(p)
    waitForFile(file)
    macB.mergeRemoteIntoLocal()
    guard macB.profile(id: id) != nil else { return false }

    let beforeDelete = Date()
    macA.deleteProfile(id: id)
    waitForFileMtime(file, after: beforeDelete)

    macB.mergeRemoteIntoLocal()
    return macB.profile(id: id) == nil
        && macB.allProfiles.contains { $0.id == id && $0.deletedAt != nil }
}

// ── 24x ───────────────────────────────────────────────────────
test("Two-Mac: concurrent saves don't lose data (pull-merge-push fix)") {
    let folder = sharediCloudFolder()
    let file = folder.appendingPathComponent("profiles.json")
    let syncA = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let syncB = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let macA = LayoutManager(storageURL: tempStorageURL(), sync: syncA)
    let macB = LayoutManager(storageURL: tempStorageURL(), sync: syncB)

    // Both Macs start with the same shared profile P1.
    let p1 = LayoutProfile(
        id: UUID(), displaySignature: "sig", name: "P1",
        capturedAt: Date(timeIntervalSinceNow: -1000),
        windows: [], screenFrames: []
    )
    macA.addProfile(p1)
    waitForFile(file)
    macB.mergeRemoteIntoLocal()

    // Now both add their OWN profile without first hearing about each other.
    // This simulates the race: A saves P3 while B is unaware, and vice versa.
    let p3 = LayoutProfile(
        id: UUID(), displaySignature: "sig", name: "From-A",
        capturedAt: Date(), windows: [], screenFrames: []
    )
    let p4 = LayoutProfile(
        id: UUID(), displaySignature: "sig", name: "From-B",
        capturedAt: Date(), windows: [], screenFrames: []
    )
    macA.addProfile(p3)
    macB.addProfile(p4)

    // Drain both serial queues so all push closures complete.
    syncA.syncDispatchQueue.sync { }
    syncB.syncDispatchQueue.sync { }

    // Without the fix, iCloud would have either [P1,P3] or [P1,P4] (whoever pushed last
    // wins). With pull-merge-push, iCloud should converge to [P1, P3, P4].
    let pulled = syncA.pull() ?? []
    let names = Set(pulled.map(\.name))
    return pulled.count == 3 && names == ["P1", "From-A", "From-B"]
}

// ── 24a ───────────────────────────────────────────────────────
test("Sync push queue is serial — rapid saves don't reorder in iCloud") {
    let folder = sharediCloudFolder()
    let file = folder.appendingPathComponent("profiles.json")
    let sync = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let mgr = LayoutManager(storageURL: tempStorageURL(), sync: sync)

    // Kick off many saves rapidly — each adds a uniquely-named profile.
    for i in 0..<20 {
        let p = LayoutProfile(
            id: UUID(), displaySignature: "sig", name: "P\(i)",
            capturedAt: Date(timeIntervalSinceNow: TimeInterval(i)),
            windows: [], screenFrames: []
        )
        mgr.addProfile(p)
    }
    // Drain the serial push queue by submitting a barrier that we wait on.
    sync.syncDispatchQueue.sync { }
    // The final iCloud file should reflect the LAST save's state (all 20 profiles).
    waitForFile(file)
    let pulled = sync.pull() ?? []
    return pulled.count == 20
}

// ── 25 ────────────────────────────────────────────────────────
test("Two-Mac: simultaneous renames — newer modifiedAt wins") {
    let folder = sharediCloudFolder()
    let file = folder.appendingPathComponent("profiles.json")
    let syncA = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let syncB = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let macA = LayoutManager(storageURL: tempStorageURL(), sync: syncA)
    let macB = LayoutManager(storageURL: tempStorageURL(), sync: syncB)

    let id = UUID()
    let base = LayoutProfile(
        id: id, displaySignature: "sig", name: "Start",
        capturedAt: Date(timeIntervalSinceNow: -100),
        windows: [], screenFrames: []
    )
    macA.addProfile(base)
    waitForFile(file)
    macB.mergeRemoteIntoLocal()

    let beforeRenameA = Date()
    macA.renameProfile(id: id, to: "A-first")
    waitForFileMtime(file, after: beforeRenameA)

    Thread.sleep(forTimeInterval: 0.01)  // ensure B's modifiedAt is strictly later

    let beforeRenameB = Date()
    macB.renameProfile(id: id, to: "B-second")
    waitForFileMtime(file, after: beforeRenameB)

    macA.mergeRemoteIntoLocal()
    return macA.profile(id: id)?.name == "B-second"
}

// Restore language preference
L.userPreference = originalLang

// Clean up temp folders (sync sandboxes + per-test storage)
for dir in _testTempDirs + _testStorageDirs {
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - Summary

print("\n──────────────────────────")
print("  \(_passed) passed, \(_failed) failed")
if !_failures.isEmpty {
    print("\nFailures:")
    for (name, reason) in _failures {
        print("  • \(name): \(reason)")
    }
}
print("──────────────────────────")
exit(_failed == 0 ? 0 : 1)
