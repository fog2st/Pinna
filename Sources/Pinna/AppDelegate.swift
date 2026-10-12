import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private let capturer = Capturer()
    private var pins: [PinWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinna")
        item.menu = makeMenu()
        statusItem = item

        // ⇧⌘2 — sits next to the system's ⇧⌘3/4/5 screenshot shortcuts.
        hotKey = HotKey(keyCode: kVK_ANSI_2, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.captureAndPin()
        }

        // Shows the system prompt if the user hasn't decided yet, and lists Pinna in System Settings.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let capture = NSMenuItem(title: "Capture & Pin", action: #selector(captureAndPin), keyEquivalent: "2")
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        menu.addItem(capture)
        menu.addItem(withTitle: "Close All Pins", action: #selector(closeAllPins), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pinna", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc func captureAndPin() {
        guard hasScreenRecordingPermission() else { return }
        Task {
            guard let (screenshot, frame) = await capturer.capture() else { return }
            screenshot.copyToPasteboard()
            pin(screenshot, frame: frame ?? defaultFrame(for: screenshot.image.size))
        }
    }

    @objc func closeAllPins() {
        pins.forEach { $0.close() }
    }

    private func pin(_ screenshot: Screenshot, frame: NSRect) {
        let window = PinWindow(screenshot: screenshot, frame: frame)
        window.onClose = { [weak self] closed in
            self?.pins.removeAll { $0 === closed }
        }
        pins.append(window)
        window.orderFrontRegardless() // show without stealing focus from the current app
    }

    /// Centers the pin on the mouse, kept inside that screen.
    private func defaultFrame(for size: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        var frame = NSRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height)
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - size.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - size.height))
        return frame
    }

    private func hasScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }

        let alert = NSAlert()
        alert.messageText = "Pinna needs Screen Recording permission"
        alert.informativeText = "Turn on Pinna in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen Pinna."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}
