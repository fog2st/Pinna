import AppKit
import Carbon.HIToolbox

/// A key plus modifiers that works from any app, like ⇧⌘2.
struct Shortcut: Equatable, Codable {
    let keyCode: Int
    private let modifierFlags: UInt

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        modifierFlags = modifiers.intersection([.control, .option, .shift, .command]).rawValue
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    /// Sits next to the system's ⇧⌘3/4/5 screenshot shortcuts.
    static let `default` = Shortcut(keyCode: kVK_ANSI_2, modifiers: [.shift, .command])

    /// The Capture & Pin shortcut, as saved in Settings.
    static var capture: Shortcut {
        get {
            UserDefaults.standard.data(forKey: "CaptureShortcut")
                .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "CaptureShortcut")
        }
    }

    /// Plain keys would get in the way of typing, so a shortcut needs ⌘, ⌥ or ⌃, unless it's an F-key.
    var isValid: Bool {
        !modifiers.isDisjoint(with: [.command, .option, .control]) || Self.functionKeys.contains(keyCode)
    }

    var carbonModifiers: Int {
        var flags = 0
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.command) { flags |= cmdKey }
        return flags
    }

    /// Like "⇧⌘2".
    var description: String {
        let key = if let index = Self.functionKeys.firstIndex(of: keyCode) {
            "F\(index + 1)"
        } else if let special = Self.specialKeys[keyCode] {
            special.name
        } else {
            Self.character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
        }
        return Self.symbols(for: modifiers) + key
    }

    /// The key as `NSMenuItem.keyEquivalent` wants it, to go with `modifiers`.
    var keyEquivalent: String {
        if let index = Self.functionKeys.firstIndex(of: keyCode) {
            return Self.string(NSF1FunctionKey + index)
        } else if let special = Self.specialKeys[keyCode] {
            return Self.string(special.equivalent)
        }
        return Self.character(for: keyCode) ?? ""
    }

    /// Like "⌃⌥⇧⌘", in the order macOS shows them.
    static func symbols(for modifiers: NSEvent.ModifierFlags) -> String {
        let all: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return all.filter { modifiers.contains($0.0) }.map(\.1).joined()
    }

    // MARK: Key names

    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// Keys that don't type a character: how to show them, and their menu key equivalent.
    private static let specialKeys: [Int: (name: String, equivalent: Int)] = [
        kVK_Space: ("Space", 0x20), kVK_Return: ("↩", 0x0D), kVK_ANSI_KeypadEnter: ("⌤", 0x03),
        kVK_Tab: ("⇥", 0x09), kVK_Delete: ("⌫", 0x08), kVK_ForwardDelete: ("⌦", NSDeleteFunctionKey),
        kVK_Escape: ("⎋", 0x1B), kVK_Home: ("↖", NSHomeFunctionKey), kVK_End: ("↘", NSEndFunctionKey),
        kVK_PageUp: ("⇞", NSPageUpFunctionKey), kVK_PageDown: ("⇟", NSPageDownFunctionKey),
        kVK_LeftArrow: ("←", NSLeftArrowFunctionKey), kVK_RightArrow: ("→", NSRightArrowFunctionKey),
        kVK_UpArrow: ("↑", NSUpArrowFunctionKey), kVK_DownArrow: ("↓", NSDownArrowFunctionKey),
    ]

    private static func string(_ code: Int) -> String {
        Unicode.Scalar(code).map { String(Character($0)) } ?? ""
    }

    /// What the key types on the current keyboard layout, without modifiers.
    private static func character(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { bytes in
            UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode),
                           UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                           &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
