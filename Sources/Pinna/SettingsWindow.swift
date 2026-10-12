import AppKit
import Carbon.HIToolbox

/// Pinna's settings: the Capture & Pin shortcut.
final class SettingsWindow: NSWindow {
    /// Called with a newly chosen shortcut; returns false if it couldn't be registered.
    var onChange: ((Shortcut) -> Bool)?
    /// Called when recording starts (true) and stops (false), so the current shortcut can be paused meanwhile.
    var onRecordingChange: ((Bool) -> Void)?

    private let recorder: ShortcutRecorder
    private let resetButton = NSButton(title: "Restore Default", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private static let hint = "Click the shortcut, then press the keys you want."

    init(shortcut: Shortcut) {
        recorder = ShortcutRecorder(shortcut: shortcut)
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Pinna Settings"
        isReleasedWhenClosed = false

        recorder.onRecordingChange = { [weak self] isRecording in
            if isRecording { self?.showMessage(Self.hint) }
            self?.onRecordingChange?(isRecording)
        }
        recorder.onRecord = { [weak self] in self?.apply($0) }
        resetButton.target = self
        resetButton.action = #selector(restoreDefault)
        resetButton.isEnabled = shortcut != .default
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.preferredMaxLayoutWidth = 260
        showMessage(Self.hint)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Capture & Pin:"), NSStackView(views: [recorder, resetButton])],
            [NSGridCell.emptyContentView, message],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 0).yPlacement = .center

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
        setContentSize(content.fittingSize)
        center()
    }

    // Stop recording when the window goes away, or the paused shortcut would stay off.
    override func resignKey() {
        super.resignKey()
        recorder.stopRecording()
    }

    override func close() {
        recorder.stopRecording()
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

    private func apply(_ shortcut: Shortcut) {
        if !shortcut.isValid {
            showMessage("Include ⌘, ⌥ or ⌃, so the shortcut doesn't get in the way of typing.", isError: true)
        } else if onChange?(shortcut) == false {
            showMessage("Pinna couldn't use \(shortcut.description). Try a different shortcut.", isError: true)
        } else {
            recorder.shortcut = shortcut
            resetButton.isEnabled = shortcut != .default
            showMessage(Self.hint)
        }
    }

    @objc private func restoreDefault() {
        apply(.default)
    }

    private func showMessage(_ text: String, isError: Bool = false) {
        message.stringValue = text
        message.textColor = isError ? .systemRed : .secondaryLabelColor
    }
}

/// A button showing a shortcut. Click it, then press keys to record a new one; Esc cancels.
private final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut {
        didSet { title = shortcut.description }
    }
    /// Called with whatever keys were pressed; checking them is up to the caller.
    var onRecord: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var isRecording = false

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .push
        title = shortcut.description
        target = self
        action = #selector(startRecording)
        widthAnchor.constraint(equalToConstant: 140).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        title = "Type Shortcut…"
        bezelColor = .controlAccentColor
        window?.makeFirstResponder(self)
        onRecordingChange?(true)
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        title = shortcut.description
        bezelColor = nil
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
        title = held.isEmpty ? "Type Shortcut…" : held
    }
}
