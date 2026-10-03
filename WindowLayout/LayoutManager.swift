import AppKit
import ApplicationServices

class LayoutManager {
    /// Singleton. `profiles` mutated only from main thread (per convention used by
    /// AppDelegate / StatusBarController / observer dispatchers). Background queue
    /// access (sync push closure) takes a snapshot first, so no shared mutation race.
    nonisolated(unsafe) static let shared: LayoutManager = {
        let mgr = LayoutManager(storageURL: defaultStorageURL(), sync: iCloudSync.shared)
        mgr.subscribeToRemoteChanges()
        return mgr
    }()

    static let didChangeNotification = Notification.Name("WindowLayoutLayoutsDidChange")
    static let didEncounterErrorNotification = Notification.Name("WindowLayoutStorageError")

    let storageURL: URL
    private let sync: iCloudSync?
    private var profiles: [LayoutProfile] = []
    private var initialReadError: Error?
    private(set) var lastStorageError: Error?
    private(set) var lastSyncError: Error?

    init(storageURL: URL, sync: iCloudSync? = nil) {
        self.storageURL = storageURL
        self.sync = sync
        if loadFromDisk() { mergeRemoteIntoLocal() }
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

    @discardableResult
    func addProfile(_ profile: LayoutProfile) -> Bool {
        commit(profiles + [profile])
    }

    @discardableResult
    func saveCurrentLayout(name: String) -> LayoutProfile? {
        lastStorageError = initialReadError
        guard initialReadError == nil else { return nil }
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
        guard commit(profiles + [profile]) else { return nil }
        Log.info("Saved layout '\(name)' — \(windows.count) windows, signature \(config.signature)")
        return profile
    }

    /// Captures current state to a hidden auto-snapshot for the active display signature.
    /// Used as a safety net when the user forgets to save before disconnecting.
    func captureAutoSnapshot() {
        // When Stage Manager is on it parks inactive-app windows in an off-screen sidebar
        // strip; capturing those positions would save garbage that, on restore, would
        // place windows at the SM-parked locations. Skip silently — user-saved layouts
        // (manual Save) still work because the user is making an explicit choice.
        if WindowEnvironment.isStageManagerActive {
            Log.info("captureAutoSnapshot skipped: Stage Manager is active")
            return
        }
        let config = DisplayConfiguration.current()
        let screens = NSScreen.screens.map(\.frame)
        guard !screens.isEmpty else { return }

        let windows = captureWindows(screens: screens)
        guard !windows.isEmpty else { return }

        let sigs = Set(config.matchingSignatures)
        var candidate = profiles
        if let idx = candidate.firstIndex(where: {
            sigs.contains($0.displaySignature) && $0.isAutoSnapshot == true && $0.deletedAt == nil
        }) {
            let keepID = candidate[idx].id
            let keepName = candidate[idx].name
            candidate[idx] = LayoutProfile(
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
            candidate.removeAll {
                $0.id != keepID
                    && $0.isAutoSnapshot == true
                    && sigs.contains($0.displaySignature)
            }
        } else {
            candidate.append(LayoutProfile(
                id: UUID(),
                displaySignature: config.signature,
                name: "_auto",
                capturedAt: Date(),
                windows: windows,
                screenFrames: screens,
                isAutoSnapshot: true
            ))
        }
        commit(candidate)
    }

    func restoreLayout(id: UUID) {
        lastApplyMovedWindows = false
        guard let profile = profile(id: id) else {
            Log.info("restoreLayout skipped: profile not found")
            return
        }
        apply(profile: profile)
    }

    /// Restore the best match for the current display configuration:
    /// most-recent user-saved profile first, auto-snapshot as fallback.
    func autoRestore() {
        lastApplyMovedWindows = false
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

    @discardableResult
    func deleteProfile(id: UUID) -> Bool {
        var candidate = profiles
        // Tombstone instead of hard-delete so the deletion propagates via iCloud.
        // Keep deletion history while sync is paused so enabling it cannot resurrect a profile.
        if sync != nil {
            if let idx = candidate.firstIndex(where: { $0.id == id }) {
                candidate[idx].deletedAt = Date()
                candidate[idx].windows = []  // free up bytes; tombstone doesn't need data
            }
        } else {
            candidate.removeAll { $0.id == id }
        }
        return commit(candidate)
    }

    @discardableResult
    func renameProfile(id: UUID, to newName: String) -> Bool {
        var candidate = profiles
        guard let idx = candidate.firstIndex(where: { $0.id == id }) else { return false }
        candidate[idx].name = newName
        // Bump modifiedAt so the rename wins the merge race against the same id on another Mac
        // without disturbing capturedAt (which drives the age shown in the menu).
        candidate[idx].modifiedAt = Date()
        return commit(candidate)
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

    /// Privacy mode. When true, captured layouts store empty window titles instead of
    /// the (truncated) live title. Restore matches by ordinal position within an app
    /// instead of by title — slightly less precise for multi-window apps, but the
    /// stored profile reveals nothing about your documents / tabs / emails.
    static let privacyHideTitlesPrefKey = "privacyHideTitles"
    private var privacyHideTitles: Bool {
        UserDefaults.standard.bool(forKey: Self.privacyHideTitlesPrefKey)
    }

    private func captureWindows(screens: [CGRect]) -> [WindowSnapshot] {
        Log.info("capture screens: \(DisplayConfiguration.diagnosticScreens())")
        let excluded = excludedBundleIDs
        var result: [WindowSnapshot] = []
        var regularApps = 0, excludedApps = 0, missingBundleID = 0, axFailures = 0
        var available = 0, minimized = 0, fullscreen = 0, unreadableFrames = 0, tooSmall = 0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            regularApps += 1
            guard let bid = app.bundleIdentifier else { missingBundleID += 1; continue }
            guard !excluded.contains(bid) else { excludedApps += 1; continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            let enumeration = axWindows(of: axApp)
            guard let windows = enumeration.windows else {
                axFailures += 1
                Log.warn("capture app=\(bid) pid=\(app.processIdentifier): AX windows unavailable code=\(enumeration.error.rawValue) invalidValue=\(enumeration.error == .success)")
                continue
            }
            available += windows.count
            for window in windows {
                guard !isMinimized(window) else { minimized += 1; continue }
                guard !isFullscreen(window) else { fullscreen += 1; continue }
                guard let frame = axFrame(of: window) else { unreadableFrames += 1; continue }
                guard frame.width > 50, frame.height > 50 else { tooSmall += 1; continue }
                // Privacy mode: store empty title. Restore will match by ordinal
                // position within the app instead.
                let title = privacyHideTitles
                    ? ""
                    : String(axTitle(of: window).prefix(Self.maxTitleChars))
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
        let capturedByApp = Dictionary(grouping: result, by: \.bundleID)
            .map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ",")
        Log.info("captureWindows: axTrusted=\(AXIsProcessTrusted()) regularApps=\(regularApps) excludedApps=\(excludedApps) missingBundleID=\(missingBundleID) axFailures=\(axFailures) available=\(available) minimized=\(minimized) fullscreen=\(fullscreen) unreadableFrames=\(unreadableFrames) tooSmall=\(tooSmall) captured=\(result.count) byApp=[\(capturedByApp)]")
        return result
    }

    // MARK: - Apply

    /// True only when the latest restore observed a frame change greater than 1 pt
    /// between AX reads before and immediately after its setters. This does not
    /// prove that the target was reached or that the frame remained there.
    private(set) var lastApplyMovedWindows = false

    private func apply(profile: LayoutProfile) {
        lastApplyMovedWindows = false
        // Restoring requires AX. Without it AXUIElement* calls silently fail, the windows
        // don't move, but the caller flashes success — misleading. Bail explicitly.
        guard AXIsProcessTrusted() else {
            Log.warn("apply: skipped — Accessibility permission not granted")
            return
        }
        let currentScreens = NSScreen.screens.map(\.frame)
        Log.info("apply screens: \(DisplayConfiguration.diagnosticScreens())")
        guard !currentScreens.isEmpty else {
            Log.warn("apply: skipped — no screens available")
            return
        }
        let excluded = excludedBundleIDs
        let runningApps = NSWorkspace.shared.runningApplications
        let regularApps = runningApps.filter { $0.activationPolicy == .regular }
        let regularBundleIDs = Set(regularApps.compactMap(\.bundleIdentifier))
        let savedByApp = Dictionary(grouping: profile.windows, by: \.bundleID)
        Log.info("apply: saved=\(profile.windows.count) apps=\(savedByApp.count) screens=\(currentScreens.count)")
        for bid in savedByApp.keys.sorted() {
            let status: String?
            if excluded.contains(bid) {
                status = "excluded"
            } else if !regularBundleIDs.contains(bid) {
                status = runningApps.contains { $0.bundleIdentifier == bid } ? "notRegular" : "notRunning"
            } else {
                status = nil
            }
            if let status {
                let count = savedByApp[bid]?.count ?? 0
                Log.info("apply app=\(bid): status=\(status) saved=\(count) unconsumedSaved=\(count)")
            }
        }

        for app in regularApps {
            guard let bid = app.bundleIdentifier, !excluded.contains(bid) else { continue }
            // Group snapshots by title so duplicates (e.g. two "New Tab"s) get distinct snapshots.
            // Each snapshot may be consumed at most once per app — no random index fallback,
            // which produced misplaced windows when AX returned them in non-deterministic order.
            var pool = profile.windows.filter { $0.bundleID == bid }
            guard !pool.isEmpty else { continue }
            var counts = RestoreAppCounts(saved: pool.count)
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            let enumeration = axWindows(of: axApp)
            guard let windows = enumeration.windows else {
                Log.warn("apply app=\(bid) pid=\(app.processIdentifier): status=axWindowsUnavailable code=\(enumeration.error.rawValue) invalidValue=\(enumeration.error == .success) saved=\(pool.count) unconsumedSaved=\(pool.count)")
                continue
            }
            counts.available = windows.count
            for (windowIndex, window) in windows.enumerated() {
                guard !isMinimized(window) else { counts.minimized += 1; continue }
                guard !isFullscreen(window) else { counts.fullscreen += 1; continue }
                // Truncate live title to the same length we used at save time, otherwise
                // a > 64-char document title (e.g. "Document - lots of words…") never matches
                // the truncated saved version and the window never gets restored.
                let title = String(axTitle(of: window).prefix(Self.maxTitleChars))
                // Title match preferred. If the saved snapshot has an empty title (privacy
                // mode at save time), or no title match exists, fall back to ordinal —
                // first remaining empty-title snapshot in the pool.
                let idx = pool.firstIndex(where: { !$0.windowTitle.isEmpty && $0.windowTitle == title })
                    ?? pool.firstIndex(where: { $0.windowTitle.isEmpty })
                guard let i = idx else {
                    if pool.isEmpty { counts.noRemainingSaved += 1 } else { counts.titleMismatch += 1 }
                    continue
                }
                let s = pool.remove(at: i)
                let si = min(s.screenIndex, currentScreens.count - 1)
                let target = Geometry.clamp(
                    Geometry.denormalize(s.normalizedFrame, in: currentScreens[si]),
                    into: currentScreens[si]
                )
                let outcome = setFrame(of: window, to: target)
                counts.record(outcome)
                if outcome.immediateChanged == true { lastApplyMovedWindows = true }
                Log.info("apply app=\(bid) pid=\(app.processIdentifier) windowIndex=\(windowIndex) savedScreenIndex=\(s.screenIndex) targetScreenIndex=\(si): \(outcome.logDescription)")
            }
            Log.info("apply app=\(bid) pid=\(app.processIdentifier): \(counts.logDescription)")
        }
        Log.info("apply complete: immediateFrameChangeObserved=\(lastApplyMovedWindows)")
    }

    // MARK: - AX helpers

    private func axWindows(of app: AXUIElement) -> (windows: [AXUIElement]?, error: AXError) {
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref)
        return (error == .success ? ref as? [AXUIElement] : nil, error)
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

    private func setFrame(of window: AXUIElement, to frame: CGRect) -> RestoreFrameResult {
        let before = axFrame(of: window)
        var pos = frame.origin
        var size = frame.size
        var sizeError: Int32?, positionError: Int32?
        // Set size FIRST so a small new size doesn't get clamped at the old position
        // when the new position pushes the window further from screen edges.
        if let sv = AXValueCreate(.cgSize, &size) {
            sizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv).rawValue
        }
        if let pv = AXValueCreate(.cgPoint, &pos) {
            positionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pv).rawValue
        }
        return RestoreFrameResult(before: before, target: frame, after: axFrame(of: window),
                                  sizeError: sizeError, positionError: positionError)
    }

    // MARK: - Persistence

    @discardableResult
    private func commit(_ candidate: [LayoutProfile], syncAfterCommit: Bool = true) -> Bool {
        do {
            if let initialReadError { throw initialReadError }
            // Preserve a file that became unreadable while the app was running, too.
            _ = try ProfileFileStore.read(from: storageURL)
            try ProfileFileStore.write(candidate, to: storageURL, pretty: true)
            profiles = candidate
            lastStorageError = nil
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            if syncAfterCommit { enqueueSync(candidate) }
            return true
        } catch {
            lastStorageError = error
            Log.error("Local profile persistence failed: \(error)")
            NotificationCenter.default.post(name: Self.didEncounterErrorNotification, object: nil)
            return false
        }
    }

    private func enqueueSync(_ snapshot: [LayoutProfile]) {
        guard let sync, sync.enabled else { return }
        let generation = sync.syncGeneration
        sync.syncDispatchQueue.async { [weak self] in
            guard sync.enabled, sync.syncGeneration == generation else { return }
            let result = sync.mergeAndPush(localSnapshot: snapshot, expectedGeneration: generation)
            DispatchQueue.main.async { [weak self] in
                guard let self, sync.enabled, sync.syncGeneration == generation else { return }
                switch result {
                case .success(let merged):
                    self.lastSyncError = nil
                    self.adoptMergedProfiles(merged)
                case .failure(let error):
                    self.recordSyncError(error)
                }
                NotificationCenter.default.post(name: Self.didEncounterErrorNotification, object: nil)
            }
        }
    }

    private func recordSyncError(_ error: Error) {
        lastSyncError = error
        Log.error("Profile sync failed: \(error)")
        NotificationCenter.default.post(name: Self.didEncounterErrorNotification, object: nil)
    }

    /// Re-merge with edits made locally while the cloud operation was queued.
    private func adoptMergedProfiles(_ incoming: [LayoutProfile]) {
        guard initialReadError == nil else { return }
        let merged = iCloudSync.merge(local: profiles, remote: incoming)
        if !Self.sameContent(merged, profiles) {
            commit(merged, syncAfterCommit: false)
        }
    }

    private func loadFromDisk() -> Bool {
        do {
            profiles = try ProfileFileStore.read(from: storageURL) ?? []
            return true
        } catch {
            initialReadError = error
            lastStorageError = error
            Log.error("Local profile load failed; preserving original file: \(error)")
            return false
        }
    }

    // MARK: - iCloud integration

    func mergeRemoteIntoLocal() {
        guard initialReadError == nil, let sync, sync.enabled else { return }
        switch sync.pullResult() {
        case .failure(let error):
            recordSyncError(error)
        case .success(let remote):
            lastSyncError = nil
            guard let remote else { return }
            let merged = iCloudSync.merge(local: profiles, remote: remote)
            let localContributed = !Self.sameContent(merged, remote)
            if !Self.sameContent(merged, profiles) {
                guard commit(merged, syncAfterCommit: false) else { return }
            }
            if localContributed { enqueueSync(profiles) }
        }
    }

    /// Compare persisted content, including geometry and metadata, without trapping on duplicate IDs.
    static func sameContent(_ a: [LayoutProfile], _ b: [LayoutProfile]) -> Bool {
        guard a.count == b.count,
              Set(a.map(\.id)).count == a.count,
              Set(b.map(\.id)).count == b.count else { return false }
        let lhs = a.sorted { $0.id.uuidString < $1.id.uuidString }
        let rhs = b.sorted { $0.id.uuidString < $1.id.uuidString }
        return zip(lhs, rhs).allSatisfy { left, right in
            guard let leftData = iCloudSync.canonicalProfileData(left),
                  let rightData = iCloudSync.canonicalProfileData(right) else { return false }
            return leftData == rightData
        }
    }

    /// Re-read and merge on the write queue; a startup snapshot must not overwrite a newer remote file.
    func kickPush() {
        guard initialReadError == nil else { return }
        enqueueSync(profiles)
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
            self?.lastSyncError = nil
            NotificationCenter.default.post(name: Self.didEncounterErrorNotification, object: nil)
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

}
