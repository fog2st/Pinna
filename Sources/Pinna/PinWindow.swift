import AppKit
import UniformTypeIdentifiers

/// A borderless, always-on-top window showing one screenshot.
final class PinWindow: NSPanel {
    let screenshot: Screenshot
    var onClose: ((PinWindow) -> Void)?
    private var scale: CGFloat = 1

    init(screenshot: Screenshot, frame: NSRect) {
        self.screenshot = screenshot
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear

        let view = PinView(image: screenshot.image)
        view.menu = makeMenu()
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        (contentView as? PinView)?.isFocused = true
    }

    override func resignKey() {
        super.resignKey()
        (contentView as? PinView)?.isFocused = false
    }

    override func close() {
        super.close()
        onClose?(self)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "c")
        menu.addItem(withTitle: "Save As…", action: #selector(saveImage), keyEquivalent: "s")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        menu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        menu.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "0")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(close), keyEquivalent: "w")
        menu.items.forEach { $0.target = self }
        return menu
    }

    // MARK: Actions

    @objc func copyImage() {
        screenshot.copyToPasteboard()
    }

    @objc func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = screenshot.suggestedFilename
        panel.level = .modalPanel
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try screenshot.pngData.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func zoomIn() { zoom(by: 1.25) }
    @objc func zoomOut() { zoom(by: 0.8) }
    @objc func actualSize() { zoom(by: 1 / scale) }

    /// Resizes the window, keeping `anchor` (a screen point) fixed; defaults to the center.
    func zoom(by factor: CGFloat, around anchor: NSPoint? = nil) {
        let newScale = max(0.1, min(scale * factor, 8))
        guard newScale != scale else { return }
        let anchor = anchor ?? NSPoint(x: frame.midX, y: frame.midY)
        let size = NSSize(width: screenshot.image.size.width * newScale, height: screenshot.image.size.height * newScale)
        let origin = NSPoint(x: anchor.x - (anchor.x - frame.minX) * size.width / frame.width,
                             y: anchor.y - (anchor.y - frame.minY) * size.height / frame.height)
        scale = newScale
        setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// Draws the screenshot and handles dragging, zooming and shortcuts.
private final class PinView: NSView {
    private let image: CGImage?

    var isFocused = false {
        didSet { needsDisplay = true }
    }

    init(image: NSImage) {
        self.image = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        super.init(frame: NSRect(origin: .zero, size: image.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.borderWidth = 1
        layer.borderColor = isFocused ? NSColor.controlAccentColor.cgColor : NSColor(white: 0.5, alpha: 0.5).cgColor
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.close()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        var delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
        if event.isDirectionInvertedFromDevice { delta = -delta } // same direction regardless of "natural scrolling"
        (window as? PinWindow)?.zoom(by: 1 + max(-0.5, min(delta, 0.5)), around: NSEvent.mouseLocation)
    }

    override func magnify(with event: NSEvent) {
        (window as? PinWindow)?.zoom(by: 1 + event.magnification, around: NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            window?.close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        menu?.performKeyEquivalent(with: event) == true || super.performKeyEquivalent(with: event)
    }
}
