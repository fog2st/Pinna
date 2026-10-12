import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private var statusItem: NSStatusItem?
    private var hotKeys: HotKeyCenter?
    private lazy var settingsWindow = makeSettingsWindow()
    private let capturer = Capturer()
    private let pins = PinManager()

    // Before any files opened with Pinna are pinned, since new pins take their settings from these.
    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinna")
        item.button?.toolTip = String(localized: "Pinna: drop an image here to pin it")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        // Images dropped on the icon are pinned. The status bar window passes drags on to its delegate.
        item.button?.window?.registerForDraggedTypes([.fileURL, .png, .tiff])
        item.button?.window?.delegate = self
        statusItem = item

        hotKeys = HotKeyCenter { [weak self] action in
            self?.perform(action)
        }
        hotKeys?.registerAll()

        pins.restoreSavedPins()

        // Shows the system prompt if the user hasn't decided yet, and lists Pinna in System Settings.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pins.saveAndWait()
        Screenshot.settlePasteboard()
    }

    /// Images opened with Pinna, from Finder's Open With or dropped on its icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        pinImages(at: urls)
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .capture: capture(fromMenu: false)
        case .captureAgain: captureAgain(fromMenu: false)
        case .pinClipboard: pinClipboard()
        case .togglePins: pins.toggleVisibility()
        case .reopenClosed: pins.reopenClosedPin()
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, shortcut: ShortcutAction? = nil, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            if let shortcut = shortcut?.shortcut {
                item.keyEquivalent = shortcut.keyEquivalent
                item.keyEquivalentModifierMask = shortcut.modifiers
            }
        }

        add(ShortcutAction.capture.title, #selector(captureFromMenu), shortcut: .capture)
        add(ShortcutAction.captureAgain.title, #selector(captureAgainFromMenu), shortcut: .captureAgain, enabled: capturer.lastArea != nil)
        add(ShortcutAction.pinClipboard.title, #selector(pinClipboard), shortcut: .pinClipboard,
            enabled: Screenshot.canRead(NSPasteboard.general))
        add(String(localized: "Open Image…"), #selector(openImage))

        if !pins.pins.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: String(localized: "Pins"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for pin in pins.pins {
                menu.addItem(pinItem(for: pin))
                // Hold ⌥ to close a pin instead.
                let close = pinItem(for: pin)
                close.title = String(localized: "Close \(close.title)")
                close.action = #selector(closePin)
                close.isAlternate = true
                close.keyEquivalentModifierMask = .option
                menu.addItem(close)
            }
            menu.addItem(.separator())
            add(String(localized: "Bring All Pins Here"), #selector(bringAllHere))
            add(pins.hasShownPins ? String(localized: "Hide All Pins") : String(localized: "Show All Pins"),
                #selector(togglePins), shortcut: .togglePins)
        } else {
            menu.addItem(.separator())
        }
        add(ShortcutAction.reopenClosed.title, #selector(reopenClosedPin), shortcut: .reopenClosed, enabled: pins.canReopen)
        add(String(localized: "Close All Pins"), #selector(closeAllPins), enabled: !pins.pins.isEmpty)
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(withTitle: String(localized: "Quit Pinna"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// A pin in the menu: a thumbnail, its size and when it was taken. Choosing it brings it here.
    private func pinItem(for pin: PinWindow) -> NSMenuItem {
        let size = pin.screenshot.size
        let time = pin.screenshot.date.formatted(date: .omitted, time: .shortened)
        var title = "\(Int(size.width)) × \(Int(size.height))  ·  \(time)"
        if pin.isClickThrough { title += "  " + String(localized: "(Click-Through)") }
        if pin.isHiddenByUser { title += "  " + String(localized: "(Hidden)") }
        let item = NSMenuItem(title: title, action: #selector(bringPinHere), keyEquivalent: "")
        item.target = self
        item.image = pin.thumbnail(height: 28)
        item.representedObject = pin
        item.toolTip = String(localized: "Bring this pin to the current desktop")
        return item
    }

    @objc private func bringPinHere(_ sender: NSMenuItem) {
        guard let pin = sender.representedObject as? PinWindow else { return }
        pins.bringHere(pin)
    }

    @objc private func closePin(_ sender: NSMenuItem) {
        (sender.representedObject as? PinWindow)?.close()
    }

    @objc private func bringAllHere() { pins.bringAllHere() }
    @objc private func togglePins() { pins.toggleVisibility() }
    @objc private func reopenClosedPin() { pins.reopenClosedPin() }
    @objc private func closeAllPins() { pins.closeAll() }

    // MARK: Capturing

    @objc private func captureFromMenu() { capture(fromMenu: true) }
    @objc private func captureAgainFromMenu() { captureAgain(fromMenu: true) }

    private func capture(fromMenu: Bool) {
        run(fromMenu: fromMenu) { try await $0.capture() }
    }

    private func captureAgain(fromMenu: Bool) {
        guard capturer.lastArea != nil else { return capture(fromMenu: fromMenu) }
        run(fromMenu: fromMenu) { try await $0.captureLastArea() }
    }

    private func run(fromMenu: Bool, _ capture: @escaping (Capturer) async throws -> Capture?) {
        guard hasScreenRecordingPermission() else { return }
        Task {
            // Let the menu fade out first, so it isn't in the screenshot.
            if fromMenu { try? await Task.sleep(for: .milliseconds(200)) }
            do {
                guard let result = try await capture(capturer) else { return }
                pins.pin(result.screenshot, at: result.frame)
                // Make the PNG off the main thread, then put it on the clipboard.
                let screenshot = result.screenshot
                await Task.detached { _ = screenshot.pngData }.value
                screenshot.copyToPasteboard()
            } catch {
                if !CGPreflightScreenCaptureAccess() {
                    _ = hasScreenRecordingPermission()
                } else {
                    NSLog("Pinna: capture failed: \(error)")
                    NSApp.activate()
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    private func hasScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }

        let alert = NSAlert()
        alert.messageText = String(localized: "Pinna needs Screen Recording permission")
        alert.informativeText = String(localized: "Turn on Pinna in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen Pinna.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: Images from elsewhere

    @objc private func pinClipboard() {
        guard let screenshot = Screenshot.fromPasteboard(.general) else {
            NSSound.beep()
            return
        }
        pins.pin(screenshot)
    }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose images to pin.")
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        pinImages(at: panel.urls)
    }

    private func pinImages(at urls: [URL]) {
        var unreadable: [String] = []
        for (index, url) in urls.enumerated() {
            if let screenshot = Screenshot(contentsOf: url) {
                pins.pin(screenshot, cascade: index)
            } else {
                unreadable.append(url.lastPathComponent)
            }
        }
        if !unreadable.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "Pinna couldn't open \(unreadable.formatted())")
            alert.informativeText = String(localized: "Only images can be pinned.")
            NSApp.activate()
            alert.runModal()
        }
    }

    // Dragging onto the menu bar icon.

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Screenshot.canRead(sender.draggingPasteboard) ? .copy : []
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            pinImages(at: urls)
            return true
        }
        guard let screenshot = Screenshot.fromPasteboard(pasteboard) else { return false }
        pins.pin(screenshot)
        return true
    }

    // MARK: Settings

    private func makeSettingsWindow() -> SettingsWindow {
        let window = SettingsWindow()
        // Pause the shortcuts while a new one is typed, so pressing one doesn't set it off.
        window.onRecordingChange = { [weak self] isRecording in
            if isRecording { self?.hotKeys?.unregisterAll() } else { self?.hotKeys?.registerAll() }
        }
        window.onChange = { [weak self] action, shortcut in
            self?.setShortcut(shortcut, for: action) ?? false
        }
        window.onRestoresPinsChange = { [weak self] in
            self?.pins.saveNow()
        }
        return window
    }

    private func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) -> Bool {
        guard hotKeys?.register(shortcut, for: action) == true else {
            hotKeys?.register(action.shortcut, for: action)
            return false
        }
        action.shortcut = shortcut
        return true
    }

    @objc func showSettings() {
        NSApp.activate()
        settingsWindow.makeKeyAndOrderFront(nil)
    }
}
