import AppKit

/// Lies over a pin's screenshot while marking up: draws the annotations, and turns drags into new ones.
@MainActor
final class MarkupView: NSView, NSTextFieldDelegate {
    let base: Screenshot
    private(set) var state = MarkupState()
    var tool = MarkupTool.arrow {
        didSet { commitText() }
    }
    var color = NSColor.systemRed
    var size = MarkupSize.medium
    /// Called when anything changes that the toolbar shows.
    var onChange: (() -> Void)?
    var onApply: (() -> Void)?
    var onCancel: (() -> Void)?

    private var undoStack: [MarkupState] = []
    private var redoStack: [MarkupState] = []
    /// The annotation being drawn, or the crop being dragged out.
    private var draft: Annotation?
    private var draftCrop: CGRect?
    private var dragStart: CGPoint?
    private var patches: [UUID: CGImage] = [:]
    private var textField: NSTextField?
    private var textOrigin: CGPoint?

    init(base: Screenshot) {
        self.base = base
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Coordinates

    /// Screenshot points per view point, across and down; different if the pin is stretched.
    private var scale: CGSize {
        CGSize(width: base.size.width / max(bounds.width, 1), height: base.size.height / max(bounds.height, 1))
    }

    private func imagePoint(_ point: NSPoint) -> CGPoint {
        let point = NSPoint(x: max(0, min(point.x, bounds.width)), y: max(0, min(point.y, bounds.height)))
        return CGPoint(x: point.x * scale.width, y: point.y * scale.height)
    }

    private func viewRect(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX / scale.width, y: rect.minY / scale.height, width: rect.width / scale.width, height: rect.height / scale.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: 1 / scale.width, y: 1 / scale.height)
        for annotation in state.annotations + [draft].compactMap({ $0 }) {
            MarkupRenderer.draw(annotation) { patch(for: $0) }
        }
        context.restoreGState()

        // Outside the crop is dimmed.
        if let crop = draftCrop ?? state.crop {
            let rect = viewRect(crop)
            let outside = NSBezierPath(rect: bounds)
            outside.append(NSBezierPath(rect: rect))
            outside.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill()
            outside.fill()
            let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            border.stroke()
        }
    }

    private func patch(for annotation: Annotation) -> CGImage? {
        if let patch = patches[annotation.id] { return patch }
        let patch = MarkupRenderer.pixelatedPatch(for: annotation, in: base)
        // Drafts change as they're dragged, so only finished annotations are kept.
        if draft?.id != annotation.id { patches[annotation.id] = patch }
        return patch
    }

    // MARK: Editing

    private func change(_ edit: (inout MarkupState) -> Void) {
        undoStack.append(state)
        redoStack.removeAll()
        edit(&state)
        needsDisplay = true
        onChange?()
    }

    func undo() {
        commitText()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        needsDisplay = true
        onChange?()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        needsDisplay = true
        onChange?()
    }

    /// Finishes any text being typed, so it's part of the state.
    func commitText() {
        guard let field = textField, let origin = textOrigin else { return }
        textField = nil
        textOrigin = nil
        field.delegate = nil
        field.removeFromSuperview()
        let text = field.stringValue
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            change { $0.annotations.append(Annotation(kind: .text(text, at: origin), color: color, size: size)) }
        }
        window?.makeFirstResponder(self)
    }

    // MARK: Mouse

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        if tool == .text {
            commitText()
            beginText(at: point)
            return
        }
        commitText()
        window?.makeFirstResponder(self)
        let start = imagePoint(point)
        dragStart = start
        switch tool {
        case .pen: draft = Annotation(kind: .pen([start]), color: color, size: size)
        case .highlighter: draft = Annotation(kind: .highlighter([start]), color: color, size: size)
        default: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = imagePoint(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)
        let rect = MarkupRenderer.rect(from: start, to: end, square: shift)
        switch tool {
        case .arrow:
            draft = Annotation(kind: .arrow(from: start, to: shift ? MarkupRenderer.snapped(end, from: start) : end), color: color, size: size)
        case .rectangle:
            draft = Annotation(kind: .rectangle(rect), color: color, size: size)
        case .ellipse:
            draft = Annotation(kind: .ellipse(rect), color: color, size: size)
        case .pen, .highlighter:
            guard var annotation = draft else { return }
            switch annotation.kind {
            case .pen(let points): annotation.kind = .pen(points + [end])
            case .highlighter(let points):
                // Shift keeps the highlighter on a straight line.
                annotation.kind = .highlighter(shift ? [points[0], MarkupRenderer.snapped(end, from: points[0])] : points + [end])
            default: break
            }
            draft = annotation
        case .pixelate:
            draft = Annotation(kind: .pixelate(rect), color: color, size: size)
        case .crop:
            draftCrop = MarkupRenderer.rect(from: start, to: end, square: false).integral
        case .text:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            draft = nil
            draftCrop = nil
            needsDisplay = true
        }
        if let crop = draftCrop, crop.width >= 4, crop.height >= 4 {
            change { $0.crop = crop }
        } else if let draft, isWorthKeeping(draft) {
            change { $0.annotations.append(draft) }
        }
    }

    /// Leaves out clicks that didn't drag far enough to draw anything.
    private func isWorthKeeping(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .arrow(let from, let to): hypot(to.x - from.x, to.y - from.y) >= 4
        case .rectangle(let rect), .ellipse(let rect), .pixelate(let rect): rect.width >= 3 && rect.height >= 3
        case .pen, .highlighter, .text: true
        }
    }

    // MARK: Text

    private func beginText(at point: NSPoint) {
        let font = MarkupRenderer.textFont(size: size, scale: 1 / scale.height)
        let field = NSTextField(string: "")
        field.font = font
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        let height = ceil(font.ascender - font.descender + font.leading) + 4
        // The click is where the text's baseline starts.
        field.frame = NSRect(x: point.x - 2, y: point.y + font.descender - 2, width: max(60, bounds.width - point.x + 2), height: height)
        addSubview(field)
        textField = field
        // Where the drawn text will go: the bottom-left of its line, below the baseline.
        textOrigin = imagePoint(NSPoint(x: point.x, y: point.y + font.descender))
        window?.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)) {
            commitText()
            return true
        }
        if selector == #selector(cancelOperation(_:)) {
            textField?.stringValue = ""
            commitText()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case 53: // Esc
            onCancel?()
        case 36, 76: // Return, Enter
            onApply?()
        case 51, 117: // Delete, Forward Delete: remove the last mark
            if !state.annotations.isEmpty { change { $0.annotations.removeLast() } }
        default:
            if flags.isDisjoint(with: [.command, .control, .option]),
               let tool = MarkupTool.allCases.first(where: { $0.key == event.charactersIgnoringModifiers?.lowercased() }) {
                self.tool = tool
                window?.invalidateCursorRects(for: self)
                onChange?()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.charactersIgnoringModifiers?.lowercased() == "z", flags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if flags.contains(.shift) { redo() } else { undo() }
        return true
    }
}

/// The tools, colors and sizes for marking up a pin, in a bar below it.
@MainActor
final class MarkupToolbar: NSPanel {
    private unowned let markup: MarkupView
    private let tools = FirstMouseSegmentedControl()
    private let sizes = FirstMouseSegmentedControl()
    private var colorButtons: [ColorSwatch] = []
    private let undoButton = FirstMouseButton()
    private let redoButton = FirstMouseButton()

    static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]

    init(markup: MarkupView) {
        self.markup = markup
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        tools.segmentCount = MarkupTool.allCases.count
        tools.trackingMode = .selectOne
        for (index, tool) in MarkupTool.allCases.enumerated() {
            tools.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: index)
            tools.setToolTip("\(tool.title) (\(tool.key.uppercased()))", forSegment: index)
            tools.setWidth(30, forSegment: index)
        }
        tools.target = self
        tools.action = #selector(pickTool)

        for color in Self.colors {
            let swatch = ColorSwatch(color: color)
            swatch.target = self
            swatch.action = #selector(pickColor)
            colorButtons.append(swatch)
        }

        sizes.segmentCount = MarkupSize.allCases.count
        sizes.trackingMode = .selectOne
        let sizeNames = [String(localized: "Thin"), String(localized: "Medium"), String(localized: "Thick")]
        for size in MarkupSize.allCases {
            sizes.setImage(Self.dot(diameter: [4, 7, 11][size.rawValue]), forSegment: size.rawValue)
            sizes.setToolTip(sizeNames[size.rawValue], forSegment: size.rawValue)
            sizes.setWidth(26, forSegment: size.rawValue)
        }
        sizes.target = self
        sizes.action = #selector(pickSize)

        configure(undoButton, symbol: "arrow.uturn.backward", title: String(localized: "Undo"), action: #selector(undo))
        configure(redoButton, symbol: "arrow.uturn.forward", title: String(localized: "Redo"), action: #selector(redo))

        let cancel = FirstMouseButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
        let done = FirstMouseButton(title: String(localized: "Done"), target: self, action: #selector(done))
        done.bezelColor = .controlAccentColor
        done.keyEquivalent = "\r"
        for button in [cancel, done] {
            button.controlSize = .small
            button.bezelStyle = .push
        }

        let colors = NSStackView(views: colorButtons)
        colors.spacing = 4
        let stack = NSStackView(views: [tools, separator(), colors, separator(), sizes, separator(), undoButton, redoButton, separator(), cancel, done])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        contentView = background
        setContentSize(background.fittingSize)
        showMarkupState()
    }

    private func configure(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.isBordered = false
        button.toolTip = title
        button.target = self
        button.action = action
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }

    private static func dot(diameter: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Shows the markup view's current tool, color, size and undo state.
    func showMarkupState() {
        tools.selectedSegment = MarkupTool.allCases.firstIndex(of: markup.tool) ?? 0
        sizes.selectedSegment = markup.size.rawValue
        for swatch in colorButtons {
            swatch.isSelected = swatch.color == markup.color
        }
        undoButton.isEnabled = markup.canUndo
        redoButton.isEnabled = markup.canRedo
    }

    /// Below `frame` (the pin), or above it if there's no room, kept on `screen`.
    func place(around frame: NSRect, on screen: NSRect) {
        var origin = NSPoint(x: frame.midX - self.frame.width / 2, y: frame.minY - self.frame.height - 8)
        if origin.y < screen.minY { origin.y = frame.maxY + 8 }
        origin.x = max(screen.minX + 4, min(origin.x, screen.maxX - self.frame.width - 4))
        setFrameOrigin(origin)
    }

    @objc private func pickTool() {
        markup.tool = MarkupTool.allCases[tools.selectedSegment]
        markup.window?.invalidateCursorRects(for: markup)
        markup.window?.makeFirstResponder(markup)
    }

    @objc private func pickColor(_ sender: ColorSwatch) {
        markup.color = sender.color
        showMarkupState()
    }

    @objc private func pickSize() {
        markup.size = MarkupSize(rawValue: sizes.selectedSegment) ?? .medium
    }

    @objc private func undo() { markup.undo() }
    @objc private func redo() { markup.redo() }
    @objc private func cancel() { markup.onCancel?() }
    @objc private func done() { markup.onApply?() }
}

/// Controls in panels that don't take focus need to act on the first click.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseSegmentedControl: NSSegmentedControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A round color button, ringed when it's the current color.
final class ColorSwatch: NSButton {
    let color: NSColor
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        isBordered = false
        title = ""
        setAccessibilityLabel(color.accessibilityName)
        toolTip = color.accessibilityName.capitalized
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
        color.setFill()
        circle.fill()
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
        if isSelected {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            NSColor.labelColor.setStroke()
            ring.stroke()
        }
    }
}
