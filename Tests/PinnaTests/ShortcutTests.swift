import AppKit
import Carbon.HIToolbox
import Testing
@testable import Pinna

struct ShortcutTests {
    @Test func needsAModifierUnlessItsAFunctionKey() {
        #expect(Shortcut(keyCode: kVK_ANSI_2, modifiers: [.shift, .command]).isValid)
        #expect(Shortcut(keyCode: kVK_ANSI_2, modifiers: [.option]).isValid)
        #expect(!Shortcut(keyCode: kVK_ANSI_2, modifiers: [.shift]).isValid)
        #expect(!Shortcut(keyCode: kVK_ANSI_2, modifiers: []).isValid)
        #expect(Shortcut(keyCode: kVK_F5, modifiers: []).isValid)
    }

    @Test func describesKeysTheWayMacOSDoes() {
        #expect(Shortcut(keyCode: kVK_F12, modifiers: [.command, .control]).description == "⌃⌘F12")
        #expect(Shortcut(keyCode: kVK_Space, modifiers: [.option]).description == "⌥Space")
        #expect(Shortcut(keyCode: kVK_LeftArrow, modifiers: [.shift, .control, .option, .command]).description == "⌃⌥⇧⌘←")
    }

    @Test func ignoresOtherModifierFlags() {
        let shortcut = Shortcut(keyCode: kVK_ANSI_A, modifiers: [.command, .capsLock, .numericPad])
        #expect(shortcut == Shortcut(keyCode: kVK_ANSI_A, modifiers: [.command]))
    }

    @Test func carbonModifiers() {
        let shortcut = Shortcut(keyCode: kVK_ANSI_A, modifiers: [.shift, .command])
        #expect(shortcut.carbonModifiers == shiftKey | cmdKey)
    }

    @Test func survivesEncoding() throws {
        let shortcut = Shortcut(keyCode: kVK_ANSI_K, modifiers: [.control, .option])
        let decoded = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(shortcut))
        #expect(decoded == shortcut)
    }

    @Test func onlyCaptureHasADefault() {
        #expect(ShortcutAction.capture.defaultShortcut == Shortcut(keyCode: kVK_ANSI_2, modifiers: [.shift, .command]))
        #expect(ShortcutAction.allCases.filter { $0.defaultShortcut != nil } == [.capture])
    }
}
