/// One pool for an entire restore, shared by every process with the same bundle ID.
/// Process IDs and AX enumeration order are not persistent window identities.
struct SnapshotMatchPool {
    static let maxTitleChars = 64

    enum Candidate {
        case eligible(title: String)
        case minimized
        case fullscreen
    }

    enum Match {
        case matched(WindowSnapshot)
        case minimized
        case fullscreen
        case titleMismatch
        case noRemainingSaved
    }

    private var remainingByBundle: [String: [WindowSnapshot]]

    init(snapshots: [WindowSnapshot]) {
        remainingByBundle = Dictionary(grouping: snapshots, by: \.bundleID)
    }

    func remainingCount(for bundleID: String) -> Int {
        remainingByBundle[bundleID]?.count ?? 0
    }

    /// nil means AX could not enumerate this process. Skipped windows and failed
    /// enumeration leave the shared pool intact for another process to use.
    mutating func matchProcess(bundleID: String, windows: [Candidate]?) -> [Match] {
        guard let windows else { return [] }
        return windows.map { candidate in
            switch candidate {
            case .minimized: return .minimized
            case .fullscreen: return .fullscreen
            case .eligible(let liveTitle):
                let title = String(liveTitle.prefix(Self.maxTitleChars))
                guard var pool = remainingByBundle[bundleID], !pool.isEmpty else {
                    return .noRemainingSaved
                }
                // Preserve exact-title priority and the saved-empty-title privacy fallback.
                let index = pool.firstIndex { !$0.windowTitle.isEmpty && $0.windowTitle == title }
                    ?? pool.firstIndex { $0.windowTitle.isEmpty }
                guard let index else { return .titleMismatch }
                let snapshot = pool.remove(at: index)
                remainingByBundle[bundleID] = pool
                return .matched(snapshot)
            }
        }
    }
}
