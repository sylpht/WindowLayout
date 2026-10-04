import Foundation
import CoreGraphics

// Pure fixtures only: no AppKit screen queries, AX calls, or user settings.
enum Log {
    static func info(_ message: String) {}
    static func warn(_ message: String) {}
    static func error(_ message: String) {}
}
enum L { static func s(_ ru: String, _ en: String, _ zh: String? = nil) -> String { en } }

@main
struct DisplayPlacementTests {
    static let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

    static func identity(_ n: Int, serial: UInt32? = nil) -> DisplayIdentity {
        DisplayIdentity(uuid: String(format: "00000000-0000-0000-0000-%012d", n),
                        vendor: 1, model: 2, serial: serial ?? UInt32(n), isBuiltin: false)
    }

    static func snapshot(_ frame: CGRect, index: Int, layout: DisplayLayout) -> WindowSnapshot {
        WindowSnapshot(bundleID: "test", windowTitle: "", frame: frame,
                       normalizedFrame: Geometry.normalize(frame, in: layout.axFrames[index]), screenIndex: index)
    }

    static func profile(_ snapshot: WindowSnapshot, layout: DisplayLayout) -> LayoutProfile {
        LayoutProfile(id: UUID(), displaySignature: "test", name: "test", capturedAt: Date(timeIntervalSince1970: 1000),
                      windows: [snapshot], screenFrames: layout.appKitFrames,
                      placementVersion: LayoutProfile.currentPlacementVersion, displayIdentities: layout.identities)
    }

    static func fails(_ result: Result<DisplayPlacement.Target, DisplayPlacement.Failure>,
                      with reason: DisplayPlacement.Failure) -> Bool {
        if case .failure(let error) = result { return error.rawValue == reason.rawValue }
        return false
    }

    static func main() {
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Bool) {
            do {
                if try body() { passed += 1; print("PASS \(name)") }
                else { failed += 1; print("FAIL \(name)") }
            } catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        let directions: [(String, CGRect, CGRect, CGRect)] = [
            ("above", CGRect(x: 0, y: 900, width: 1920, height: 1080),
             CGRect(x: 0, y: -1080, width: 1920, height: 1080), CGRect(x: 100, y: -980, width: 800, height: 600)),
            ("below", CGRect(x: 0, y: -1080, width: 1920, height: 1080),
             CGRect(x: 0, y: 900, width: 1920, height: 1080), CGRect(x: 100, y: 1000, width: 800, height: 600)),
            ("left taller", CGRect(x: -1920, y: 0, width: 1920, height: 1080),
             CGRect(x: -1920, y: -180, width: 1920, height: 1080), CGRect(x: -1820, y: -160, width: 800, height: 100)),
            ("right shorter", CGRect(x: 1440, y: 0, width: 1920, height: 600),
             CGRect(x: 1440, y: 300, width: 1920, height: 600), CGRect(x: 1540, y: 750, width: 800, height: 100))
        ]
        for (name, appKit, expectedAX, window) in directions {
            test("\(name): capture selection and restore clamp use the same AX coordinates") {
                let layout = DisplayLayout(appKitFrames: [primary, appKit], identities: [identity(1), identity(2)])
                guard layout.axFrames == [primary, expectedAX], Geometry.screenIndex(for: window, in: layout.axFrames) == 1 else { return false }
                let saved = snapshot(window, index: 1, layout: layout)
                let restored = try DisplayPlacement.target(snapshot: saved, profile: profile(saved, layout: layout), current: layout).get()
                return restored.screenIndex == 1 && restored.frame == window
            }
        }
        test("conversion uses the primary maxY even when another screen is taller") {
            let upper = CGRect(x: 0, y: 900, width: 1920, height: 2160)
            let layout = DisplayLayout(appKitFrames: [primary, upper], identities: [identity(1), identity(2)])
            return layout.axFrames[1].minY == -2160 && layout.axFrames[0].minY == 0
        }
        test("offscreen capture has no guessed source display") {
            Geometry.screenIndex(for: CGRect(x: 9000, y: 9000, width: 100, height: 100), in: [primary]) == nil
        }
        let above = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let three = DisplayLayout(appKitFrames: [primary, above, right], identities: [identity(1), identity(2), identity(3)])
        let saved = snapshot(CGRect(x: 100, y: -980, width: 800, height: 600), index: 1, layout: three)
        let savedProfile = profile(saved, layout: three)
        test("screen array reorder preserves the physical target") {
            let current = DisplayLayout(appKitFrames: [primary, right, above], identities: [identity(1), identity(3), identity(2)])
            let restored = try DisplayPlacement.target(snapshot: saved, profile: savedProfile, current: current).get()
            return restored.screenIndex == 2 && restored.frame == saved.frame
        }
        test("a monitor moved from above to the left keeps its relative window position") {
            let current = DisplayLayout(appKitFrames: [primary, CGRect(x: -1920, y: 0, width: 1920, height: 1080), right],
                                        identities: three.identities)
            let restored = try DisplayPlacement.target(snapshot: saved, profile: savedProfile, current: current).get()
            return restored.frame == CGRect(x: -1820, y: -80, width: 800, height: 600)
        }
        test("changing primary display shifts both source and target origins correctly") {
            let old = DisplayLayout(appKitFrames: [primary, right], identities: [identity(1), identity(2)])
            let current = DisplayLayout(appKitFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                                      CGRect(x: -1440, y: 0, width: 1440, height: 900)],
                                        identities: [identity(2), identity(1)])
            let windows = [CGRect(x: 100, y: 100, width: 800, height: 600), CGRect(x: 1540, y: -80, width: 800, height: 600)]
            let expected = [CGRect(x: -1340, y: 280, width: 800, height: 600), CGRect(x: 100, y: 100, width: 800, height: 600)]
            for index in windows.indices {
                let window = snapshot(windows[index], index: index, layout: old)
                let restored = try DisplayPlacement.target(snapshot: window, profile: profile(window, layout: old), current: current).get()
                guard restored.frame == expected[index] else { return false }
            }
            return true
        }
        test("no current displays produces no placement") {
            fails(DisplayPlacement.target(snapshot: saved, profile: savedProfile,
                current: DisplayLayout(appKitFrames: [], identities: [])), with: .noScreens)
        }
        test("a missing physical display does not fall back to its old array index") {
            let current = DisplayLayout(appKitFrames: [primary, right], identities: [identity(1), identity(3)])
            return fails(DisplayPlacement.target(snapshot: saved, profile: savedProfile, current: current), with: .displayMissing)
        }
        test("unique hardware serial survives a changed UUID") {
            let current = DisplayLayout(appKitFrames: three.appKitFrames, identities: [identity(1), identity(8, serial: 2), identity(3)])
            let restored = try DisplayPlacement.target(snapshot: saved, profile: savedProfile, current: current).get()
            return restored.screenIndex == 1 && restored.method == "hardwareSerial"
        }
        test("a lone serial-zero display can use its nonzero UUID") {
            let layout = DisplayLayout(appKitFrames: [primary], identities: [identity(1, serial: 0)])
            let window = snapshot(CGRect(x: 100, y: 100, width: 800, height: 600), index: 0, layout: layout)
            return try DisplayPlacement.target(snapshot: window, profile: profile(window, layout: layout), current: layout).get().method == "displayUUID"
        }
        test("zero UUID with no serial remains unresolved") {
            let layout = DisplayLayout(appKitFrames: [primary], identities: [identity(0, serial: 0)])
            let window = snapshot(CGRect(x: 100, y: 100, width: 800, height: 600), index: 0, layout: layout)
            return fails(DisplayPlacement.target(snapshot: window, profile: profile(window, layout: layout), current: layout), with: .unavailableIdentity)
        }
        test("nil identity remains unresolved") {
            let layout = DisplayLayout(appKitFrames: [primary], identities: [nil])
            let window = snapshot(CGRect(x: 100, y: 100, width: 800, height: 600), index: 0, layout: layout)
            return fails(DisplayPlacement.target(snapshot: window, profile: profile(window, layout: layout), current: layout), with: .unavailableIdentity)
        }
        for sameUUID in [false, true] {
            test("identical serial-zero displays are ambiguous even with \(sameUUID ? "duplicate" : "distinct") UUIDs") {
                let layout = DisplayLayout(appKitFrames: [primary, right],
                    identities: [identity(1, serial: 0), identity(sameUUID ? 1 : 2, serial: 0)])
                let window = snapshot(CGRect(x: 100, y: 100, width: 800, height: 600), index: 0, layout: layout)
                return fails(DisplayPlacement.target(snapshot: window, profile: profile(window, layout: layout), current: layout), with: .ambiguousIdentity)
            }
        }
        test("duplicate nonzero hardware serials are not treated as unique physical displays") {
            let layout = DisplayLayout(appKitFrames: [primary, right], identities: [identity(1, serial: 9), identity(2, serial: 9)])
            let window = snapshot(CGRect(x: 100, y: 100, width: 800, height: 600), index: 0, layout: layout)
            return fails(DisplayPlacement.target(snapshot: window, profile: profile(window, layout: layout), current: layout), with: .ambiguousIdentity)
        }
        test("legacy raw AX frame repairs old screenIndex and normalized y") {
            let wrong = WindowSnapshot(bundleID: "test", windowTitle: "", frame: saved.frame,
                                       normalizedFrame: CGRect(x: 99, y: 99, width: 99, height: 99), screenIndex: 0)
            var old = profile(wrong, layout: three)
            old.placementVersion = nil; old.displayIdentities = nil
            let reordered = DisplayLayout(appKitFrames: [primary, right, above], identities: [identity(1), identity(3), identity(2)])
            let restored = try DisplayPlacement.target(snapshot: wrong, profile: old, current: reordered).get()
            return restored.frame == saved.frame && restored.screenIndex == 2 && restored.method.contains("resaveRecommended")
        }
        test("legacy changed topology is unresolved rather than guessed by index") {
            var old = savedProfile
            old.placementVersion = nil; old.displayIdentities = nil
            let current = DisplayLayout(appKitFrames: [primary, right], identities: [identity(1), identity(2)])
            return fails(DisplayPlacement.target(snapshot: saved, profile: old, current: current), with: .legacyTopologyChanged)
        }
        test("legacy JSON without new fields still decodes") {
            let json = """
            [{"id":"\(UUID().uuidString)","displaySignature":"old","name":"Old","capturedAt":"2026-01-01T00:00:00Z","windows":[],"screenFrames":[]}]
            """
            let decoded = try iCloudSync.makeDecoder().decode([LayoutProfile].self, from: Data(json.utf8))
            try ProfileFileStore.validate(decoded)
            return decoded[0].placementVersion == nil && decoded[0].displayIdentities == nil
        }
        test("new placement metadata survives a JSON roundtrip") {
            let decoded = try iCloudSync.makeDecoder().decode(LayoutProfile.self, from: iCloudSync.makeEncoder().encode(savedProfile))
            try ProfileFileStore.validate([decoded])
            return decoded.placementVersion == 1 && decoded.displayIdentities == three.identities
                && decoded.screenFrames == three.appKitFrames && decoded.windows[0].normalizedFrame == saved.normalizedFrame
        }
        test("unsupported or misaligned placement metadata is rejected") {
            var future = savedProfile; future.placementVersion = 99
            var misaligned = savedProfile; misaligned.displayIdentities = [identity(1)]
            var orphaned = savedProfile; orphaned.placementVersion = nil
            for invalid in [future, misaligned, orphaned] {
                do { try ProfileFileStore.validate([invalid]); return false } catch {}
            }
            return fails(DisplayPlacement.target(snapshot: saved, profile: future, current: three), with: .unsupportedVersion)
        }
        test("new source index must be within the saved frame array") {
            let invalid = WindowSnapshot(bundleID: "test", windowTitle: "", frame: saved.frame, normalizedFrame: .zero, screenIndex: 9)
            let invalidProfile = profile(invalid, layout: three)
            do { try ProfileFileStore.validate([invalidProfile]); return false } catch {}
            return fails(DisplayPlacement.target(snapshot: invalid, profile: invalidProfile, current: three), with: .invalidSavedScreen)
        }
        test("new metadata rejects zero-sized screens and overflowing bounds") {
            let invalidFrames = [CGRect.zero, CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                                                     width: CGFloat.greatestFiniteMagnitude, height: 100)]
            for frame in invalidFrames {
                let layout = DisplayLayout(appKitFrames: [frame], identities: [identity(1)])
                let window = WindowSnapshot(bundleID: "test", windowTitle: "", frame: primary,
                                            normalizedFrame: .zero, screenIndex: 0)
                do { try ProfileFileStore.validate([profile(window, layout: layout)]); return false } catch {}
            }
            return true
        }
        print("Display placement: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
