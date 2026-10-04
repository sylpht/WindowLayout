import Foundation
import CoreGraphics

/// AX setters may succeed before an app updates its frame. These observations are
/// immediate readbacks, not a guarantee that the requested frame will persist.
struct RestoreFrameResult {
    let before: CGRect?
    let target: CGRect
    let after: CGRect?
    let sizeError: Int32?
    let positionError: Int32?

    static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) <= 1 && abs(a.origin.y - b.origin.y) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    var immediateChanged: Bool? {
        guard let before, let after else { return nil }
        return !Self.framesMatch(before, after)
    }

    var immediateTargetMatch: Bool? {
        after.map { Self.framesMatch($0, target) }
    }

    var setterFailed: Bool { sizeError != 0 || positionError != 0 }

    var logDescription: String {
        "sizeAX=\(sizeError.map(String.init) ?? "value-unavailable") "
            + "positionAX=\(positionError.map(String.init) ?? "value-unavailable") "
            + "before=\(Self.describe(before)) target=\(Self.describe(target)) "
            + "immediateAfter=\(Self.describe(after)) "
            + "immediateChanged=\(immediateChanged.map(String.init) ?? "unknown") "
            + "immediateTargetMatch=\(immediateTargetMatch.map(String.init) ?? "unknown")"
    }

    private static func describe(_ frame: CGRect?) -> String {
        guard let frame else { return "unavailable" }
        return String(format: "[%.1f,%.1f,%.1f,%.1f]",
                      Double(frame.origin.x), Double(frame.origin.y),
                      Double(frame.width), Double(frame.height))
    }
}

struct RestoreAppCounts {
    let saved: Int
    var processes = 0
    var axWindowFailures = 0
    var available = 0
    var minimized = 0
    var fullscreen = 0
    var placementUnresolved = 0
    var titleMismatch = 0
    var noRemainingSaved = 0
    var attempted = 0
    var immediateChanged = 0
    var immediateTargetMismatch = 0
    var immediateReadbackMissing = 0
    var setterFailures = 0

    mutating func record(_ result: RestoreFrameResult) {
        attempted += 1
        if result.immediateChanged == true { immediateChanged += 1 }
        if result.immediateTargetMatch == false { immediateTargetMismatch += 1 }
        if result.before == nil || result.after == nil { immediateReadbackMissing += 1 }
        if result.setterFailed { setterFailures += 1 }
    }

    func logDescription(unconsumedSaved: Int) -> String {
        "saved=\(saved) processes=\(processes) axWindowFailures=\(axWindowFailures) available=\(available) minimized=\(minimized) fullscreen=\(fullscreen) "
            + "placementUnresolved=\(placementUnresolved) "
            + "titleMismatch=\(titleMismatch) noRemainingSaved=\(noRemainingSaved) attempted=\(attempted) unconsumedSaved=\(unconsumedSaved) "
            + "setterFailures=\(setterFailures) immediateChanged=\(immediateChanged) "
            + "immediateTargetMismatch=\(immediateTargetMismatch) immediateReadbackMissing=\(immediateReadbackMissing)"
    }
}
