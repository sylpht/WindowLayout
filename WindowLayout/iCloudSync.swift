import Foundation

/// Lightweight iCloud Drive sync via the user's `~/Library/Mobile Documents/com~apple~CloudDocs/WindowLayout/`
/// folder. Works without iCloud entitlements or a paid Developer Program — macOS handles the
/// actual upload/download via finderd. We only read/write a JSON file and watch for remote changes.
final class iCloudSync: NSObject, NSFilePresenter {

    // Singleton. Mutable state inside (watching, _lastSyncedAt, queues) is guarded
    // by syncStateLock or by the dispatch queues themselves — see those declarations.
    nonisolated(unsafe) static let shared = iCloudSync()

    /// ISO8601 with fractional seconds. The default `.iso8601` strategy strips
    /// sub-second precision, which makes two renames within the same second tie
    /// at merge time (and the `>=` tie-break leaves a divergence between Macs).
    /// ISO8601DateFormatter is documented thread-safe, so nonisolated(unsafe) is correct.
    nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
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
            let was = syncStateLock.withLock {
                let previous = UserDefaults.standard.bool(forKey: Self.prefKey)
                UserDefaults.standard.set(newValue, forKey: Self.prefKey)
                if previous != newValue { _syncGeneration += 1 }
                return previous
            }
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
    private var _syncGeneration = 0
    var syncGeneration: Int { syncStateLock.withLock { _syncGeneration } }
    var lastSyncedAt: Date? {
        get { syncStateLock.withLock { _lastSyncedAt } }
    }
    private func setLastSyncedAt(_ date: Date, generation: Int) -> Bool {
        syncStateLock.withLock {
            guard _syncGeneration == generation && enabled else { return false }
            _lastSyncedAt = date
            return true
        }
    }

    private func operationIsCurrent(_ generation: Int) -> Bool {
        syncStateLock.withLock { _syncGeneration == generation && enabled }
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

    /// Compatibility entry point; all writes merge the latest readable local replica.
    @discardableResult
    func push(profiles: [LayoutProfile]) -> Bool {
        if case .success = mergeAndPush(localSnapshot: profiles) { return true }
        return false
    }

    /// Reject any pulled file larger than this. A normal user has at most a few KB.
    /// Defends against accidental or malicious giant files (10MB+) DoS'ing the parse.
    static let maxPulledBytes = ProfileFileStore.defaultMaxBytes

    enum SyncError: LocalizedError {
        case unavailable, superseded, coordinationDidNotRun

        var errorDescription: String? {
            switch self {
            case .unavailable: return L.s("iCloud Drive недоступен.", "iCloud Drive is unavailable.", "iCloud 云盘不可用。")
            case .superseded: return L.s("Синхронизация отменена из-за изменения настроек.", "The sync operation was cancelled because sync settings changed.", "同步设置已更改，操作已取消。")
            case .coordinationDidNotRun: return L.s("Не удалось выполнить согласованную операцию с файлом.", "The coordinated file operation did not run.", "未能执行协调的文件操作。")
            }
        }
    }

    /// Coordinate the read-merge-write against other writers of this local replica.
    /// This is not a distributed lock across Macs or an iCloud conflict-version resolver.
    /// Only successful writes return profiles that the caller may adopt locally.
    @discardableResult
    func mergeAndPush(localSnapshot: [LayoutProfile], expectedGeneration: Int? = nil) -> Result<[LayoutProfile], Error> {
        let generation = expectedGeneration ?? syncGeneration
        guard operationIsCurrent(generation) else { return .failure(SyncError.superseded) }
        guard let url = syncFileURL else { return .failure(SyncError.unavailable) }
        do {
            try ProfileFileStore.validate(localSnapshot)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch { return .failure(error) }

        var result: Result<[LayoutProfile], Error> = .failure(SyncError.coordinationDidNotRun)
        let coordinator = NSFileCoordinator(filePresenter: self)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            do {
                guard operationIsCurrent(generation) else { throw SyncError.superseded }
                let remote = try ProfileFileStore.read(from: writeURL) ?? []
                let merged = Self.merge(local: localSnapshot, remote: remote)
                guard operationIsCurrent(generation) else { throw SyncError.superseded }
                try ProfileFileStore.write(merged, to: writeURL, pretty: false)
                guard setLastSyncedAt(Date(), generation: generation) else { throw SyncError.superseded }
                result = .success(merged)
                Log.info("iCloud mergeAndPush: \(merged.count) profiles (remote had \(remote.count), local snapshot had \(localSnapshot.count))")
            } catch {
                result = .failure(error)
                Log.error("iCloud mergeAndPush failed: \(error)")
            }
        }
        if let e = coordError {
            Log.error("iCloud mergeAndPush coordination failed: \(e)")
            return .failure(e)
        }
        return result
    }

    /// Read remote profiles from iCloud. Returns nil if file doesn't exist yet or parse fails.
    func pull() -> [LayoutProfile]? {
        try? pullResult().get()
    }

    func pullResult() -> Result<[LayoutProfile]?, Error> {
        let generation = syncGeneration
        guard operationIsCurrent(generation) else { return .failure(SyncError.superseded) }
        guard let url = syncFileURL else { return .failure(SyncError.unavailable) }

        let coordinator = NSFileCoordinator(filePresenter: self)
        var coordError: NSError?
        var result: Result<[LayoutProfile]?, Error> = .failure(SyncError.coordinationDidNotRun)

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            do {
                guard operationIsCurrent(generation) else { throw SyncError.superseded }
                let profiles = try ProfileFileStore.read(from: readURL)
                guard operationIsCurrent(generation) else { throw SyncError.superseded }
                if profiles != nil, !setLastSyncedAt(Date(), generation: generation) { throw SyncError.superseded }
                result = .success(profiles)
            } catch {
                result = .failure(error)
                Log.error("iCloud pull failed: \(error)")
            }
        }
        if let e = coordError {
            Log.error("iCloud pull coordination failed: \(e)")
            return .failure(e)
        }
        return result
    }

    // MARK: - Merge

    /// Merge local + remote profiles. Strategy:
    ///   - Index by `id`. When both sides have the same id, keep the side with newer `capturedAt`.
    ///   - Tombstones (`deletedAt != nil`) win over live profiles regardless of capturedAt.
    ///   - Garbage-collect tombstones older than 30 days.
    static func merge(local: [LayoutProfile], remote: [LayoutProfile]) -> [LayoutProfile] {
        var byID: [UUID: LayoutProfile] = [:]
        for p in local + remote {
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
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func newer(_ a: LayoutProfile, _ b: LayoutProfile) -> LayoutProfile {
        // Tombstones always win — we never want a delete to be overwritten by a stale save.
        if a.deletedAt != nil && b.deletedAt == nil { return a }
        if b.deletedAt != nil && a.deletedAt == nil { return b }
        if let aDeleted = a.deletedAt, let bDeleted = b.deletedAt,
           persistedDate(aDeleted) != persistedDate(bDeleted) {
            return persistedDate(aDeleted) > persistedDate(bDeleted) ? a : b
        }
        // Use revisionTime (max of capturedAt and modifiedAt) so renames also win the race.
        let aRevision = persistedDate(a.revisionTime), bRevision = persistedDate(b.revisionTime)
        if aRevision != bRevision { return aRevision > bRevision ? a : b }
        // The persisted representation also resolves ties identically on both Macs,
        // including a live Date with precision that the on-disk codec cannot retain.
        let aData = canonicalProfileData(a) ?? Data(), bData = canonicalProfileData(b) ?? Data()
        return aData.lexicographicallyPrecedes(bData) ? b : a
    }

    static func canonicalProfileData(_ profile: LayoutProfile) -> Data? {
        let encoder = makeEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(profile)
    }

    private static func persistedDate(_ date: Date) -> Date {
        dateFormatter.date(from: dateFormatter.string(from: date)) ?? date
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
