import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var captureItem: NSMenuItem?
    private var hotKey: HotKey?
    private lazy var settingsWindow = makeSettingsWindow()
    private let capturer = Capturer()
    private var pins: [PinWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinna")
        item.menu = makeMenu()
        statusItem = item

        hotKey = HotKey { [weak self] in
            self?.captureAndPin()
        }
        hotKey?.register(Shortcut.capture)

        // Shows the system prompt if the user hasn't decided yet, and lists Pinna in System Settings.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let capture = NSMenuItem(title: "Capture & Pin", action: #selector(captureAndPin), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        captureItem = capture
        showShortcutInMenu()
        menu.addItem(withTitle: "Close All Pins", action: #selector(closeAllPins), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Pinna", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func showShortcutInMenu() {
        captureItem?.keyEquivalent = Shortcut.capture.keyEquivalent
        captureItem?.keyEquivalentModifierMask = Shortcut.capture.modifiers
    }

    private func makeSettingsWindow() -> SettingsWindow {
        let window = SettingsWindow(shortcut: Shortcut.capture)
        // Pause the shortcut while a new one is typed, so pressing it doesn't take a screenshot.
        window.onRecordingChange = { [weak self] isRecording in
            self?.hotKey?.register(isRecording ? nil : Shortcut.capture)
        }
        window.onChange = { [weak self] shortcut in
            self?.setCaptureShortcut(shortcut) ?? false
        }
        return window
    }

    private func setCaptureShortcut(_ shortcut: Shortcut) -> Bool {
        guard hotKey?.register(shortcut) == true else {
            hotKey?.register(Shortcut.capture)
            return false
        }
        Shortcut.capture = shortcut
        showShortcutInMenu()
        return true
    }

    @objc func showSettings() {
        NSApp.activate()
        settingsWindow.makeKeyAndOrderFront(nil)
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
