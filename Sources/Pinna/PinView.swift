import AppKit
@preconcurrency import VisionKit

/// A pin's content: the screenshot on a blurred background. Handles dragging, zooming and shortcuts, and holds
/// the Live Text and markup layers while they're on.
final class PinView: NSView, NSDraggingSource, ImageAnalysisOverlayViewDelegate {
    var screenshot: Screenshot {
        didSet {
            screenshotView.image = screenshot.image
            updateAccessibility()
            needsLayout = true
            resizeSubviews(withOldSize: bounds.size)
        }
    }
    private let insets: NSEdgeInsets
    private let screenshotView = ScreenshotView()
    private(set) var liveTextOverlay: ImageAnalysisOverlayView?
    var markupView: MarkupView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let markupView {
                markupView.frame = screenshotFrame
                addSubview(markupView)
            }
        }
    }

    init(screenshot: Screenshot, insets: NSEdgeInsets) {
        self.screenshot = screenshot
        self.insets = insets
        super.init(frame: .zero)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active // stay blurred when the pin isn't focused
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        screenshotView.image = screenshot.image
        addSubview(screenshotView)
        let outline = PinOutlineView(frame: bounds)
        outline.autoresizingMask = [.width, .height]
        addSubview(outline)
        updateAccessibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The image and its interaction overlays share one proportionally fitted, centered frame.
    var screenshotFrame: NSRect {
        PinGeometry(imageSize: screenshot.size, insets: insets, minWidth: 0).imageFrame(in: bounds)
    }

    // Laid out here rather than in `layout()` so the screenshot moves in step with the window as it resizes.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        let frame = screenshotFrame
        screenshotView.frame = frame
        liveTextOverlay?.frame = frame
        markupView?.frame = frame
    }

    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        let size = screenshot.size
        let time = screenshot.date.formatted(date: .omitted, time: .shortened)
        setAccessibilityLabel(String(localized: "Pinned screenshot, \(Int(size.width)) by \(Int(size.height)) points, from \(time)"))
    }

    // MARK: Live Text

    /// Shows the text found in the screenshot so it can be selected, or stops if `analysis` is nil.
    func showLiveText(_ analysis: ImageAnalysis?) {
        guard let analysis else {
            liveTextOverlay?.removeFromSuperview()
            liveTextOverlay = nil
            return
        }
        let overlay = liveTextOverlay ?? ImageAnalysisOverlayView()
        overlay.delegate = self
        overlay.preferredInteractionTypes = [.textSelection, .dataDetectors]
        overlay.analysis = analysis
        overlay.frame = screenshotFrame
        if overlay.superview == nil {
            addSubview(overlay, positioned: .above, relativeTo: screenshotView)
        }
        liveTextOverlay = overlay
    }

    // The screenshot fills the overlay exactly.
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    // MARK: Mouse

    // The background and screenshot are just for show; this view handles every click, except on text
    // while Live Text is on, and while marking up.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if let markupView, markupView.frame.contains(local) {
            return markupView.hitTest(local) ?? markupView
        }
        if let overlay = liveTextOverlay, overlay.frame.contains(local),
           overlay.hasInteractiveItem(at: overlay.convert(local, from: self)) {
            return overlay.hitTest(local) ?? overlay
        }
        return self
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pinWindow: PinWindow? { window as? PinWindow }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        liveTextOverlay?.resetSelection()
        if event.modifierFlags.contains(.option) {
            dragOut(with: event)
        } else if event.clickCount == 2, markupView == nil {
            window?.close()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        var delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
        if event.isDirectionInvertedFromDevice { delta = -delta } // same direction regardless of "natural scrolling"
        delta = max(-0.5, min(delta, 0.5))
        if event.modifierFlags.contains(.option) {
            pinWindow?.changeOpacity(by: delta / 2)
        } else {
            pinWindow?.zoom(by: 1 + delta, around: NSEvent.mouseLocation)
        }
    }

    override func magnify(with event: NSEvent) {
        pinWindow?.zoom(by: 1 + event.magnification, around: NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case 53: window?.close() // Esc
        case 123: pinWindow?.nudge(dx: -step, dy: 0)
        case 124: pinWindow?.nudge(dx: step, dy: 0)
        case 125: pinWindow?.nudge(dx: 0, dy: -step)
        case 126: pinWindow?.nudge(dx: 0, dy: step)
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        menu?.performKeyEquivalent(with: event) == true || super.performKeyEquivalent(with: event)
    }

    // MARK: Dragging out

    /// ⌥-drag hands the screenshot to another app, or to Finder as a PNG file.
    private func dragOut(with event: NSEvent) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pinna Drags", isDirectory: true)
        let url = directory.appendingPathComponent(screenshot.suggestedFilename)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try screenshot.pngData.write(to: url)
        } catch {
            NSLog("Pinna: couldn't write the dragged screenshot: \(error)")
            return
        }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(screenshot.pngData, forType: .png)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(screenshotFrame, contents: screenshot.nsImage)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

/// A dark outer stroke and light inner stroke keep every edge visible over light and dark backgrounds.
private final class PinOutlineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat
        if #available(macOS 26, *) { radius = 16 } else { radius = 10 }
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        outer.lineWidth = 2
        NSColor.black.withAlphaComponent(0.55).setStroke()
        outer.stroke()
        let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: radius - 1, yRadius: radius - 1)
        inner.lineWidth = 1
        NSColor.white.withAlphaComponent(0.75).setStroke()
        inner.stroke()
    }
}

/// Draws the screenshot with rounded corners, scaled to its frame.
private final class ScreenshotView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleProportionallyToFit
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image
        layer.contentsGravity = .resizeAspect
        layer.minificationFilter = .trilinear
        // Follows the window's corners, 6pt further in. macOS 26 rounds windows more.
        if #available(macOS 26, *) { layer.cornerRadius = 10 } else { layer.cornerRadius = 4 }
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }
}
