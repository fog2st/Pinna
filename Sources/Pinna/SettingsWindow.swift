import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Pinna's settings: shortcuts, how new pins behave, and starting at login.
final class SettingsWindow: NSWindow {
    /// Called with a newly chosen shortcut, or nil to remove one; returns false if it couldn't be registered.
    var onChange: ((ShortcutAction, Shortcut?) -> Bool)?
    /// Called when recording starts (true) and stops (false), so the shortcuts can be paused meanwhile.
    var onRecordingChange: ((Bool) -> Void)?
    var onRestoresPinsChange: (() -> Void)?

    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private var clearButtons: [ShortcutAction: NSButton] = [:]
    private let message = NSTextField(wrappingLabelWithString: "")
    private let resizing = NSPopUpButton()
    private let keepsOnTop = NSButton(checkboxWithTitle: String(localized: "Keep on top of other windows"), target: nil, action: nil)
    private let showsOnAllSpaces = NSButton(checkboxWithTitle: String(localized: "Show on all Spaces, including full-screen apps"), target: nil, action: nil)
    private let launchAtLogin = NSButton(checkboxWithTitle: String(localized: "Launch Pinna at login"), target: nil, action: nil)
    private let restoresPins = NSButton(checkboxWithTitle: String(localized: "Reopen pins from last time"), target: nil, action: nil)
    private let loginApproval = NSButton(title: String(localized: "Allow in Login Items…"), target: nil, action: nil)
    private var loginApprovalRow: NSGridRow?
    private static let hint = String(localized: "Click a shortcut, then press the keys you want.")

    init() {
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = String(localized: "Pinna Settings")
        isReleasedWhenClosed = false

        var rows: [[NSView]] = [[sectionLabel(String(localized: "Shortcuts")), NSGridCell.emptyContentView]]
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorder(shortcut: action.shortcut)
            recorder.onRecordingChange = { [weak self] isRecording in
                if isRecording { self?.showMessage(Self.hint) }
                self?.onRecordingChange?(isRecording)
            }
            recorder.onRecord = { [weak self] in self?.apply($0, for: action) }
            recorder.setAccessibilityLabel(action.title)
            recorders[action] = recorder

            let clear = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Remove Shortcut"))!,
                                 target: self, action: #selector(clearShortcut))
            clear.isBordered = false
            clear.contentTintColor = .tertiaryLabelColor
            clear.toolTip = String(localized: "Remove Shortcut")
            clear.tag = ShortcutAction.allCases.firstIndex(of: action)!
            clearButtons[action] = clear
            rows.append([NSTextField(labelWithString: action.title + ":"), NSStackView(views: [recorder, clear])])
        }
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.preferredMaxLayoutWidth = 300
        showMessage(Self.hint)
        let restoreDefaults = NSButton(title: String(localized: "Restore Default Shortcuts"), target: self, action: #selector(restoreDefaultShortcuts))
        restoreDefaults.controlSize = .small
        rows.append([NSGridCell.emptyContentView, message])
        rows.append([NSGridCell.emptyContentView, restoreDefaults])

        resizing.addItems(withTitles: [String(localized: "Keep window proportions"), String(localized: "Resize freely")])
        resizing.target = self
        resizing.action = #selector(changeResizing)
        let resizingNote = note(String(localized: "The image always keeps its proportions. Hold ⇧ while resizing to switch window resizing modes, or use the pin's right-click menu."))
        for checkbox in [keepsOnTop, showsOnAllSpaces, launchAtLogin, restoresPins] {
            checkbox.target = self
            checkbox.action = #selector(toggleCheckbox)
        }
        loginApproval.target = self
        loginApproval.action = #selector(openLoginItems)
        loginApproval.controlSize = .small

        rows.append([separator(), NSGridCell.emptyContentView])
        rows.append([sectionLabel(String(localized: "New Pins")), NSGridCell.emptyContentView])
        rows.append([NSTextField(labelWithString: String(localized: "When resizing:")), resizing])
        rows.append([NSGridCell.emptyContentView, resizingNote])
        rows.append([NSTextField(labelWithString: String(localized: "Window:")), keepsOnTop])
        rows.append([NSGridCell.emptyContentView, showsOnAllSpaces])
        rows.append([separator(), NSGridCell.emptyContentView])
        rows.append([sectionLabel(String(localized: "General")), NSGridCell.emptyContentView])
        rows.append([NSTextField(labelWithString: String(localized: "Startup:")), launchAtLogin])
        rows.append([NSGridCell.emptyContentView, loginApproval])
        rows.append([NSGridCell.emptyContentView, restoresPins])

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).yPlacement = .center
        }
        // Section titles and separators span both columns.
        for (index, row) in rows.enumerated() where row[1] === NSGridCell.emptyContentView && row[0] !== NSGridCell.emptyContentView {
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: index, length: 1))
            grid.cell(atColumnIndex: 0, rowIndex: index).xPlacement = .leading
            if row[0] is NSBox { grid.cell(atColumnIndex: 0, rowIndex: index).xPlacement = .fill }
        }

        loginApprovalRow = grid.cell(for: loginApproval)?.row

        let content = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        contentView = content
        reloadValues()
        setContentSize(content.fittingSize)
        center()
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 300
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// Shows the saved settings.
    private func reloadValues() {
        for action in ShortcutAction.allCases {
            recorders[action]?.shortcut = action.shortcut
            clearButtons[action]?.isHidden = action.shortcut == nil
        }
        resizing.selectItem(at: Preferences.keepsProportions ? 0 : 1)
        keepsOnTop.state = Preferences.keepsOnTop ? .on : .off
        showsOnAllSpaces.state = Preferences.showsOnAllSpaces ? .on : .off
        restoresPins.state = Preferences.restoresPins ? .on : .off
        let login = SMAppService.mainApp.status
        launchAtLogin.state = login == .enabled || login == .requiresApproval ? .on : .off
        // Only needed when macOS asks the user to approve the login item.
        loginApprovalRow?.isHidden = login != .requiresApproval
    }

    // The login item can be changed in System Settings meanwhile.
    override func becomeKey() {
        super.becomeKey()
        reloadValues()
    }

    // Stop recording when the window goes away, or the paused shortcuts would stay off.
    override func resignKey() {
        super.resignKey()
        recorders.values.forEach { $0.stopRecording() }
    }

    override func close() {
        recorders.values.forEach { $0.stopRecording() }
        super.close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        // Pinna has no menu bar to provide ⌘W.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return false
    }

    // MARK: Shortcuts

    private func apply(_ shortcut: Shortcut, for action: ShortcutAction) {
        if !shortcut.isValid {
            showMessage(String(localized: "Include ⌘, ⌥ or ⌃, so the shortcut doesn't get in the way of typing."), isError: true)
        } else if let other = ShortcutAction.allCases.first(where: { $0 != action && $0.shortcut == shortcut }) {
            showMessage(String(localized: "\(shortcut.description) is already used for “\(other.title)”."), isError: true)
        } else if onChange?(action, shortcut) == false {
            showMessage(String(localized: "Pinna couldn't use \(shortcut.description). Try a different shortcut."), isError: true)
        } else {
            showMessage(Self.hint)
        }
        reloadValues()
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        let action = ShortcutAction.allCases[sender.tag]
        _ = onChange?(action, nil)
        reloadValues()
    }

    @objc private func restoreDefaultShortcuts() {
        for action in ShortcutAction.allCases {
            _ = onChange?(action, nil)
        }
        for action in ShortcutAction.allCases where action.defaultShortcut != nil {
            if onChange?(action, action.defaultShortcut) == false {
                showMessage(String(localized: "Pinna couldn't use \(action.defaultShortcut!.description). Try a different shortcut."), isError: true)
            }
        }
        reloadValues()
    }

    private func showMessage(_ text: String, isError: Bool = false) {
        message.stringValue = text
        message.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: Other settings

    @objc private func changeResizing() {
        Preferences.keepsProportions = resizing.indexOfSelectedItem == 0
    }

    @objc private func toggleCheckbox(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender {
        case keepsOnTop: Preferences.keepsOnTop = on
        case showsOnAllSpaces: Preferences.showsOnAllSpaces = on
        case restoresPins:
            Preferences.restoresPins = on
            onRestoresPinsChange?()
        case launchAtLogin:
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSAlert(error: error).runModal()
            }
        default: break
        }
        reloadValues()
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// A button showing a shortcut. Click it, then press keys to record a new one; Esc cancels.
private final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? {
        didSet { showShortcut() }
    }
    /// Called with whatever keys were pressed; checking them is up to the caller.
    var onRecord: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var isRecording = false

    init(shortcut: Shortcut?) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .push
        target = self
        action = #selector(startRecording)
        widthAnchor.constraint(equalToConstant: 140).isActive = true
        showShortcut()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func showShortcut() {
        guard !isRecording else { return }
        title = shortcut?.description ?? String(localized: "Record Shortcut")
    }

    @objc private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        title = String(localized: "Type Shortcut…")
        bezelColor = .controlAccentColor
        window?.makeFirstResponder(self)
        onRecordingChange?(true)
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        bezelColor = nil
        showShortcut()
        onRecordingChange?(false)
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        let shortcut = Shortcut(keyCode: Int(event.keyCode), modifiers: event.modifierFlags)
        stopRecording()
        if shortcut != Shortcut(keyCode: kVK_Escape, modifiers: []) {
            onRecord?(shortcut)
        }
    }

    // ⌘ and ⌃ keys arrive here rather than in keyDown; while recording they're the shortcut being typed.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    // Show the modifiers as they're held down.
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        let held = Shortcut.symbols(for: event.modifierFlags)
        title = held.isEmpty ? String(localized: "Type Shortcut…") : held
    }
}
