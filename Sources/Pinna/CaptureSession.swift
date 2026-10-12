import AppKit

/// The full-screen part of a capture: shows the frozen screens and lets the user pick what to keep.
@MainActor
final class CaptureSession {
    enum Selection {
        case area(NSRect)
        case window(PickableWindow)
    }

    enum Mode { case area, window }

    let screens: [FrozenScreen]
    let windows: [PickableWindow]
    private(set) var mode = Mode.area
    private(set) var mouse = NSEvent.mouseLocation
    /// The area being dragged out, in screen coordinates.
    private(set) var selection: NSRect?
    private var dragStart: NSPoint?
    private var dragScreen: NSRect?
    /// While Space is held mid-drag, the selection moves instead of changing size.
    private var isMoving = false
    private var overlays: [CaptureOverlayWindow] = []
    private var continuation: CheckedContinuation<Selection?, Never>?
    private var appSwitchObserver: NSObjectProtocol?

    init(screens: [FrozenScreen], windows: [PickableWindow]) {
        self.screens = screens
        self.windows = windows
    }

    func run() async -> Selection? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            show()
        }
    }

    /// The window under the mouse, when picking windows.
    var hoveredWindow: PickableWindow? {
        mode == .window ? windows.first { $0.frame.contains(mouse) } : nil
    }

    /// What's lit up: the window under the mouse, or the dragged area.
    var highlight: NSRect? {
        mode == .window ? hoveredWindow?.frame : selection
    }

    var isDragging: Bool { dragStart != nil }

    private func show() {
        for screen in screens {
            let window = CaptureOverlayWindow(frame: screen.frame)
            let view = CaptureView(session: self, screen: screen)
            window.contentView = view
            window.initialFirstResponder = view
            window.makeFirstResponder(view)
            overlays.append(window)
            window.orderFrontRegardless()
        }
        // Key, so Esc and Space arrive, but without activating Pinna and taking focus from the app being captured.
        let underMouse = overlays.first { $0.frame.contains(mouse) } ?? overlays.first
        underMouse?.makeKey()
        NSCursor.crosshair.push()
        update()

        // Switching apps (⌘Tab) would leave the overlay up without keyboard focus.
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    private func finish(_ result: Selection?) {
        guard let continuation else { return }
        self.continuation = nil
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
        }
        NSCursor.pop()
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        continuation.resume(returning: result)
    }

    private func update() {
        for overlay in overlays {
            (overlay.contentView as? CaptureView)?.update()
        }
    }

    // MARK: Events

    func mouseMoved(to point: NSPoint) {
        mouse = point
        update()
    }

    func mouseDown(at point: NSPoint) {
        mouse = point
        guard mode == .area else { return }
        dragScreen = screens.first { $0.frame.contains(point) }?.frame
        dragStart = point
        selection = nil
        update()
    }

    func mouseDragged(to point: NSPoint) {
        guard mode == .area, var start = dragStart, let screen = dragScreen else { return }
        if isMoving {
            start.x += point.x - mouse.x
            start.y += point.y - mouse.y
            dragStart = start
        }
        mouse = point
        let end = NSPoint(x: max(screen.minX, min(point.x, screen.maxX)), y: max(screen.minY, min(point.y, screen.maxY)))
        let rect = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        selection = ScreenGeometry.integral(rect.intersection(screen))
        update()
    }

    func mouseUp(at point: NSPoint) {
        mouse = point
        switch mode {
        case .window:
            if let window = hoveredWindow { finish(.window(window)) }
        case .area:
            if let selection, selection.width >= 4, selection.height >= 4 {
                finish(.area(selection))
            } else {
                // Just a click: start over.
                dragStart = nil
                selection = nil
                update()
            }
        }
    }

    func keyDown(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Esc
            finish(nil)
        case 49 where !event.isARepeat: // Space
            if isDragging {
                isMoving = true
            } else {
                mode = mode == .area ? .window : .area
                selection = nil
                update()
            }
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "c", event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
                copyColor()
            }
        }
    }

    func keyUp(_ event: NSEvent) {
        if event.keyCode == 49 { isMoving = false }
    }

    /// Copies the color under the mouse as hex, and ends the capture.
    private func copyColor() {
        guard let color = screens.first(where: { $0.frame.contains(mouse) })?.color(at: mouse) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(color.hexString, forType: .string)
        finish(nil)
    }
}

/// A borderless window covering one screen, above everything including the menu bar.
private final class CaptureOverlayWindow: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

/// One screen's frozen picture, dimmed except for the selection, with a magnifier and the selection's size.
private final class CaptureView: NSView {
    // Weak: a late event may arrive after the capture ended.
    private weak var session: CaptureSession?
    private let screen: FrozenScreen
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let sizeLabel = HUDLabel()
    private let loupe: LoupeView

    init(session: CaptureSession, screen: FrozenScreen) {
        self.session = session
        self.screen = screen
        loupe = LoupeView(screen: screen)
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layer?.contents = screen.image
        layer?.contentsGravity = .resize

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        layer?.addSublayer(dimLayer)
        layer?.addSublayer(borderLayer)
        addSubview(sizeLabel)
        addSubview(loupe)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Drag to select an area. Press Space to pick a window, or Escape to cancel."))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func local(_ rect: NSRect) -> NSRect {
        rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    func update() {
        guard let session else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let area = session.highlight
        let highlight = area.map(local)
        let path = CGMutablePath()
        path.addRect(bounds)
        if let highlight { path.addRect(highlight) }
        dimLayer.path = path

        if let highlight {
            let isWindow = session.mode == .window
            borderLayer.path = CGPath(rect: highlight.insetBy(dx: isWindow ? 1.5 : 0.5, dy: isWindow ? 1.5 : 0.5), transform: nil)
            borderLayer.strokeColor = (isWindow ? NSColor.controlAccentColor : .white).cgColor
            borderLayer.lineWidth = isWindow ? 3 : 1
            borderLayer.fillColor = isWindow ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor : nil
        } else {
            borderLayer.path = nil
        }

        // The size, just below the highlighted area, or inside it when there's no room.
        if let area, let highlight, bounds.intersects(highlight) {
            let size = area.size
            sizeLabel.stringValue = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
            let labelSize = sizeLabel.fittingSize
            var origin = NSPoint(x: highlight.minX, y: highlight.minY - labelSize.height - 6)
            if origin.y < bounds.minY + 4 { origin.y = highlight.minY + 6 }
            origin.x = max(bounds.minX + 4, min(origin.x, bounds.maxX - labelSize.width - 4))
            sizeLabel.frame = NSRect(origin: origin, size: labelSize)
            sizeLabel.isHidden = false
        } else {
            sizeLabel.isHidden = true
        }

        // The magnifier follows the mouse, below and to the right, flipping sides near the edges.
        let mouse = NSPoint(x: session.mouse.x - screen.frame.minX, y: session.mouse.y - screen.frame.minY)
        loupe.isHidden = session.mode == .window || !bounds.contains(mouse)
        if !loupe.isHidden {
            loupe.mouse = session.mouse
            let size = loupe.frame.size
            var origin = NSPoint(x: mouse.x + 20, y: mouse.y - 20 - size.height)
            if origin.x + size.width > bounds.maxX { origin.x = mouse.x - 20 - size.width }
            if origin.y < bounds.minY { origin.y = min(mouse.y + 20, bounds.maxY - size.height) }
            loupe.setFrameOrigin(origin)
            loupe.needsDisplay = true
        }
    }

    // MARK: Events

    private func screenPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { session?.mouseMoved(to: screenPoint(event)) }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        session?.mouseDown(at: screenPoint(event))
    }
    override func mouseDragged(with event: NSEvent) { session?.mouseDragged(to: screenPoint(event)) }
    override func mouseUp(with event: NSEvent) { session?.mouseUp(at: screenPoint(event)) }
    override func keyDown(with event: NSEvent) { session?.keyDown(event) }
    override func keyUp(with event: NSEvent) { session?.keyUp(event) }
    override func rightMouseDown(with event: NSEvent) {} // no menus while capturing
}

/// Shows the pixels around the mouse, enlarged, with the color and position of the one in the middle.
private final class LoupeView: NSView {
    var mouse = NSPoint.zero
    private let screen: FrozenScreen
    private static let pixels = 15
    private static let cell: CGFloat = 8
    private static let captionHeight: CGFloat = 36

    init(screen: FrozenScreen) {
        self.screen = screen
        let side = CGFloat(Self.pixels) * Self.cell
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side + Self.captionHeight))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side = CGFloat(Self.pixels) * Self.cell
        let box = NSRect(x: 0, y: Self.captionHeight, width: side, height: side)
        let shape = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)

        // The pixels, square and sharp.
        let center = screen.pixel(at: mouse)
        let half = Self.pixels / 2
        let wanted = CGRect(x: center.x - half, y: center.y - half, width: Self.pixels, height: Self.pixels)
        let available = wanted.intersection(CGRect(x: 0, y: 0, width: screen.image.width, height: screen.image.height))
        context.saveGState()
        shape.addClip()
        NSColor.black.setFill()
        box.fill()
        if let crop = screen.image.cropping(to: available) {
            context.interpolationQuality = .none
            let destination = CGRect(x: box.minX + (available.minX - wanted.minX) * Self.cell,
                                     y: box.maxY - (available.maxY - wanted.minY) * Self.cell,
                                     width: available.width * Self.cell, height: available.height * Self.cell)
            context.draw(crop, in: destination)
        }
        // A faint grid, and the middle pixel outlined.
        NSColor.black.withAlphaComponent(0.08).setStroke()
        let grid = NSBezierPath()
        for i in 1..<Self.pixels {
            let offset = CGFloat(i) * Self.cell
            grid.move(to: NSPoint(x: box.minX + offset, y: box.minY))
            grid.line(to: NSPoint(x: box.minX + offset, y: box.maxY))
            grid.move(to: NSPoint(x: box.minX, y: box.minY + offset))
            grid.line(to: NSPoint(x: box.maxX, y: box.minY + offset))
        }
        grid.lineWidth = 0.5
        grid.stroke()
        let middle = NSRect(x: box.minX + CGFloat(half) * Self.cell, y: box.minY + CGFloat(half) * Self.cell, width: Self.cell, height: Self.cell)
        NSColor.black.setStroke()
        NSBezierPath(rect: middle.insetBy(dx: -1, dy: -1)).stroke()
        NSColor.white.setStroke()
        NSBezierPath(rect: middle).stroke()
        context.restoreGState()

        NSColor.white.withAlphaComponent(0.8).setStroke()
        shape.lineWidth = 2
        shape.stroke()

        // The caption: color, and position on this screen in points.
        let caption = NSRect(x: 0, y: 0, width: side, height: Self.captionHeight - 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: caption, xRadius: 6, yRadius: 6).fill()
        let color = screen.color(at: mouse)
        let x = Int(mouse.x - screen.frame.minX), y = Int(screen.frame.maxY - mouse.y)
        let lines = "\(color?.hexString ?? "")\n\(x), \(y)"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: lines, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        let height = text.boundingRect(with: caption.size, options: .usesLineFragmentOrigin).height
        text.draw(in: NSRect(x: caption.minX, y: caption.midY - height / 2, width: caption.width, height: height))
        if let color {
            color.setFill()
            let swatch = NSRect(x: caption.minX + 8, y: caption.midY - 5, width: 10, height: 10)
            NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
        }
    }
}
