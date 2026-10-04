import Foundation

/// Accessed on the main thread. Only automatic requests are governed by the
/// reconnect preference; an explicit manual request remains available.
final class RestoreScheduler {
    enum Trigger: String {
        case displayChange = "display-change"
        case startup, wake
        case accessibilityGranted = "accessibility-granted"
    }
    static let preferenceDidChangeNotification = Notification.Name("WindowLayoutAutoRestorePreferenceDidChange")
    typealias Cancellation = () -> Void
    typealias Enqueue = (TimeInterval, @escaping () -> Void) -> Cancellation

    struct Attempt {
        let trigger: Trigger
        let number: Int
        let delay: TimeInterval
        let elapsed: TimeInterval
        let scheduledSignature: String
        let currentSignature: String
    }

    private let isEnabled: () -> Bool
    private let currentSignature: () -> String
    private let restore: () -> Void
    private let manualRestore: () -> Void
    private let enqueue: Enqueue
    private let now: () -> Date
    private let onScheduled: (String, Trigger) -> Void
    private let onAttempt: (Attempt) -> Void
    private var cancellations: [Cancellation] = []
    private var generation: UInt = 0

    init(isEnabled: @escaping () -> Bool, currentSignature: @escaping () -> String,
         restore: @escaping () -> Void,
         manualRestore: (() -> Void)? = nil,
         enqueue: @escaping Enqueue = { delay, action in
             let work = DispatchWorkItem(block: action)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
             return { work.cancel() }
         }, now: @escaping () -> Date = Date.init,
         onScheduled: @escaping (String, Trigger) -> Void = { _, _ in },
         onAttempt: @escaping (Attempt) -> Void = { _ in }) {
        self.isEnabled = isEnabled
        self.currentSignature = currentSignature
        self.restore = restore
        self.manualRestore = manualRestore ?? restore
        self.enqueue = enqueue
        self.now = now
        self.onScheduled = onScheduled
        self.onAttempt = onAttempt
    }

    func schedule(for signature: String, trigger: Trigger = .displayChange) {
        cancelPending()
        guard isEnabled() else { return }
        let generation = self.generation
        let scheduledAt = now()
        onScheduled(signature, trigger)
        for (index, delay) in [2.5, 6.0, 14.0].enumerated() {
            let cancellation = enqueue(delay) { [weak self] in
                guard let self, self.generation == generation else { return }
                let currentSignature = self.currentSignature()
                guard self.isEnabled(), currentSignature == signature else {
                    self.cancelPending()
                    return
                }
                self.onAttempt(Attempt(trigger: trigger, number: index + 1, delay: delay,
                                       elapsed: self.now().timeIntervalSince(scheduledAt),
                                       scheduledSignature: signature,
                                       currentSignature: currentSignature))
                self.restore()
            }
            cancellations.append(cancellation)
        }
    }

    func preferenceDidChange() {
        if !isEnabled() { cancelPending() }
    }

    func cancelPending() {
        // Dispatch cancellation alone cannot invalidate a callback already handed
        // off for execution. Generations also prevent off/on from reviving it.
        generation &+= 1
        cancellations.forEach { $0() }
        cancellations.removeAll()
    }

    func restoreManually() {
        cancelPending()
        manualRestore()
    }
}
