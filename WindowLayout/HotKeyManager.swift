import AppKit
import Carbon.HIToolbox

/// Thin wrapper around the Carbon `RegisterEventHotKey` API for app-global
/// keyboard shortcuts. Carbon is deprecated but still works and is the only
/// sanctioned way to do this without Accessibility for input-capture.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandlerInstalled = false

    private init() {}

    /// Register a hotkey. `keyCode` is a Carbon/virtual key code (e.g. `kVK_ANSI_S`).
    /// `modifiers` combines `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32 {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: fourCharCode("WLAP"), id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            // Most common: another app already owns this combo (status -9878 = eventHotKeyExistsErr).
            Log.error("RegisterEventHotKey failed (status=\(status)) for keyCode=\(keyCode) modifiers=\(modifiers) — likely already taken by another app")
            return 0
        }

        handlers[id] = handler
        refs[id] = ref
        return id
    }

    func unregister(id: UInt32) {
        if let ref = refs[id] {
            UnregisterEventHotKey(ref)
            refs.removeValue(forKey: id)
        }
        handlers.removeValue(forKey: id)
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return err }

                let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                if let h = mgr.handlers[hotKeyID.id] {
                    DispatchQueue.main.async { h() }
                }
                return noErr
            },
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }

    private func fourCharCode(_ s: String) -> OSType {
        var result: OSType = 0
        for byte in s.utf8.prefix(4) {
            result = (result << 8) | OSType(byte)
        }
        return result
    }
}
