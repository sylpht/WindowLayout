import AppKit
import ApplicationServices

class LayoutManager {
    static let shared: LayoutManager = {
        let mgr = LayoutManager(storageURL: defaultStorageURL(), sync: iCloudSync.shared)
        mgr.subscribeToRemoteChanges()
        return mgr
    }()

    static let didChangeNotification = Notification.Name("WindowLayoutLayoutsDidChange")

    let storageURL: URL
    private let sync: iCloudSync?
    private var profiles: [LayoutProfile] = []

    init(storageURL: URL, sync: iCloudSync? = nil) {
        self.storageURL = storageURL
        self.sync = sync
        loadFromDisk()
        mergeRemoteIntoLocal()
    }

    private static func defaultStorageURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("WindowLayout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }

    // MARK: - Queries

    /// All profiles including auto-snapshots and tombstones. For tests / internal logic.
    var allProfiles: [LayoutProfile] { profiles }

    /// User-visible profiles only (auto-snapshots and tombstones hidden), sorted newest-first.
    func profilesForCurrentSetup() -> [LayoutProfile] {
        let sigs = Set(DisplayConfiguration.current().matchingSignatures)
        return profiles
            .filter { sigs.contains($0.displaySignature) && $0.isAutoSnapshot != true && $0.deletedAt == nil }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    func profile(id: UUID) -> LayoutProfile? {
        profiles.first { $0.id == id && $0.deletedAt == nil }
    }

    // MARK: - Mutations

    func addProfile(_ profile: LayoutProfile) {
        profiles.append(profile)
        saveToDisk()
    }

    @discardableResult
    func saveCurrentLayout(name: String) -> LayoutProfile? {
        let config = DisplayConfiguration.current()
        let screens = NSScreen.screens.map(\.frame)
        guard !screens.isEmpty else { return nil }

        let windows = captureWindows(screens: screens)
        // Refuse to save empty layouts — the user would later "restore" it and nothing
        // happens, with no clue why. Returning nil lets the caller surface a useful error.
        guard !windows.isEmpty else {
            Log.warn("saveCurrentLayout: refusing to save empty layout '\(name)' — captureWindows returned 0 windows (AX denied or all apps excluded?)")
            return nil
        }
        let profile = LayoutProfile(
            id: UUID(),
            displaySignature: config.signature,
            name: name,
            capturedAt: Date(),
            windows: windows,
            screenFrames: screens,
            isAutoSnapshot: false
        )
        profiles.append(profile)
        saveToDisk()
        Log.info("Saved layout '\(name)' — \(windows.count) windows, signature \(config.signature)")
        return profile
    }

    /// Captures current state to a hidden auto-snapshot for the active display signature.
    /// Used as a safety net when the user forgets to save before disconnecting.
    func captureAutoSnapshot() {
        let config = DisplayConfiguration.current()
        let screens = NSScreen.screens.map(\.frame)
        guard !screens.isEmpty else { return }

        let windows = captureWindows(screens: screens)
        guard !windows.isEmpty else { return }

        let sigs = Set(config.matchingSignatures)
        if let idx = profiles.firstIndex(where: {
            sigs.contains($0.displaySignature) && $0.isAutoSnapshot == true && $0.deletedAt == nil
        }) {
            let keepID = profiles[idx].id
            let keepName = profiles[idx].name
            profiles[idx] = LayoutProfile(
                id: keepID,
                displaySignature: config.signature,
                name: keepName,
                capturedAt: Date(),
                windows: windows,
                screenFrames: screens,
                isAutoSnapshot: true
            )
            // Dedupe: a legacy-and-canonical pair could coexist after a v1.0↔v1.1 round-trip.
            // After replacing one with canonical, drop any other auto-snapshot for this setup.
            profiles.removeAll {
                $0.id != keepID
                    && $0.isAutoSnapshot == true
                    && sigs.contains($0.displaySignature)
            }
        } else {
            profiles.append(LayoutProfile(
                id: UUID(),
                displaySignature: config.signature,
                name: "_auto",
                capturedAt: Date(),
                windows: windows,
                screenFrames: screens,
                isAutoSnapshot: true
            ))
        }
        saveToDisk()
    }

    func restoreLayout(id: UUID) {
        guard let profile = profile(id: id) else { return }
        apply(profile: profile)
    }

    /// Restore the best match for the current display configuration:
    /// most-recent user-saved profile first, auto-snapshot as fallback.
    func autoRestore() {
        // Stage Manager auto-arranges windows; restoring positions on top of it just
        // gets clobbered. Skip — user can still manually trigger restore from the menu.
        if WindowEnvironment.isStageManagerActive {
            Log.info("autoRestore skipped: Stage Manager is active")
            return
        }
        let sigs = Set(DisplayConfiguration.current().matchingSignatures)
        // Filter tombstones — a deleted profile would otherwise out-rank a real one
        // (more recent capturedAt) and silently make autoRestore a no-op.
        // matchingSignatures includes both v1.1+ canonical and v1.0 legacy formats.
        let forSetup = profiles.filter { sigs.contains($0.displaySignature) && $0.deletedAt == nil }
        let userSaved = forSetup
            .filter { $0.isAutoSnapshot != true }
            .sorted { $0.capturedAt > $1.capturedAt }
        let autoSnapshot = forSetup.first { $0.isAutoSnapshot == true }
        if let p = userSaved.first ?? autoSnapshot {
            let kind = p.isAutoSnapshot == true ? "auto-snapshot" : "user profile"
            Log.info("autoRestore using \(kind) '\(p.name)' (\(p.windows.count) windows)")
            apply(profile: p)
        } else {
            Log.info("autoRestore: no profile for current display setup (\(sigs.first ?? "?"))")
        }
    }

    func deleteProfile(id: UUID) {
        // Tombstone instead of hard-delete so the deletion propagates via iCloud.
        // Hard-delete only when sync is off (no need to keep history).
        if sync?.enabled == true {
            if let idx = profiles.firstIndex(where: { $0.id == id }) {
                profiles[idx].deletedAt = Date()
                profiles[idx].windows = []  // free up bytes; tombstone doesn't need data
            }
        } else {
            profiles.removeAll { $0.id == id }
        }
        saveToDisk()
    }

    func renameProfile(id: UUID, to newName: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].name = newName
        // Bump modifiedAt so the rename wins the merge race against the same id on another Mac
        // without disturbing capturedAt (which drives the age shown in the menu).
        profiles[idx].modifiedAt = Date()
        saveToDisk()
    }

    func suggestedNameForNewLayout() -> String {
        // Find the next free number by scanning existing names, not by counting profiles.
        // Counting breaks when a middle layout is deleted: count=2 with profiles
        // ["Layout 1", "Layout 3"] would suggest "Layout 3" — colliding with the existing one.
        let existing = profilesForCurrentSetup().map(\.name)
        var n = 1
        let template: (Int) -> String = {
            L.s("Расположение \($0)", "Layout \($0)", "布局 \($0)")
        }
        while existing.contains(template(n)) { n += 1 }
        return template(n)
    }

    // MARK: - Capture

    private var excludedBundleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "excludedApps") ?? [])
    }

    /// Max chars of window title we persist. Window titles often contain confidential
    /// data (email subjects, document paths, browser tabs). We only need enough to
    /// distinguish multiple windows of the same app — 64 chars is plenty.
    private static let maxTitleChars = 64

    private func captureWindows(screens: [CGRect]) -> [WindowSnapshot] {
        let excluded = excludedBundleIDs
        var result: [WindowSnapshot] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, !excluded.contains(bid) else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = axWindows(of: axApp) else { continue }
            for window in windows {
                guard !isMinimized(window),
                      !isFullscreen(window),
                      let frame = axFrame(of: window),
                      frame.width > 50, frame.height > 50 else { continue }
                let title = String(axTitle(of: window).prefix(Self.maxTitleChars))
                // Pick the screen containing the window's CENTER, not the first intersecting one.
                // Stops a window straddling two monitors from being assigned to whichever screen
                // happens to be first in NSScreen.screens (order varies between launches).
                let center = CGPoint(x: frame.midX, y: frame.midY)
                let idx = screens.firstIndex(where: { $0.contains(center) })
                    ?? screens.firstIndex(where: { $0.intersects(frame) })
                    ?? 0
                let screenFrame = screens[min(idx, screens.count - 1)]
                result.append(WindowSnapshot(
                    bundleID: bid,
                    windowTitle: title,
                    frame: frame,
                    normalizedFrame: Geometry.normalize(frame, in: screenFrame),
                    screenIndex: idx
                ))
            }
        }
        return result
    }

    // MARK: - Apply

    private func apply(profile: LayoutProfile) {
        let currentScreens = NSScreen.screens.map(\.frame)
        guard !currentScreens.isEmpty else { return }
        let excluded = excludedBundleIDs

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, !excluded.contains(bid) else { continue }
            // Group snapshots by title so duplicates (e.g. two "New Tab"s) get distinct snapshots.
            // Each snapshot may be consumed at most once per app — no random index fallback,
            // which produced misplaced windows when AX returned them in non-deterministic order.
            var pool = profile.windows.filter { $0.bundleID == bid }
            guard !pool.isEmpty else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = axWindows(of: axApp) else { continue }
            for window in windows {
                guard !isMinimized(window), !isFullscreen(window) else { continue }
                // Truncate live title to the same length we used at save time, otherwise
                // a > 64-char document title (e.g. "Document - lots of words…") never matches
                // the truncated saved version and the window never gets restored.
                let title = String(axTitle(of: window).prefix(Self.maxTitleChars))
                guard let idx = pool.firstIndex(where: { $0.windowTitle == title }) else { continue }
                let s = pool.remove(at: idx)
                let si = min(s.screenIndex, currentScreens.count - 1)
                let target = Geometry.clamp(
                    Geometry.denormalize(s.normalizedFrame, in: currentScreens[si]),
                    into: currentScreens[si]
                )
                setFrame(of: window, to: target)
            }
        }
    }

    // MARK: - AX helpers

    private func axWindows(of app: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success else { return nil }
        return ref as? [AXUIElement]
    }

    private func axFrame(of window: AXUIElement) -> CGRect? {
        var pRef: CFTypeRef?, sRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sRef) == .success,
              let pVal = pRef, CFGetTypeID(pVal) == AXValueGetTypeID(),
              let sVal = sRef, CFGetTypeID(sVal) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pVal as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sVal as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private func axTitle(of window: AXUIElement) -> String {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &ref)
        return (ref as? String) ?? ""
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref)
        return (ref as? Bool) == true
    }

    private func isFullscreen(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &ref)
        return (ref as? Bool) == true
    }

    private func setFrame(of window: AXUIElement, to frame: CGRect) {
        var pos = frame.origin
        var size = frame.size
        // Set size FIRST so a small new size doesn't get clamped at the old position
        // when the new position pushes the window further from screen edges.
        if let sv = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv)
        }
        if let pv = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pv)
        }
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let encoder = iCloudSync.makeEncoder(pretty: true)
        guard let data = try? encoder.encode(profiles) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storageURL, options: .atomic)
        // Owner-only — see the same comment in iCloudSync.swift.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: storageURL.path)
        // Atomically pull-merge-push on the serial queue so that two Macs writing
        // concurrently can't lose each other's data. Without the pull-before-push,
        // Mac A's blind push of [P1, P3] would overwrite Mac B's already-pushed
        // [P1, P4] in iCloud — P4 would survive only in B's local copy until next save.
        if let sync, sync.enabled {
            let snapshot = profiles
            sync.syncDispatchQueue.async { [weak self] in
                // mergeAndPush does the read-merge-write atomically inside a single
                // coordinated-write block — no other Mac can race against us.
                let merged = sync.mergeAndPush(localSnapshot: snapshot)
                if !Self.sameContent(merged, snapshot) {
                    DispatchQueue.main.async { self?.adoptMergedProfiles(merged) }
                }
            }
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Apply an externally-merged set onto current local state, re-merging with whatever
    /// has changed locally since the snapshot was taken (e.g. a save during the async push).
    private func adoptMergedProfiles(_ incoming: [LayoutProfile]) {
        let merged = iCloudSync.merge(local: profiles, remote: incoming)
        if !Self.sameContent(merged, profiles) {
            profiles = merged
            saveLocalOnly()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        profiles = (try? iCloudSync.makeDecoder().decode([LayoutProfile].self, from: data)) ?? []
    }

    // MARK: - iCloud integration

    /// Pull remote profiles from iCloud and merge into local. Called once at startup
    /// and again whenever the iCloud file changes externally.
    /// Internal (not private) so integration tests can simulate the cross-Mac flow.
    func mergeRemoteIntoLocal() {
        guard let sync, let remote = sync.pull() else { return }
        let merged = iCloudSync.merge(local: profiles, remote: remote)
        let weHadSomethingNew = !Self.sameContent(merged, remote)
        if !Self.sameContent(merged, profiles) {
            profiles = merged
            saveLocalOnly()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            Log.info("iCloud merge applied — now \(profiles.count) profiles")
        }
        // If local contributed items remote didn't have (e.g. another Mac's blind push
        // wiped them from iCloud), push the merged result back so they're not lost.
        if weHadSomethingNew, sync.enabled {
            let snapshot = merged
            sync.syncDispatchQueue.async { sync.push(profiles: snapshot) }
        }
    }

    /// True if two profile sets are equivalent for sync purposes (same ids + revisions + tombstones + names).
    static func sameContent(_ a: [LayoutProfile], _ b: [LayoutProfile]) -> Bool {
        guard a.count == b.count else { return false }
        let aMap = Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0) })
        for bp in b {
            guard let ap = aMap[bp.id] else { return false }
            if ap.name != bp.name
                || ap.revisionTime != bp.revisionTime
                || ap.deletedAt != bp.deletedAt {
                return false
            }
        }
        return true
    }

    /// Save to disk WITHOUT pushing to iCloud. Used after merging remote changes.
    private func saveLocalOnly() {
        let encoder = iCloudSync.makeEncoder(pretty: true)
        guard let data = try? encoder.encode(profiles) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storageURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: storageURL.path)
    }

    /// Called from the menu when the user just turned sync ON.
    /// MUST pull-merge first, then push — otherwise a fresh Mac with empty local
    /// would overwrite an already-populated iCloud file with [].
    func kickPush() {
        guard let sync else { return }
        mergeRemoteIntoLocal()  // brief main-thread block while we coordinate the read
        let snapshot = profiles
        // Push asynchronously on the serial queue so any concurrent save still serialises after us.
        sync.syncDispatchQueue.async { sync.push(profiles: snapshot) }
    }

    fileprivate func subscribeToRemoteChanges() {
        NotificationCenter.default.addObserver(
            forName: iCloudSync.didChangeRemotelyNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.mergeRemoteIntoLocal()
        }
        NotificationCenter.default.addObserver(
            forName: iCloudSync.didDisableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.purgeTombstones()
        }
        NotificationCenter.default.addObserver(
            forName: iCloudSync.didDeleteRemotelyNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Re-push local state so the deletion doesn't strand other Macs without data.
            // Same path as kickPush — atomic mergeAndPush will recreate the iCloud file.
            self?.kickPush()
        }
    }

    /// Hard-delete any tombstones. Called when sync is disabled — tombstones can no longer
    /// propagate to other Macs, so keeping them just wastes disk and pollutes allProfiles.
    private func purgeTombstones() {
        let before = profiles.count
        profiles.removeAll { $0.deletedAt != nil }
        if profiles.count != before {
            saveLocalOnly()
            Log.info("Purged \(before - profiles.count) tombstones after sync disabled")
        }
    }
}
