import AppKit
import UniformTypeIdentifiers

/// A window showing one screenshot on a blurred, see-through background. It stays on the desktop it was
/// pinned on, and floats above other windows unless the pin in its title bar is turned off.
final class PinWindow: NSPanel, NSWindowDelegate {
    let screenshot: Screenshot
    var onClose: ((PinWindow) -> Void)?
    /// How big the screenshot is shown, relative to its real size.
    private var scale: CGFloat = 1
    /// Room around the screenshot: the title bar above it, a thin border on the other sides.
    private let insets: NSEdgeInsets
    /// Room for the window buttons and the pin; narrower screenshots are centered.
    private var minWidth: CGFloat = 0
    private var resizeAxis: ResizeAxis?

    private enum ResizeAxis { case width, height, corner }

    /// `imageFrame` is where the screenshot goes on screen; the window is built around it.
    init(screenshot: Screenshot, frame imageFrame: NSRect) {
        self.screenshot = screenshot
        let titlebarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: .titled).height
        insets = NSEdgeInsets(top: titlebarHeight, left: 6, bottom: 6, right: 6)
        super.init(contentRect: imageFrame,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Pinned Screenshot"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        // Floating windows follow you to every desktop unless they're managed.
        collectionBehavior = [.managed, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        delegate = self

        let view = PinView(image: screenshot.image, insets: insets)
        view.menu = makeMenu()
        contentView = view

        let accessory = makeKeepOnTopAccessory()
        addTitlebarAccessoryViewController(accessory)

        minWidth = (standardWindowButton(.zoomButton)?.frame.maxX ?? 70) + 12 + accessory.view.frame.width
        let size = windowSize(scale: 1)
        setFrame(NSRect(x: imageFrame.midX - size.width / 2, y: imageFrame.minY - insets.bottom,
                        width: size.width, height: size.height), display: false)
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

    private func makeKeepOnTopAccessory() -> NSTitlebarAccessoryViewController {
        let toggle = PinToggle()
        toggle.state = .on
        toggle.target = self
        toggle.action = #selector(toggleKeepOnTop)

        // Centered in the title bar, as far from the corner as the window buttons are from theirs.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: toggle.frame.width + 4, height: insets.top))
        toggle.frame.origin.y = (container.frame.height - toggle.frame.height) / 2
        toggle.autoresizingMask = [.minYMargin, .maxYMargin]
        container.addSubview(toggle)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        return accessory
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

    @objc func toggleKeepOnTop(_ sender: NSButton) {
        level = sender.state == .on ? .floating : .normal
    }

    @objc func zoomIn() { zoom(by: 1.25) }
    @objc func zoomOut() { zoom(by: 0.8) }
    @objc func actualSize() { zoom(by: 1 / scale) }

    // MARK: Sizing

    private func clamped(_ scale: CGFloat) -> CGFloat {
        max(0.1, min(scale, 8))
    }

    private func windowSize(scale: CGFloat) -> NSSize {
        let image = screenshot.image.size
        return NSSize(width: max((image.width * scale).rounded() + insets.left + insets.right, minWidth),
                      height: (image.height * scale).rounded() + insets.top + insets.bottom)
    }

    /// The scales at which the screenshot would fill a window of `size` across and down.
    private func fittingScales(_ size: NSSize) -> (width: CGFloat, height: CGFloat) {
        let image = screenshot.image.size
        return ((size.width - insets.left - insets.right) / image.width,
                (size.height - insets.top - insets.bottom) / image.height)
    }

    /// Resizes the window, keeping `anchor` (a screen point) fixed; defaults to the center.
    func zoom(by factor: CGFloat, around anchor: NSPoint? = nil) {
        let newScale = clamped(scale * factor)
        guard newScale != scale else { return }
        let anchor = anchor ?? NSPoint(x: frame.midX, y: frame.midY)
        let size = windowSize(scale: newScale)
        let origin = NSPoint(x: anchor.x - (anchor.x - frame.minX) * size.width / frame.width,
                             y: anchor.y - (anchor.y - frame.minY) * size.height / frame.height)
        scale = newScale
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func windowDidResize(_ notification: Notification) {
        // Keep the exact scale while the size matches it (small zoom steps round to the same size);
        // otherwise something else resized the window, like dragging an edge or the green button.
        let expected = windowSize(scale: scale)
        guard abs(frame.width - expected.width) > 1 || abs(frame.height - expected.height) > 1 else { return }
        let fitting = fittingScales(frame.size)
        scale = min(fitting.width, fitting.height)
    }

    /// Keeps the screenshot's proportions while an edge or corner is dragged.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Work out which edge is being dragged from the first step and stick with it. Deciding at every
        // step made corner drags flip between following the width and the height, which flickered.
        let axis = resizeAxis ?? (frameSize.height == frame.height ? .width : frameSize.width == frame.width ? .height : .corner)
        if inLiveResize { resizeAxis = axis }

        let fitting = fittingScales(frameSize)
        // A screenshot narrower than the title bar can only follow the height.
        let fillsWidth = windowSize(scale: scale).width > minWidth
        let newScale = switch axis {
        case .width: fillsWidth ? fitting.width : scale
        case .height: fitting.height
        case .corner: fillsWidth ? max(fitting.width, fitting.height) : fitting.height
        }
        return windowSize(scale: clamped(newScale))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        resizeAxis = nil
    }

    /// The green button fits the screenshot to the screen, keeping its proportions.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let fitting = fittingScales(newFrame.size)
        let size = windowSize(scale: clamped(min(fitting.width, fitting.height)))
        return NSRect(x: newFrame.midX - size.width / 2, y: newFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }
}

/// The keep-on-top toggle: an outlined pin that fills in with the accent color while the window floats.
private final class PinToggle: NSButton {
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        setButtonType(.toggle)
        isBordered = false
        imagePosition = .imageOnly
        let symbol = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Keep on Top")?.withSymbolConfiguration(symbol)
        alternateImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Keep on Top")?.withSymbolConfiguration(symbol)
        toolTip = "Keep on top of other windows"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Clicks change the state without going through `state`, but always send the action.
    override var state: NSControl.StateValue {
        didSet { updateTint() }
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        updateTint()
        return super.sendAction(action, to: target)
    }

    private func updateTint() {
        contentTintColor = state == .on ? .controlAccentColor : .secondaryLabelColor
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor? = state == .on
            ? .controlAccentColor.withAlphaComponent(isHovered ? 0.3 : 0.2)
            : isHovered ? .labelColor.withAlphaComponent(0.1) : nil
        if let fill {
            fill.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        super.draw(dirtyRect)
    }
}

/// The window's content: the screenshot on a blurred background. Handles dragging, zooming and shortcuts.
private final class PinView: NSView {
    private let screenshotView: ScreenshotView
    private let imageSize: NSSize
    private let insets: NSEdgeInsets

    init(image: NSImage, insets: NSEdgeInsets) {
        screenshotView = ScreenshotView(image: image)
        imageSize = image.size
        self.insets = insets
        super.init(frame: .zero)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active // stay blurred when the pin isn't focused
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        addSubview(screenshotView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Laid out here rather than in `layout()` so the screenshot moves in step with the window as it resizes.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        let area = NSRect(x: insets.left, y: insets.bottom,
                          width: bounds.width - insets.left - insets.right, height: bounds.height - insets.top - insets.bottom)
        let scale = max(0, min(area.width / imageSize.width, area.height / imageSize.height))
        let size = NSSize(width: (imageSize.width * scale).rounded(), height: (imageSize.height * scale).rounded())
        screenshotView.frame = NSRect(x: (area.midX - size.width / 2).rounded(), y: area.maxY - size.height,
                                      width: size.width, height: size.height)
    }

    // The background and screenshot are just for show; this view handles every click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
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

/// Draws the screenshot with rounded corners, scaled to its frame.
private final class ScreenshotView: NSView {
    private let image: CGImage?

    init(image: NSImage) {
        self.image = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleAxesIndependently
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image
        layer.minificationFilter = .trilinear
        // Follows the window's corners, 6pt further in. macOS 26 rounds windows more.
        if #available(macOS 26, *) { layer.cornerRadius = 10 } else { layer.cornerRadius = 4 }
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }
}
