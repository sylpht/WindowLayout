import AppKit
import CoreFoundation
import CoreGraphics

/// Stage Manager / Mission Control state. macOS 13+ Stage Manager auto-arranges windows
/// in a sidebar group; restoring window positions while it's active fights the OS.
enum WindowEnvironment {
    /// True if Stage Manager is enabled system-wide.
    /// Read via `CFPreferencesCopyAppValue` from `com.apple.WindowManager` → `GloballyEnabled`.
    /// `UserDefaults(suiteName:)` returns nil on some macOS versions for system-wide domains;
    /// CFPreferences is the documented Apple way to read another app's prefs.
    static var isStageManagerActive: Bool {
        let key = "GloballyEnabled" as CFString
        let domain = "com.apple.WindowManager" as CFString
        let value = CFPreferencesCopyAppValue(key, domain) as? NSNumber
        return value?.boolValue ?? false
    }
}

struct DisplayConfiguration {
    /// Canonical signature — vendor:model:serial:WxH per display, position-independent.
    /// Stable across monitor reordering in System Settings; identifies the same display
    /// even if it's plugged into a different USB-C port.
    let signature: String

    /// v1.0-format signature (serial:model:WxH@x,y). Kept for backward-compat lookup
    /// so existing user profiles saved under v1.0 still match.
    let legacySignature: String

    /// All sigs that should be considered equivalent for profile lookup.
    /// Deduped — for some setups (e.g. zero-ID built-in displays) canonical and legacy
    /// can be identical, in which case we don't return the same string twice.
    var matchingSignatures: [String] {
        signature == legacySignature ? [signature] : [signature, legacySignature]
    }

    static func current() -> DisplayConfiguration {
        let key = NSDeviceDescriptionKey("NSScreenNumber")

        let canonical = NSScreen.screens.compactMap { screen -> String? in
            guard let cgID = screen.deviceDescription[key] as? CGDirectDisplayID else { return nil }
            let vendor = CGDisplayVendorNumber(cgID)
            let model = CGDisplayModelNumber(cgID)
            let serial = CGDisplaySerialNumber(cgID)
            let isBuiltin = CGDisplayIsBuiltin(cgID) != 0
            let w = Int(screen.frame.width)
            let h = Int(screen.frame.height)
            // Built-in MacBook displays often report vendor=0, model=0, serial=0.
            // Use a stable "builtin:WxH" marker for them.
            if isBuiltin && vendor == 0 && model == 0 && serial == 0 {
                return "builtin:\(w)x\(h)"
            }
            return "\(vendor):\(model):\(serial):\(w)x\(h)"
        }.sorted()

        let legacy = NSScreen.screens.compactMap { screen -> String? in
            guard let cgID = screen.deviceDescription[key] as? CGDirectDisplayID else { return nil }
            let serial = CGDisplaySerialNumber(cgID)
            let model = CGDisplayModelNumber(cgID)
            let w = Int(screen.frame.width)
            let h = Int(screen.frame.height)
            let x = Int(screen.frame.origin.x)
            let y = Int(screen.frame.origin.y)
            return "\(serial):\(model):\(w)x\(h)@\(x),\(y)"
        }.sorted()

        return DisplayConfiguration(
            signature: canonical.joined(separator: "|"),
            legacySignature: legacy.joined(separator: "|")
        )
    }

    static func friendlyName() -> String {
        let screens = NSScreen.screens
        let key = NSDeviceDescriptionKey("NSScreenNumber")

        switch screens.count {
        case 0: return L.s("Нет дисплеев", "No displays", "无显示器")
        case 1: return screens[0].localizedName
        case 2:
            var builtin: NSScreen?
            var external: NSScreen?
            for s in screens {
                guard let id = s.deviceDescription[key] as? CGDirectDisplayID else { continue }
                if CGDisplayIsBuiltin(id) != 0 { builtin = s }
                else { external = s }
            }
            if let b = builtin, let e = external {
                return "\(b.localizedName) + \(e.localizedName)"
            }
            return screens.map(\.localizedName).joined(separator: " + ")
        default:
            return L.displaysCount(screens.count)
        }
    }
}
