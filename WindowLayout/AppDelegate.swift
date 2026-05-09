import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    private var onboardingController: OnboardingWindowController?
    /// Observer token for the onboarding window's willClose. Stored so we can
    /// remove the previous observer before showOnboarding() registers a new one
    /// — otherwise each language switch leaks an observer bound to a dead window.
    private var onboardingCloseObserver: NSObjectProtocol?
    private var restoreWorkItems: [DispatchWorkItem] = []
    /// Track signature, not just count — hot-swapping one display for another
    /// keeps the count the same but produces a different signature, and the user
    /// expects layouts for the new display to restore.
    private var lastSignature: String = ""
    private var isFirstLaunch = false
    private var axPollTimer: Timer?
    private var lastAXState: Bool = AXIsProcessTrusted()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Log.info("App launched — version \(version), signature \(DisplayConfiguration.current().signature)")
        // Touch LayoutManager.shared first so its observer for iCloud-remote-change is
        // registered before iCloudSync.shared starts watching. Avoids losing a remote
        // change that fires during the tiny window between iCloud init and observer setup.
        _ = LayoutManager.shared
        setupFirstLaunch()

        lastSignature = DisplayConfiguration.current().signature
        statusBarController = StatusBarController()
        observeScreenParameters()
        installDisplayReconfigurationCallback()
        registerGlobalHotkeys()
        startAXPolling()

        if isFirstLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.showOnboarding()
            }
        } else if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
    }

    func showOnboarding() {
        // Remove any previous observer before adding a new one — happens on every
        // language switch, which closes & reopens the window.
        if let prev = onboardingCloseObserver {
            NotificationCenter.default.removeObserver(prev)
        }

        let wc = OnboardingWindowController()
        onboardingController = wc

        onboardingCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: wc.window,
            queue: .main
        ) { [weak self] _ in
            self?.onboardingController = nil
            self?.statusBarController?.refreshMenu()
        }

        wc.present()
    }

    private func setupFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: "hasLaunched") else { return }
        isFirstLaunch = true
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "autoRestore")
        try? SMAppService.mainApp.register()
    }

    // MARK: - Screen observer (post-change)

    private func observeScreenParameters() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let newSig = DisplayConfiguration.current().signature
            let signatureChanged = newSig != self.lastSignature
            let oldSig = self.lastSignature
            self.lastSignature = newSig
            self.statusBarController?.refreshMenu()

            // Trigger autoRestore on ANY signature change (connect, disconnect, hot-swap).
            // autoRestore() itself bails out gracefully if no profile matches the new
            // signature, so a pure resolution change with no saved layout is a free no-op.
            guard signatureChanged, UserDefaults.standard.bool(forKey: "autoRestore") else { return }
            Log.info("Display signature changed: \(oldSig) → \(newSig)")
            self.scheduleRestoreWithRetries()
        }
    }

    /// Fire autoRestore at 2.5s, 6s, 14s after a reconnect. Handles apps that
    /// are still launching (post-login / sleep) and windows that resist the
    /// first `setFrame` call.
    private func scheduleRestoreWithRetries() {
        restoreWorkItems.forEach { $0.cancel() }
        restoreWorkItems.removeAll()

        for delay in [2.5, 6.0, 14.0] {
            let item = DispatchWorkItem {
                LayoutManager.shared.autoRestore()
            }
            restoreWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    // MARK: - Save on disconnect (pre-change)

    private func installDisplayReconfigurationCallback() {
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, userData in
            guard flags.contains(.beginConfigurationFlag) else { return }
            guard let userData else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                delegate.autoSnapshotBeforeChange()
            }
        }, ptr)
    }

    private func autoSnapshotBeforeChange() {
        // Only snapshot if Accessibility is granted — otherwise captureWindows is a no-op.
        guard AXIsProcessTrusted() else { return }
        LayoutManager.shared.captureAutoSnapshot()
    }

    // MARK: - Accessibility polling

    /// Detect when the user grants / revokes Accessibility outside the app
    /// so the menu reflects reality without a restart.
    private func startAXPolling() {
        axPollTimer?.invalidate()
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = AXIsProcessTrusted()
            if current != self.lastAXState {
                self.lastAXState = current
                Log.info("Accessibility permission changed: \(current ? "granted" : "revoked")")
                self.statusBarController?.refreshMenu()
            }
        }
    }

    // MARK: - Global hotkeys

    func applicationWillTerminate(_ notification: Notification) {
        // Explicitly unregister the file presenter so NSFileCoordinator's process-wide
        // registry doesn't keep a dangling reference (mostly cleanliness — process death
        // also clears it, but defensive against future in-process recycling).
        iCloudSync.shared.shutdown()
    }

    private func registerGlobalHotkeys() {
        let modCmdShiftOpt = UInt32(cmdKey | shiftKey | optionKey)

        // ⌘⇧⌥S → save current layout (auto-named)
        HotKeyManager.shared.register(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: modCmdShiftOpt
        ) { [weak self] in
            let name = LayoutManager.shared.suggestedNameForNewLayout()
            // saveCurrentLayout returns nil if no windows could be captured
            // (AX denied, no apps, all excluded). Only flash on actual save.
            if LayoutManager.shared.saveCurrentLayout(name: name) != nil {
                self?.statusBarController?.flashIconSuccess()
                self?.statusBarController?.refreshMenu()
            } else {
                Log.warn("Hotkey ⌘⇧⌥S — save was a no-op (no windows captured)")
            }
        }

        // ⌘⇧⌥R → restore most-recent layout for current setup
        HotKeyManager.shared.register(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: modCmdShiftOpt
        ) { [weak self] in
            LayoutManager.shared.autoRestore()
            // Only flash if apply actually moved something (AX granted, profile matched).
            if LayoutManager.shared.lastApplyMovedWindows {
                self?.statusBarController?.flashIconSuccess()
            } else {
                Log.warn("Hotkey ⌘⇧⌥R — restore was a no-op (AX denied / Stage Manager active / no profile)")
            }
        }
    }
}
