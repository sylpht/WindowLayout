import AppKit

private func lifecycle(_ f: RestoreSchedulerFixture, center: NotificationCenter) -> RestoreLifecycle {
    RestoreLifecycle(scheduler: f.scheduler,
                     currentSignature: { [unowned f] in f.signature },
                     isAccessibilityTrusted: { [unowned f] in f.trusted }, center: center)
}

func runRestoreLifecycleTests(_ test: (String, () -> Bool) -> Void) {
    test("Restore lifecycle — restart schedules restoration without a display change") {
        let f = RestoreSchedulerFixture(), center = NotificationCenter()
        let lifecycle = lifecycle(f, center: center)
        defer { lifecycle.shutdown() }
        lifecycle.start(isFirstLaunch: false)
        guard f.jobs.count == 3 else { return false }
        f.jobs[0].action()
        return f.restores == 1 && f.attempts.first?.trigger == .startup
    }
    test("Restore lifecycle — first launch leaves onboarding windows alone") {
        let f = RestoreSchedulerFixture(), center = NotificationCenter()
        let lifecycle = lifecycle(f, center: center)
        defer { lifecycle.shutdown() }
        lifecycle.start(isFirstLaunch: true)
        lifecycle.accessibilityDidChange(trusted: true)
        return f.jobs.isEmpty
    }
    test("Restore lifecycle — sleep cancels old jobs and wake restores unchanged signature") {
        let f = RestoreSchedulerFixture(), center = NotificationCenter()
        let lifecycle = lifecycle(f, center: center)
        defer { lifecycle.shutdown() }
        lifecycle.start(isFirstLaunch: false)
        let old = f.jobs
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        guard f.jobs.count == 6 else { return false }
        old.forEach { $0.action() }
        f.jobs[3].action()
        return old.allSatisfy(\.cancelled) && f.restores == 1
            && f.attempts.first?.trigger == .wake
    }
    test("Restore lifecycle — disabled preference prevents startup and wake jobs") {
        let f = RestoreSchedulerFixture(), center = NotificationCenter()
        f.enabled = false
        let lifecycle = lifecycle(f, center: center)
        defer { lifecycle.shutdown() }
        lifecycle.start(isFirstLaunch: false)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        return f.jobs.isEmpty
    }
    test("Restore lifecycle — display changes during sleep wait for wake and its current signature") {
        let f = RestoreSchedulerFixture(), center = NotificationCenter()
        let lifecycle = lifecycle(f, center: center)
        defer { lifecycle.shutdown() }
        lifecycle.start(isFirstLaunch: false)
        let old = f.jobs
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        f.signature = "display-B"
        lifecycle.displayDidChange(signature: f.signature)
        guard f.jobs.count == 3 else { return false }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        guard f.jobs.count == 6 else { return false }
        old.forEach { $0.action() }
        f.jobs[3].action()
        return f.restores == 1 && f.attempts.first?.scheduledSignature == "display-B"
            && f.attempts.first?.trigger == .wake
    }
    test("Restore lifecycle — first-launch display change waits for Accessibility grant") {
        let f = RestoreSchedulerFixture(), center = NotificationCenter()
        f.trusted = false
        let lifecycle = lifecycle(f, center: center)
        defer { lifecycle.shutdown() }
        lifecycle.start(isFirstLaunch: true)
        lifecycle.displayDidChange(signature: f.signature)
        guard f.jobs.isEmpty else { return false }
        f.trusted = true
        lifecycle.accessibilityDidChange(trusted: true)
        return f.jobs.count == 3
    }
    test("Restore lifecycle — permission granted during sleep waits for wake") {
        let f = RestoreSchedulerFixture(), center = NotificationCenter()
        f.trusted = false
        let lifecycle = lifecycle(f, center: center)
        defer { lifecycle.shutdown() }
        lifecycle.start(isFirstLaunch: false)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        f.trusted = true
        lifecycle.accessibilityDidChange(trusted: true)
        guard f.jobs.isEmpty else { return false }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        return f.jobs.count == 3
    }
    test("Restore lifecycle — permission revocation cancels and grant uses current displays") {
        let f = RestoreSchedulerFixture(), center = NotificationCenter()
        let lifecycle = lifecycle(f, center: center)
        defer { lifecycle.shutdown() }
        lifecycle.start(isFirstLaunch: false)
        let old = f.jobs
        f.trusted = false
        lifecycle.accessibilityDidChange(trusted: false)
        old.forEach { $0.action() }
        f.signature = "display-B"
        f.trusted = true
        lifecycle.accessibilityDidChange(trusted: true)
        guard f.jobs.count == 6 else { return false }
        f.jobs[3].action()
        return f.restores == 1 && f.attempts.first?.trigger == .accessibilityGranted
            && f.attempts.first?.scheduledSignature == "display-B"
    }
    test("Restore lifecycle — repeated start and shutdown do not leave observers") {
        let f = RestoreSchedulerFixture(), center = NotificationCenter()
        let lifecycle = lifecycle(f, center: center)
        lifecycle.start(isFirstLaunch: false)
        lifecycle.start(isFirstLaunch: false)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        guard f.jobs.count == 6 else { return false }
        lifecycle.shutdown()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        f.jobs.forEach { $0.action() }
        return f.jobs.count == 6 && f.restores == 0 && f.jobs.allSatisfy(\.cancelled)
    }
}
