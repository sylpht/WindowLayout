import Foundation
import CoreGraphics

/// One primary-first screen snapshot. All geometry passed to AX stays in points.
struct DisplayLayout {
    let appKitFrames: [CGRect]
    let identities: [DisplayIdentity?]

    var axFrames: [CGRect] {
        guard let primary = appKitFrames.first else { return [] }
        return appKitFrames.map { Geometry.axFrame(fromAppKit: $0, primaryMaxY: primary.maxY) }
    }
}

enum DisplayPlacement {
    static let currentVersion = LayoutProfile.currentPlacementVersion

    struct Target {
        let frame: CGRect
        let screenIndex: Int
        let method: String
    }

    enum Failure: String, Error {
        case noScreens, unsupportedVersion, invalidSavedScreen, unavailableIdentity
        case ambiguousIdentity, displayMissing, legacyTopologyChanged, legacySourceUnavailable
    }

    static func target(snapshot: WindowSnapshot, profile: LayoutProfile,
                       current: DisplayLayout) -> Result<Target, Failure> {
        let screens = current.axFrames
        guard !screens.isEmpty else { return .failure(.noScreens) }
        guard let version = profile.placementVersion else {
            return legacyTarget(snapshot: snapshot, profile: profile, current: current)
        }
        guard version == currentVersion else { return .failure(.unsupportedVersion) }
        guard let saved = profile.displayIdentities, saved.count == profile.screenFrames.count,
              current.identities.count == screens.count, saved.indices.contains(snapshot.screenIndex) else {
            return .failure(.invalidSavedScreen)
        }
        switch resolve(savedIndex: snapshot.screenIndex, saved: saved, current: current.identities) {
        case .failure(let failure): return .failure(failure)
        case .success(let match):
            let target = Geometry.denormalize(snapshot.normalizedFrame, in: screens[match.index])
            return .success(Target(frame: Geometry.clamp(target, into: screens[match.index]),
                                   screenIndex: match.index, method: match.method))
        }
    }

    private struct Match { let index: Int; let method: String }

    private static func resolve(savedIndex: Int, saved: [DisplayIdentity?],
                                current: [DisplayIdentity?]) -> Result<Match, Failure> {
        guard let identity = saved[savedIndex] else { return .failure(.unavailableIdentity) }
        let savedKnown = saved.compactMap { $0 }, currentKnown = current.compactMap { $0 }
        // Identical units without unique serials can get connector-dependent UUIDs.
        // Never call a swap between those units an exact physical-display match.
        let ambiguous = { (item: DisplayIdentity, collection: [DisplayIdentity]) in
            collection.filter { $0.hardwareKey == item.hardwareKey }.count > 1
                || (item.serial == 0 && collection.filter { $0.serial == 0 && $0.modelKey == item.modelKey }.count > 1)
        }
        guard !ambiguous(identity, savedKnown), !ambiguous(identity, currentKnown) else {
            return .failure(.ambiguousIdentity)
        }
        if identity.serial != 0 {
            let matches = current.indices.filter { current[$0]?.hardwareKey == identity.hardwareKey }
            if matches.count == 1 { return .success(Match(index: matches[0], method: "hardwareSerial")) }
            if matches.count > 1 { return .failure(.ambiguousIdentity) }
        }
        guard let uuid = identity.validUUID else { return .failure(.unavailableIdentity) }
        guard savedKnown.filter({ $0.validUUID == uuid }).count == 1 else { return .failure(.ambiguousIdentity) }
        let matches = current.indices.filter { current[$0]?.validUUID == uuid }
        guard matches.count <= 1 else { return .failure(.ambiguousIdentity) }
        if let index = matches.first, let candidate = current[index] {
            guard candidate.hardwareKey == identity.hardwareKey else { return .failure(.displayMissing) }
            return .success(Match(index: index, method: "displayUUID"))
        }
        // A connector-dependent UUID may change after reconnect. A sole serial-zero
        // model is a best-available inference, not proof of the same physical unit:
        // replacing it with another unit of the same model cannot be distinguished.
        guard identity.serial == 0,
              savedKnown.filter({ $0.serial == 0 && $0.modelKey == identity.modelKey }).count == 1 else {
            return .failure(.displayMissing)
        }
        let modelMatches = current.indices.filter {
            current[$0]?.serial == 0 && current[$0]?.modelKey == identity.modelKey
        }
        guard modelMatches.count == 1, let candidate = current[modelMatches[0]] else { return .failure(.displayMissing) }
        guard let currentUUID = candidate.validUUID else { return .failure(.unavailableIdentity) }
        guard currentKnown.filter({ $0.validUUID == currentUUID }).count == 1 else { return .failure(.ambiguousIdentity) }
        return .success(Match(index: modelMatches[0], method: "uniqueModelFallback"))
    }

    private static func legacyTarget(snapshot: WindowSnapshot, profile: LayoutProfile,
                                     current: DisplayLayout) -> Result<Target, Failure> {
        guard let primary = profile.screenFrames.first else { return .failure(.legacySourceUnavailable) }
        let oldScreens = profile.screenFrames.map { Geometry.axFrame(fromAppKit: $0, primaryMaxY: primary.maxY) }
        // Old screenIndex and normalizedFrame may already be wrong because capture
        // compared an AX window against AppKit screens. Recover from the raw AX frame.
        guard let oldIndex = Geometry.screenIndex(for: snapshot.frame, in: oldScreens) else {
            return .failure(.legacySourceUnavailable)
        }
        let source = oldScreens[oldIndex]
        let screens = current.axFrames
        let matches = screens.indices.filter { screens[$0] == source }
        guard matches.count == 1 else { return .failure(.legacyTopologyChanged) }
        let index = matches[0]
        let normalized = Geometry.normalize(snapshot.frame, in: source)
        let target = Geometry.denormalize(normalized, in: screens[index])
        return .success(Target(frame: Geometry.clamp(target, into: screens[index]),
                               screenIndex: index, method: "legacyGeometry-resaveRecommended"))
    }
}
