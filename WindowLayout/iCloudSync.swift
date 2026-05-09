import Foundation

/// Lightweight iCloud Drive sync via the user's `~/Library/Mobile Documents/com~apple~CloudDocs/WindowLayout/`
/// folder. Works without iCloud entitlements or a paid Developer Program — macOS handles the
/// actual upload/download via finderd. We only read/write a JSON file and watch for remote changes.
final class iCloudSync: NSObject, NSFilePresenter {

    static let shared = iCloudSync()

    /// ISO8601 with fractional seconds. The default `.iso8601` strategy strips
    /// sub-second precision, which makes two renames within the same second tie
    /// at merge time (and the `>=` tie-break leaves a divergence between Macs).
    static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func makeEncoder(pretty: Bool = false) -> JSONEncoder {
        let enc = JSONEncoder()
        if pretty { enc.outputFormatting = .prettyPrinted }
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(dateFormatter.string(from: date))
        }
        return enc
    }

    static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            // Try fractional first (new format), fall back to standard ISO8601 (old files).
            if let d = dateFormatter.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            if let d = plain.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                debugDescription: "Unparseable date: \(s)")
        }
        return dec
    }

    static let didChangeRemotelyNotification = Notification.Name("WindowLayoutiCloudDidChange")
    /// Posted when the iCloud file is deleted externally. Observed by LayoutManager
    /// which re-pushes local state so the deletion doesn't strand other Macs.
    static let didDeleteRemotelyNotification = Notification.Name("WindowLayoutiCloudDidDelete")
    static let prefKey = "iCloudSyncEnabled"

    /// Queue for NSFilePresenter callbacks. Named so it shows up identifiably in
    /// Instruments / sample dumps.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.windowlayout.iCloudSync.presenter"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 1  // serialize callbacks; we don't reorder events
        return q
    }()
    private var watching = false
    /// Serial queue for push/pull. Ensures two rapid saves don't get reordered on the
    /// global concurrent .utility queue (which would let an older snapshot overwrite a
    /// newer one in iCloud).
    private let pushQueue = DispatchQueue(label: "com.windowlayout.iCloudSync.push", qos: .utility)
    var syncDispatchQueue: DispatchQueue { pushQueue }

    /// Override for tests: when set, syncFolderURL returns this instead of the iCloud Drive path.
    private let injectedFolder: URL?
    /// Override for tests: when true, `enabled` is forced on regardless of UserDefaults
    /// (and toggling has no effect).
    private let alwaysEnabled: Bool

    /// Production initialiser for the singleton.
    override convenience init() { self.init(syncFolderURL: nil, alwaysEnabled: false) }

    /// Test initialiser — point at a temp folder, force enabled, bypass UserDefaults.
    init(syncFolderURL: URL?, alwaysEnabled: Bool) {
        self.injectedFolder = syncFolderURL
        self.alwaysEnabled = alwaysEnabled
        super.init()
        // Test instances never start watching — tests poll directly via push/pull.
        if !alwaysEnabled, enabled { startWatching() }
    }

    /// User-toggle in menu. Persisted in UserDefaults.
    var enabled: Bool {
        get { alwaysEnabled || UserDefaults.standard.bool(forKey: Self.prefKey) }
        set {
            if alwaysEnabled { return }  // immutable for test instances
            let was = UserDefaults.standard.bool(forKey: Self.prefKey)
            UserDefaults.standard.set(newValue, forKey: Self.prefKey)
            if newValue {
                startWatching()
            } else {
                stopWatching()
                if was {
                    NotificationCenter.default.post(name: Self.didDisableNotification, object: nil)
                }
            }
        }
    }

    static let didDisableNotification = Notification.Name("WindowLayoutiCloudDidDisable")

    /// True if iCloud Drive is available on this machine.
    var isAvailable: Bool { syncFolderURL != nil }

    /// Date of last successful pull/push, for UI status text. Nil if never synced.
    /// Read/written under `syncStateLock` because writes happen on the file-coordinator queue
    /// while reads happen on the main thread (menu refresh).
    private let syncStateLock = NSLock()
    private var _lastSyncedAt: Date?
    var lastSyncedAt: Date? {
        get { syncStateLock.withLock { _lastSyncedAt } }
    }
    private func setLastSyncedAt(_ date: Date) {
        syncStateLock.withLock { _lastSyncedAt = date }
    }

    // MARK: - Paths

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/WindowLayout/`
    /// Returns nil if iCloud Drive is not enabled (folder missing). Tests can override
    /// this by passing a temp folder to the test init.
    var syncFolderURL: URL? {
        if let injected = injectedFolder { return injected }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let icloud = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: icloud.path) else { return nil }
        return icloud.appendingPathComponent("WindowLayout", isDirectory: true)
    }

    var syncFileURL: URL? { syncFolderURL?.appendingPathComponent("profiles.json") }

    // MARK: - Lifecycle

    private func startWatching() {
        guard !watching, isAvailable else { return }
        ensureFolderExists()
        NSFileCoordinator.addFilePresenter(self)
        watching = true
        Log.info("iCloud sync watching \(syncFileURL?.path ?? "?")")
    }

    private func stopWatching() {
        guard watching else { return }
        NSFileCoordinator.removeFilePresenter(self)
        queue.cancelAllOperations()
        // Clear stale "synced N ago" so re-enabling later doesn't briefly show
        // an irrelevant old timestamp before the first new sync lands.
        syncStateLock.withLock { _lastSyncedAt = nil }
        watching = false
    }

    /// Called from AppDelegate.applicationWillTerminate.
    func shutdown() { stopWatching() }

    private func ensureFolderExists() {
        guard let folder = syncFolderURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // MARK: - Push / pull

    /// Write local profiles to the iCloud folder. macOS handles the actual upload.
    /// Returns true on successful write.
    @discardableResult
    func push(profiles: [LayoutProfile]) -> Bool {
        guard enabled, let url = syncFileURL else { return false }
        ensureFolderExists()

        // Compact JSON for iCloud — pretty-printing bloats sync diffs ~3x with no benefit.
        let encoder = Self.makeEncoder(pretty: false)
        guard let data = try? encoder.encode(profiles) else { return false }

        let coordinator = NSFileCoordinator(filePresenter: self)
        var coordError: NSError?
        var success = false
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: writeURL.path)
                setLastSyncedAt(Date())
                success = true
                Log.info("iCloud push: \(profiles.count) profiles → \(url.lastPathComponent)")
            } catch {
                Log.error("iCloud push failed: \(error)")
            }
        }
        if let e = coordError { Log.error("iCloud push coordination failed: \(e)") }
        return success
    }

    /// Reject any pulled file larger than this. A normal user has at most a few KB.
    /// Defends against accidental or malicious giant files (10MB+) DoS'ing the parse.
    static let maxPulledBytes = 5 * 1024 * 1024  // 5 MB

    /// Atomic pull-merge-push inside a single coordinated write block.
    /// NSFileCoordinator serialises writes across all clients (this process AND finderd
    /// AND other processes), so the read-merge-write sequence inside the block can't
    /// race against another Mac's concurrent push.
    /// Returns the merged profile set so the caller can update local state.
    @discardableResult
    func mergeAndPush(localSnapshot: [LayoutProfile]) -> [LayoutProfile] {
        guard enabled, let url = syncFileURL else { return localSnapshot }
        ensureFolderExists()

        var result = localSnapshot
        let coordinator = NSFileCoordinator(filePresenter: self)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            // Read whatever is currently in iCloud (may be empty if file missing).
            var remote: [LayoutProfile] = []
            if FileManager.default.fileExists(atPath: writeURL.path),
               let data = try? Data(contentsOf: writeURL) {
                if data.count > Self.maxPulledBytes {
                    Log.error("iCloud file too large (\(data.count) bytes > \(Self.maxPulledBytes)) — refusing to parse")
                } else if let parsed = try? Self.makeDecoder().decode([LayoutProfile].self, from: data) {
                    remote = parsed
                }
            }
            // Merge local with whatever the OTHER Mac just put there.
            let merged = Self.merge(local: localSnapshot, remote: remote)
            result = merged
            // Write the merged result back atomically.
            let encoder = Self.makeEncoder(pretty: false)
            guard let outData = try? encoder.encode(merged) else { return }
            do {
                try outData.write(to: writeURL, options: .atomic)
                // Restrict to owner read/write — window titles can contain sensitive data
                // and the file's default mode (644) lets any local process read them.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: writeURL.path)
                setLastSyncedAt(Date())
                Log.info("iCloud mergeAndPush: \(merged.count) profiles (remote had \(remote.count), local snapshot had \(localSnapshot.count))")
            } catch {
                Log.error("iCloud mergeAndPush write failed: \(error)")
            }
        }
        if let e = coordError { Log.error("iCloud mergeAndPush coordination failed: \(e)") }
        return result
    }

    /// Read remote profiles from iCloud. Returns nil if file doesn't exist yet or parse fails.
    func pull() -> [LayoutProfile]? {
        guard enabled, let url = syncFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }

        let coordinator = NSFileCoordinator(filePresenter: self)
        var coordError: NSError?
        var result: [LayoutProfile]?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            if data.count > Self.maxPulledBytes {
                Log.error("iCloud file too large (\(data.count) bytes) — refusing to parse")
                return
            }
            result = try? Self.makeDecoder().decode([LayoutProfile].self, from: data)
            if result != nil {
                setLastSyncedAt(Date())
            } else {
                Log.error("iCloud pull: failed to decode \(data.count) bytes — corrupt file")
            }
        }
        if let e = coordError { Log.error("iCloud pull coordination failed: \(e)") }
        return result
    }

    // MARK: - Merge

    /// Merge local + remote profiles. Strategy:
    ///   - Index by `id`. When both sides have the same id, keep the side with newer `capturedAt`.
    ///   - Tombstones (`deletedAt != nil`) win over live profiles regardless of capturedAt.
    ///   - Garbage-collect tombstones older than 30 days.
    static func merge(local: [LayoutProfile], remote: [LayoutProfile]) -> [LayoutProfile] {
        var byID: [UUID: LayoutProfile] = [:]
        for p in local { byID[p.id] = p }
        for p in remote {
            if let existing = byID[p.id] {
                byID[p.id] = newer(existing, p)
            } else {
                byID[p.id] = p
            }
        }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        return byID.values.filter { p in
            guard let d = p.deletedAt else { return true }
            return d > cutoff
        }
    }

    private static func newer(_ a: LayoutProfile, _ b: LayoutProfile) -> LayoutProfile {
        // Tombstones always win — we never want a delete to be overwritten by a stale save.
        if a.deletedAt != nil && b.deletedAt == nil { return a }
        if b.deletedAt != nil && a.deletedAt == nil { return b }
        // Use revisionTime (max of capturedAt and modifiedAt) so renames also win the race.
        return a.revisionTime >= b.revisionTime ? a : b
    }

    // MARK: - NSFilePresenter

    var presentedItemURL: URL? { syncFileURL }
    var presentedItemOperationQueue: OperationQueue { queue }

    func presentedItemDidChange() {
        Log.info("iCloud: remote change detected")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeRemotelyNotification, object: nil)
        }
    }

    /// Called when the iCloud file is deleted externally (Finder, another Mac wiping it).
    /// We re-push our local state so the file reappears — we'd rather keep our profiles
    /// than honor an unintentional delete.
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        Log.info("iCloud: remote file deleted externally — will re-push local state")
        completionHandler(nil)
        DispatchQueue.main.async {
            // Distinct notification: pull-merge wouldn't help here (file is gone),
            // we need an explicit re-push from local.
            NotificationCenter.default.post(name: Self.didDeleteRemotelyNotification, object: nil)
        }
    }

    deinit {
        if watching { NSFileCoordinator.removeFilePresenter(self) }
    }
}
