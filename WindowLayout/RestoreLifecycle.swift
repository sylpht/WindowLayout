import AppKit

/// Workspace sleep notifications use their own notification center. Injecting it
/// lets tests exercise the same observers without putting the machine to sleep.
final class RestoreLifecycle {
    private let scheduler: RestoreScheduler
    private let currentSignature: () -> String
    private let isAccessibilityTrusted: () -> Bool
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var isSleeping = false
    private var restoreWhenTrusted = false

    init(scheduler: RestoreScheduler, currentSignature: @escaping () -> String,
         isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.scheduler = scheduler
        self.currentSignature = currentSignature
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.center = center
    }

    func start(isFirstLaunch: Bool) {
        guard observers.isEmpty else { return }
        isSleeping = false
        restoreWhenTrusted = !isFirstLaunch
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.isSleeping = true
            self?.scheduler.cancelPending()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.isSleeping = false
            self.restoreWhenTrusted = true
            self.scheduler.cancelPending()
            if self.isAccessibilityTrusted() {
                self.scheduler.schedule(for: self.currentSignature(), trigger: .wake)
            }
        })
        if restoreWhenTrusted && isAccessibilityTrusted() {
            scheduler.schedule(for: currentSignature(), trigger: .startup)
        }
    }

    func displayDidChange(signature: String) {
        guard !observers.isEmpty && !isSleeping else { return }
        restoreWhenTrusted = true
        guard isAccessibilityTrusted() else {
            scheduler.cancelPending()
            return
        }
        scheduler.schedule(for: signature)
    }

    func accessibilityDidChange(trusted: Bool) {
        if !trusted {
            scheduler.cancelPending()
        } else if !observers.isEmpty && !isSleeping && restoreWhenTrusted {
            scheduler.schedule(for: currentSignature(), trigger: .accessibilityGranted)
        }
    }

    func shutdown() {
        scheduler.cancelPending()
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    deinit { observers.forEach { center.removeObserver($0) } }
}
