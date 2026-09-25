import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey — works system-wide with no
/// accessibility permission, so recording can be toggled mid-meeting from any app.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    struct ID {
        static let toggleRecording: UInt32 = 1
        static let keyMoment: UInt32 = 2
        static let pause: UInt32 = 3
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var handlerInstalled = false

    private init() {}

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E54_4B52) /* 'NTKR' */, id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }

    fileprivate func dispatch(id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID)
            DispatchQueue.main.async {
                HotKeyCenter.shared.dispatch(id: hotKeyID.id)
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
