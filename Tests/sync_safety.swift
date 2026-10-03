import Foundation
import CoreGraphics

// This standalone runner replaces the production logger so tests only write in
// their temporary folders. Compile without WindowLayout/Log.swift.
enum Log {
    static func info(_ message: String) {}
    static func warn(_ message: String) {}
    static func error(_ message: String) {}
}

enum L {
    static func s(_ ru: String, _ en: String, _ zh: String? = nil) -> String { en }
}

final class MemorySyncPreferences: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    override func bool(forKey defaultName: String) -> Bool { lock.withLock { value } }
    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { self.value = value as? Bool ?? false }
    }
}

final class SyncResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<[LayoutProfile], Error>?
    func set(_ result: Result<[LayoutProfile], Error>) { lock.withLock { value = result } }
    func get() -> Result<[LayoutProfile], Error>? { lock.withLock { value } }
}

enum SyncTestError: Error { case timedOut }

@main
struct SyncSafetyTests {
    static func profile(_ name: String) -> LayoutProfile {
        LayoutProfile(id: UUID(), displaySignature: "test", name: name,
                      capturedAt: Date(timeIntervalSince1970: 1000), windows: [], screenFrames: [])
    }

    static func withSync(_ body: (iCloudSync, URL) throws -> Bool) throws -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WindowLayoutSyncSafety-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(iCloudSync(syncFolderURL: folder, alwaysEnabled: true), folder.appendingPathComponent("profiles.json"))
    }

    static func isFailure<T>(_ result: Result<T, Error>) -> Bool {
        if case .failure = result { return true }
        return false
    }

    static func cancelStagedWrite(reenable: Bool) throws -> Bool {
        try withSync { _, url in
            let original = try iCloudSync.makeEncoder().encode([profile("Remote")])
            try original.write(to: url)
            let preferences = MemorySyncPreferences()
            preferences.set(true, forKey: iCloudSync.prefKey)
            let staged = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0), toggled = DispatchSemaphore(value: 0)
            let result = SyncResultBox()
            let sync = iCloudSync(syncFolderURL: url.deletingLastPathComponent(), alwaysEnabled: false,
                                 preferences: preferences, beforeFileReplacement: {
                staged.signal()
                guard resume.wait(timeout: .now() + 5) == .success else { throw SyncTestError.timedOut }
            })
            defer { resume.signal(); sync.shutdown() }
            let generation = sync.syncGeneration
            sync.syncDispatchQueue.async {
                result.set(sync.mergeAndPush(localSnapshot: [profile("Local")], expectedGeneration: generation))
                finished.signal()
            }
            guard staged.wait(timeout: .now() + 5) == .success else { throw SyncTestError.timedOut }
            let directory = url.deletingLastPathComponent()
            let stagedFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let hasStagedFile = stagedFiles.contains { $0.hasPrefix(".profiles-") && $0.hasSuffix(".tmp") }
            DispatchQueue.global().async {
                sync.enabled = false
                if reenable { sync.enabled = true }
                toggled.signal()
            }
            // If staging wrongly holds the state lock, release the writer on timeout
            // so the test fails instead of deadlocking the runner.
            let toggleCompletedBeforeCommit = toggled.wait(timeout: .now() + 2) == .success
            resume.signal()
            guard finished.wait(timeout: .now() + 5) == .success else { throw SyncTestError.timedOut }
            if !toggleCompletedBeforeCommit {
                guard toggled.wait(timeout: .now() + 5) == .success else { throw SyncTestError.timedOut }
                return false
            }
            guard let outcome = result.get(), case .failure(let error) = outcome,
                  let syncError = error as? iCloudSync.SyncError, case .superseded = syncError else { return false }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            return try hasStagedFile && Data(contentsOf: url) == original && remaining == ["profiles.json"]
                && sync.lastSyncedAt == nil && sync.enabled == reenable
        }
    }

    static func main() {
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Bool) {
            do {
                if try body() { passed += 1; print("PASS \(name)") }
                else { failed += 1; print("FAIL \(name)") }
            } catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        test("missing remote can be created") {
            try withSync { sync, _ in
                let local = profile("Local")
                guard try sync.pullResult().get() == nil else { return false }
                let written = try sync.mergeAndPush(localSnapshot: [local]).get()
                return written.map(\.id) == [local.id] && sync.lastSyncedAt != nil
                    && sync.pull()?.map(\.id) == [local.id]
            }
        }
        test("corrupt remote bytes survive a save") {
            try withSync { sync, url in
                let original = Data("{recoverable but incomplete JSON".utf8)
                try original.write(to: url)
                let result = sync.mergeAndPush(localSnapshot: [profile("Local")])
                return try isFailure(result) && isFailure(sync.pullResult())
                    && Data(contentsOf: url) == original && sync.lastSyncedAt == nil
            }
        }
        test("oversized valid remote bytes survive a save") {
            try withSync { sync, url in
                var original = try iCloudSync.makeEncoder().encode([profile("Remote")])
                original.append(Data(repeating: 32, count: iCloudSync.maxPulledBytes))
                try original.write(to: url)
                let result = sync.mergeAndPush(localSnapshot: [profile("Local")])
                return try isFailure(result) && Data(contentsOf: url) == original && sync.lastSyncedAt == nil
            }
        }
        test("oversized merged output preserves existing remote") {
            try withSync { sync, url in
                let original = try iCloudSync.makeEncoder().encode([profile("Remote")])
                try original.write(to: url)
                let large = profile(String(repeating: "x", count: iCloudSync.maxPulledBytes))
                let result = sync.mergeAndPush(localSnapshot: [large])
                return try isFailure(result) && Data(contentsOf: url) == original && sync.lastSyncedAt == nil
            }
        }
        test("unreadable remote reports failure and preserves bytes") {
            try withSync { sync, url in
                let original = try iCloudSync.makeEncoder().encode([profile("Remote")])
                try original.write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
                // A privileged runner can still read mode-000 files; the directory
                // case below covers a deterministic read failure on those runners.
                if FileManager.default.isReadableFile(atPath: url.path) {
                    print("SKIP permission-denied fixture: runner can read mode-000 files")
                    return true
                }
                let result = sync.mergeAndPush(localSnapshot: [profile("Local")])
                guard isFailure(result), sync.lastSyncedAt == nil else { return false }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return try Data(contentsOf: url) == original
            }
        }
        test("non-file remote reports failure and preserves directory contents") {
            try withSync { sync, url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let child = url.appendingPathComponent("keep")
                try Data("keep".utf8).write(to: child)
                let result = sync.mergeAndPush(localSnapshot: [profile("Local")])
                return try isFailure(result) && Data(contentsOf: child) == Data("keep".utf8)
                    && sync.lastSyncedAt == nil
            }
        }
        test("write failure reports failure without adopting or marking sync successful") {
            try withSync { sync, url in
                let original = try iCloudSync.makeEncoder().encode([profile("Remote")])
                try original.write(to: url)
                let directory = url.deletingLastPathComponent()
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
                if FileManager.default.isWritableFile(atPath: directory.path) {
                    print("SKIP permission-denied fixture: runner can write mode-500 directories")
                    return true
                }
                let result = sync.mergeAndPush(localSnapshot: [profile("Local")])
                return try isFailure(result) && Data(contentsOf: url) == original && sync.lastSyncedAt == nil
            }
        }
        test("stale sync generation cannot change the file") {
            try withSync { sync, url in
                let original = try iCloudSync.makeEncoder().encode([profile("Remote")])
                try original.write(to: url)
                let result = sync.mergeAndPush(localSnapshot: [profile("Local")],
                                               expectedGeneration: sync.syncGeneration - 1)
                return try isFailure(result) && Data(contentsOf: url) == original && sync.lastSyncedAt == nil
            }
        }
        test("disabling sync after staging cancels replacement without blocking the toggle") {
            try cancelStagedWrite(reenable: false)
        }
        test("OFF then ON after staging cannot commit an older sync generation") {
            try cancelStagedWrite(reenable: true)
        }
        test("atomic store uses owner-only mode and preserves old file on invalid output") {
            try withSync { _, url in
                let local = profile("Private")
                try ProfileFileStore.write([local], to: url, pretty: true)
                let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                let before = try Data(contentsOf: url)
                do {
                    try ProfileFileStore.write([local, local], to: url, pretty: true)
                    return false
                } catch {
                    let entries = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
                    return try mode?.intValue == 0o600 && Data(contentsOf: url) == before
                        && entries == ["profiles.json"]
                }
            }
        }
        test("failed atomic replacement removes staging file and preserves destination") {
            try withSync { _, url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let child = url.appendingPathComponent("keep")
                try Data("keep".utf8).write(to: child)
                do {
                    try ProfileFileStore.write([profile("Local")], to: url, pretty: false)
                    return false
                } catch {
                    let entries = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
                    return try Data(contentsOf: child) == Data("keep".utf8) && entries == ["profiles.json"]
                }
            }
        }
        test("duplicate IDs and negative screen indices in remote are rejected without replacement") {
            try withSync { sync, url in
                let local = profile("Duplicate")
                var invalid = profile("Invalid")
                let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
                invalid.windows = [WindowSnapshot(bundleID: "test", windowTitle: "", frame: frame,
                    normalizedFrame: frame, screenIndex: -1)]
                for profiles in [[local, local], [invalid]] {
                    let original = try iCloudSync.makeEncoder().encode(profiles)
                    try original.write(to: url)
                    guard isFailure(sync.pullResult()), isFailure(sync.mergeAndPush(localSnapshot: [])),
                          try Data(contentsOf: url) == original else { return false }
                }
                return true
            }
        }
        test("non-finite geometry cannot replace an existing file") {
            try withSync { _, url in
                let original = try iCloudSync.makeEncoder().encode([profile("Remote")])
                try original.write(to: url)
                var invalid = profile("Invalid")
                let frame = CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)
                invalid.windows = [WindowSnapshot(bundleID: "test", windowTitle: "", frame: frame,
                    normalizedFrame: .zero, screenIndex: 0)]
                do {
                    try ProfileFileStore.write([invalid], to: url, pretty: false)
                    return false
                } catch { return try Data(contentsOf: url) == original }
            }
        }
        test("compatibility push preserves disjoint profiles through safe merge") {
            try withSync { sync, url in
                let remote = profile("Remote"), local = profile("Local")
                try iCloudSync.makeEncoder().encode([remote]).write(to: url)
                return sync.push(profiles: [local]) && Set(sync.pull()?.map(\.id) ?? []) == [remote.id, local.id]
            }
        }
        test("latest tombstone survives in either merge order") {
            let live = profile("Deleted")
            var old = live, recent = live
            old.deletedAt = Date(timeIntervalSinceNow: -31 * 86400)
            recent.deletedAt = Date(timeIntervalSinceNow: -86400)
            for (local, remote) in [(old, recent), (recent, old)] {
                let merged = iCloudSync.merge(local: [local], remote: [remote])
                guard merged.count == 1, merged[0].deletedAt == recent.deletedAt else { return false }
                let withStaleLive = iCloudSync.merge(local: merged, remote: [live])
                guard withStaleLive.count == 1, withStaleLive[0].deletedAt != nil else { return false }
            }
            return true
        }
        test("equal serialized revisions converge in either merge order") {
            var a = profile("Rename-A")
            a.modifiedAt = Date(timeIntervalSince1970: 1700000000.1231)
            var b = a
            b.name = "Rename-B"
            b.modifiedAt = Date(timeIntervalSince1970: 1700000000.1234)
            let decoded = try iCloudSync.makeDecoder().decode([LayoutProfile].self,
                from: iCloudSync.makeEncoder().encode([a, b]))
            guard decoded[0].revisionTime == decoded[1].revisionTime else { return false }
            let ab = iCloudSync.merge(local: [decoded[0]], remote: [decoded[1]])
            let ba = iCloudSync.merge(local: [decoded[1]], remote: [decoded[0]])
            return ab.count == 1 && ba.count == 1 && ab[0].name == ba[0].name
        }
        test("live sub-millisecond dates and their persisted copies choose the same winner") {
            var a = profile("Rename-A")
            a.modifiedAt = Date(timeIntervalSince1970: 1700000000.1234)
            var b = a
            b.name = "Rename-B"
            b.modifiedAt = Date(timeIntervalSince1970: 1700000000.1231)
            let decoded = try iCloudSync.makeDecoder().decode([LayoutProfile].self,
                from: iCloudSync.makeEncoder().encode([a, b]))
            let inputs = [(a, b), (a, decoded[1]), (decoded[0], b), (decoded[0], decoded[1])]
            var winners = Set<Data>()
            for (left, right) in inputs {
                for (local, remote) in [(left, right), (right, left)] {
                    let result = iCloudSync.merge(local: [local], remote: [remote])
                    guard result.count == 1, let data = iCloudSync.canonicalProfileData(result[0]) else { return false }
                    winners.insert(data)
                }
            }
            return winners.count == 1
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
