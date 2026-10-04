import Foundation

final class RestoreSchedulerFixture {
    final class Job {
        let delay: TimeInterval
        let action: () -> Void
        var cancelled = false

        init(delay: TimeInterval, action: @escaping () -> Void) {
            self.delay = delay
            self.action = action
        }
    }

    var enabled = true
    var trusted = true
    var signature = "display-A"
    var date = Date(timeIntervalSince1970: 100)
    var jobs: [Job] = []
    var attempts: [RestoreScheduler.Attempt] = []
    var restores = 0
    lazy var scheduler = RestoreScheduler(
        isEnabled: { [unowned self] in enabled },
        currentSignature: { [unowned self] in signature },
        restore: { [unowned self] in restores += 1 },
        enqueue: { [unowned self] delay, action in
            let job = Job(delay: delay, action: action)
            jobs.append(job)
            return { job.cancelled = true }
        },
        now: { [unowned self] in date },
        onAttempt: { [unowned self] in attempts.append($0) }
    )
}

func runRestoreSchedulerTests(_ test: (String, () -> Bool) -> Void) {
    test("Restore scheduler — preserves retry delays and diagnostic timing") {
        let f = RestoreSchedulerFixture()
        f.scheduler.schedule(for: f.signature)
        guard f.jobs.map(\.delay) == [2.5, 6, 14] else { return false }
        for job in f.jobs {
            f.date = Date(timeIntervalSince1970: 100 + job.delay)
            job.action()
        }
        return f.restores == 3 && f.attempts.map(\.number) == [1, 2, 3]
            && f.attempts.map(\.elapsed) == [2.5, 6, 14]
            && f.attempts.allSatisfy { $0.scheduledSignature == "display-A" && $0.currentSignature == "display-A" }
    }

    test("Restore scheduler — disabling cancels remaining retries without undoing the first") {
        let f = RestoreSchedulerFixture()
        f.scheduler.schedule(for: f.signature)
        f.jobs[0].action()
        f.enabled = false
        f.scheduler.preferenceDidChange()
        // Deliver even cancelled callbacks: the execution guard must also protect
        // against callbacks already handed off by an enqueue implementation.
        f.jobs[1].action()
        f.jobs[2].action()
        return f.restores == 1 && f.attempts.count == 1 && f.jobs.allSatisfy(\.cancelled)
    }

    test("Restore scheduler — turning back on does not resurrect cancelled retries") {
        let f = RestoreSchedulerFixture()
        f.scheduler.schedule(for: f.signature)
        f.enabled = false
        f.scheduler.preferenceDidChange()
        f.enabled = true
        f.scheduler.preferenceDidChange()
        f.jobs.forEach { $0.action() }
        return f.restores == 0 && f.jobs.count == 3 && f.jobs.allSatisfy(\.cancelled)
    }

    test("Restore scheduler — rechecks preference if a change notification was missed") {
        let f = RestoreSchedulerFixture()
        f.scheduler.schedule(for: f.signature)
        f.enabled = false
        f.jobs[0].action()
        f.enabled = true
        f.jobs[1].action()
        f.jobs[2].action()
        return f.restores == 0 && f.attempts.isEmpty
    }

    test("Restore scheduler — superseded callbacks cannot restore even on the same display") {
        let f = RestoreSchedulerFixture()
        f.scheduler.schedule(for: f.signature)
        let oldJobs = f.jobs
        f.scheduler.schedule(for: f.signature)
        oldJobs.forEach { $0.action() }
        f.jobs[3].action()
        return oldJobs.allSatisfy(\.cancelled) && f.restores == 1 && f.attempts.count == 1
    }

    test("Restore scheduler — mismatched live signature invalidates the old batch") {
        let f = RestoreSchedulerFixture()
        f.scheduler.schedule(for: f.signature)
        f.signature = "display-B"
        f.jobs[0].action()
        f.signature = "display-A"
        f.jobs[1].action()
        f.jobs[2].action()
        return f.restores == 0 && f.attempts.isEmpty
    }

    test("Restore scheduler — disabled display changes cancel old work and schedule nothing") {
        let f = RestoreSchedulerFixture()
        f.scheduler.schedule(for: f.signature)
        f.enabled = false
        f.signature = "display-B"
        f.scheduler.schedule(for: f.signature)
        f.jobs.forEach { $0.action() }
        return f.jobs.count == 3 && f.jobs.allSatisfy(\.cancelled) && f.restores == 0
    }

    test("Restore scheduler — manual restoration works while automatic restoration is disabled") {
        let f = RestoreSchedulerFixture()
        f.scheduler.schedule(for: f.signature)
        f.enabled = false
        f.scheduler.preferenceDidChange()
        f.scheduler.restoreManually()
        f.jobs.forEach { $0.action() }
        return f.restores == 1 && f.attempts.isEmpty
    }
}
