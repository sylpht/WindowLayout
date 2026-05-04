import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    private var onboardingController: OnboardingWindowController?
    private var restoreWorkItems: [DispatchWorkItem] = []
    private var lastScreenCount = 0
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

        lastScreenCount = NSScreen.screens.count
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
        let wc = OnboardingWindowController()
        onboardingController = wc

        NotificationCenter.default.addObserver(
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
            let newCount = NSScreen.screens.count
            let screenAdded = newCount > self.lastScreenCount
            self.lastScreenCount = newCount
            self.statusBarController?.refreshMenu()

            guard screenAdded, UserDefaults.standard.bool(forKey: "autoRestore") else { return }
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
            LayoutManager.shared.saveCurrentLayout(name: name)
            self?.statusBarController?.flashIconSuccess()
            self?.statusBarController?.refreshMenu()
        }

        // ⌘⇧⌥R → restore most-recent layout for current setup
        HotKeyManager.shared.register(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: modCmdShiftOpt
        ) { [weak self] in
            LayoutManager.shared.autoRestore()
            self?.statusBarController?.flashIconSuccess()
        }
    }
}
