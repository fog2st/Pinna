import AppKit
import UniformTypeIdentifiers

/// A window showing one screenshot. It stays on the desktop it was pinned on,
/// and floats above other windows unless the switch in its title bar is turned off.
final class PinWindow: NSPanel, NSWindowDelegate {
    let screenshot: Screenshot
    var onClose: ((PinWindow) -> Void)?
    /// How big the screenshot is shown, relative to its real size.
    private var scale: CGFloat = 1
    /// Room for the window buttons and the switch; narrower screenshots are centered.
    private var minContentWidth: CGFloat = 0

    /// `imageFrame` is where the screenshot goes on screen; the title bar sits above it.
    init(screenshot: Screenshot, frame imageFrame: NSRect) {
        self.screenshot = screenshot
        super.init(contentRect: imageFrame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Pinned Screenshot"
        titleVisibility = .hidden
        level = .floating
        // Floating windows follow you to every desktop unless they're managed.
        collectionBehavior = [.managed, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        delegate = self

        let view = PinView(image: screenshot.image)
        view.menu = makeMenu()
        contentView = view

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = makeKeepOnTopSwitch()
        accessory.layoutAttribute = .trailing
        addTitlebarAccessoryViewController(accessory)

        minContentWidth = (standardWindowButton(.zoomButton)?.frame.maxX ?? 70) + 12 + accessory.view.frame.width
        let size = contentSize(scale: 1)
        setFrame(frameRect(forContentRect: NSRect(x: imageFrame.midX - size.width / 2, y: imageFrame.minY,
                                                  width: size.width, height: size.height)), display: false)
    }

    override func close() {
        super.close()
        onClose?(self)
    }

    override func sendEvent(_ event: NSEvent) {
        // Clicks don't activate Pinna, so bring the pin forward by hand.
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            orderFrontRegardless()
        }
        super.sendEvent(event)
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

    private func makeKeepOnTopSwitch() -> NSView {
        let toggle = FirstMouseSwitch()
        toggle.controlSize = .mini
        toggle.state = .on
        toggle.target = self
        toggle.action = #selector(toggleKeepOnTop)
        toggle.toolTip = "Keep on top of other windows"
        toggle.setAccessibilityLabel("Keep on Top")

        let icon = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) ?? NSImage())
        let stack = NSStackView(views: [icon, toggle])
        stack.edgeInsets.right = 8
        stack.frame.size = stack.fittingSize
        return stack
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

    @objc func toggleKeepOnTop(_ sender: NSSwitch) {
        level = sender.state == .on ? .floating : .normal
    }

    @objc func zoomIn() { zoom(by: 1.25) }
    @objc func zoomOut() { zoom(by: 0.8) }
    @objc func actualSize() { zoom(by: 1 / scale) }

    // MARK: Sizing

    private func clamped(_ scale: CGFloat) -> CGFloat {
        max(0.1, min(scale, 8))
    }

    private func contentSize(scale: CGFloat) -> NSSize {
        let image = screenshot.image.size
        return NSSize(width: max(image.width * scale, minContentWidth).rounded(), height: (image.height * scale).rounded())
    }

    /// Resizes the window, keeping `anchor` (a screen point) fixed; defaults to the center.
    func zoom(by factor: CGFloat, around anchor: NSPoint? = nil) {
        let newScale = clamped(scale * factor)
        guard newScale != scale else { return }
        let content = contentRect(forFrameRect: frame)
        let anchor = anchor ?? NSPoint(x: content.midX, y: content.midY)
        let size = contentSize(scale: newScale)
        let origin = NSPoint(x: anchor.x - (anchor.x - content.minX) * size.width / content.width,
                             y: anchor.y - (anchor.y - content.minY) * size.height / content.height)
        scale = newScale
        setFrame(frameRect(forContentRect: NSRect(origin: origin, size: size)), display: true)
    }

    func windowDidResize(_ notification: Notification) {
        // Keep the exact scale while the size matches it (small zoom steps round to the same size);
        // otherwise something else resized the window, like dragging an edge or the green button.
        let content = contentRect(forFrameRect: frame).size
        let expected = contentSize(scale: scale)
        guard abs(content.width - expected.width) > 1 || abs(content.height - expected.height) > 1 else { return }
        let image = screenshot.image.size
        scale = min(content.width / image.width, content.height / image.height)
    }

    /// Keeps the screenshot's proportions while an edge or corner is dragged.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let current = contentRect(forFrameRect: frame).size
        let proposed = contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let image = screenshot.image.size
        // Follow the edge being dragged. A screenshot narrower than the title bar only follows the height.
        let fillsWidth = image.width * scale >= current.width - 1
        let newScale = fillsWidth && abs(proposed.width - current.width) > abs(proposed.height - current.height)
            ? proposed.width / image.width
            : proposed.height / image.height
        return frameRect(forContentRect: NSRect(origin: .zero, size: contentSize(scale: clamped(newScale)))).size
    }

    /// The green button fits the screenshot to the screen, keeping its proportions.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let available = contentRect(forFrameRect: newFrame)
        let image = screenshot.image.size
        let size = contentSize(scale: clamped(min(available.width / image.width, available.height / image.height)))
        return frameRect(forContentRect: NSRect(x: available.midX - size.width / 2, y: available.maxY - size.height,
                                                width: size.width, height: size.height))
    }
}

/// Toggles on the first click, even when the pin isn't focused.
private final class FirstMouseSwitch: NSSwitch {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Draws the screenshot and handles dragging, zooming and shortcuts.
private final class PinView: NSView {
    private let image: CGImage?

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
        layer.contentsGravity = .resizeAspect // centered when the window is wider than the screenshot
        layer.minificationFilter = .trilinear
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
