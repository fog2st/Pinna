import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut. Carbon's RegisterEventHotKey needs no Accessibility permission.
@MainActor
final class HotKey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x5049_4E41), id: 1) // 'PINA'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("Pinna: couldn't register the global shortcut (error \(status))")
        }
    }

    fileprivate func fire() {
        action()
    }
}

private func hotKeyHandler(_: EventHandlerCallRef?, _: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
    // Carbon delivers hot key events on the main thread.
    MainActor.assumeIsolated { hotKey.fire() }
    return noErr
}
