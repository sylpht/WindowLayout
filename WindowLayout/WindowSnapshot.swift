import Foundation
import CoreGraphics

struct WindowSnapshot: Codable {
    let bundleID: String
    let windowTitle: String
    let frame: CGRect
    let normalizedFrame: CGRect
    let screenIndex: Int
}

struct LayoutProfile: Codable, Identifiable {
    /// Identity — never mutated after creation. `let` enforces this so a
    /// stray `=` assignment can't break sync (which keys everything on id).
    let id: UUID
    let displaySignature: String
    var name: String
    let capturedAt: Date
    var windows: [WindowSnapshot]
    let screenFrames: [CGRect]
    /// Nil/false = user-saved. True = background snapshot created on disconnect.
    /// Auto-snapshots are hidden from the UI but used by auto-restore as a fallback.
    var isAutoSnapshot: Bool? = nil
    /// Tombstone for iCloud sync: when set, this profile is hidden from UI but kept on disk
    /// so the deletion propagates to other Macs. Garbage-collected after 30 days.
    var deletedAt: Date? = nil
    /// Last modification (rename, etc.) for iCloud merge tie-break. nil = never modified
    /// since capture. Merge picks max(capturedAt, modifiedAt) when comparing two copies.
    var modifiedAt: Date? = nil

    /// Effective revision time used for merge ordering.
    var revisionTime: Date { max(capturedAt, modifiedAt ?? capturedAt) }
}
