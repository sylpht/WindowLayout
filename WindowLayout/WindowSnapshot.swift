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
    static let currentPlacementVersion = 1
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
    /// Version 1 normalizes windows against AX (top-left) screen coordinates.
    /// screenFrames remain AppKit rectangles, in primary-first capture order.
    var placementVersion: Int? = nil
    /// Aligned with screenFrames. Nil entries mean identity could not be obtained.
    var displayIdentities: [DisplayIdentity?]? = nil

    /// Effective revision time used for merge ordering.
    var revisionTime: Date { max(capturedAt, modifiedAt ?? capturedAt) }
}

struct DisplayIdentity: Codable, Equatable {
    let uuid: String?
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let isBuiltin: Bool

    var validUUID: String? {
        guard let uuid, let parsed = UUID(uuidString: uuid),
              parsed.uuidString != "00000000-0000-0000-0000-000000000000" else { return nil }
        return parsed.uuidString
    }

    var hardwareKey: String { "\(vendor):\(model):\(serial):\(isBuiltin)" }
    var modelKey: String { "\(vendor):\(model):\(isBuiltin)" }
}
