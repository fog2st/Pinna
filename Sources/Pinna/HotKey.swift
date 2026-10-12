import Carbon.HIToolbox
import Foundation

/// System-wide keyboard shortcuts. Carbon's RegisterEventHotKey needs no Accessibility permission.
@MainActor
final class HotKeyCenter {
    private let action: (ShortcutAction) -> Void
    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    init(action: @escaping (ShortcutAction) -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Registers every action's saved shortcut.
    func registerAll() {
        for action in ShortcutAction.allCases {
            register(action.shortcut, for: action)
        }
    }

    /// Turns every shortcut off, while a new one is typed in Settings.
    func unregisterAll() {
        for action in ShortcutAction.allCases {
            register(nil, for: action)
        }
    }

    /// Replaces the action's shortcut, or just removes it if `shortcut` is nil. Returns false if it couldn't be registered.
    @discardableResult
    func register(_ shortcut: Shortcut?, for action: ShortcutAction) -> Bool {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
        guard let shortcut else { return true }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5049_4E41), id: Self.id(for: action)) // 'PINA'
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.carbonModifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Pinna: couldn't register the global shortcut \(shortcut.description) (error \(status))")
            return false
        }
        hotKeyRefs[action] = ref
        return true
    }

    private static func id(for action: ShortcutAction) -> UInt32 {
        UInt32(ShortcutAction.allCases.firstIndex(of: action)! + 1)
    }

    fileprivate func fire(id: UInt32) {
        guard let action = ShortcutAction.allCases.first(where: { Self.id(for: $0) == id }) else { return }
        self.action(action)
    }
}

private func hotKeyHandler(_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    // Carbon delivers hot key events on the main thread.
    MainActor.assumeIsolated { center.fire(id: hotKeyID.id) }
    return noErr
}
