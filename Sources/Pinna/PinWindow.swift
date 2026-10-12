import AppKit
import UniformTypeIdentifiers
@preconcurrency import VisionKit

/// What makes up a pin. Kept when a pin is closed (to reopen it), moved to another Space, or saved for next time.
struct PinState {
    var id = UUID()
    var screenshot: Screenshot
    /// The window's bottom-left corner.
    var origin: NSPoint
    /// The size the screenshot is shown at, in points.
    var display: NSSize
    /// Whether the screenshot was stretched out of its proportions.
    var isStretched = false
    var keepsProportions = Preferences.keepsProportions
    var opacity: CGFloat = 1
    var keepsOnTop = Preferences.keepsOnTop
    var showsOnAllSpaces = Preferences.showsOnAllSpaces
}

/// A window showing one screenshot on a blurred, see-through background. It stays on the desktop it was
/// pinned on unless set to show on all Spaces, and floats above other windows unless the pin in its title bar is off.
final class PinWindow: NSPanel, NSWindowDelegate {
    let id: UUID
    private(set) var screenshot: Screenshot
    var onClose: ((PinWindow) -> Void)?
    /// Called when something worth saving changes: position, size, settings, or the screenshot itself.
    var onChange: ((PinWindow) -> Void)?
    /// Hidden with Hide All Pins, as opposed to closed or minimized.
    var isHiddenByUser = false

    private var geometry: PinGeometry
    private var display: NSSize
    private var isStretched: Bool {
        didSet { pinView.isStretched = isStretched }
    }
    private(set) var keepsProportions: Bool
    private(set) var keepsOnTop: Bool
    private(set) var showsOnAllSpaces: Bool
    private(set) var isClickThrough = false
    private var resizeAxis: PinGeometry.ResizeAxis?

    private let pinView: PinView
    private let keepOnTopButton = TitlebarButton(symbol: "pin", selectedSymbol: "pin.fill",
                                                 title: String(localized: "Keep on Top"))
    private let liveTextButton = TitlebarButton(symbol: "text.viewfinder", selectedSymbol: "text.viewfinder",
                                                title: String(localized: "Live Text: select text in the screenshot"))
    private let markupButton = TitlebarButton(symbol: "pencil.tip.crop.circle", selectedSymbol: "pencil.tip.crop.circle.fill",
                                              title: String(localized: "Markup"))
    private var markupToolbar: MarkupToolbar?
    private let toast = Toast()
    private static let analyzer = ImageAnalyzer()
    private var analysis: ImageAnalysis?
    private var analysisCallbacks: [(ImageAnalysis?) -> Void] = []

    /// `imageFrame`, if given, is where the screenshot goes on screen, and the window is built around it.
    /// Otherwise the window goes at the state's origin.
    init(state: PinState, imageFrame: NSRect? = nil) {
        id = state.id
        screenshot = state.screenshot
        display = state.display
        isStretched = state.isStretched
        keepsProportions = state.keepsProportions
        keepsOnTop = state.keepsOnTop
        showsOnAllSpaces = state.showsOnAllSpaces
        let titlebarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: .titled).height
        let insets = NSEdgeInsets(top: titlebarHeight, left: 6, bottom: 6, right: 6)
        geometry = PinGeometry(imageSize: state.screenshot.size, insets: insets, minWidth: 0)
        pinView = PinView(screenshot: state.screenshot, insets: insets)
        pinView.isStretched = state.isStretched

        super.init(contentRect: NSRect(origin: state.origin, size: .zero),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = String(localized: "Pinned Screenshot")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        alphaValue = state.opacity
        delegate = self
        applyLevel()
        applySpaces()

        pinView.menu = makeMenu()
        contentView = pinView
        let accessory = makeTitlebarAccessory()
        addTitlebarAccessoryViewController(accessory)
        geometry.minWidth = (standardWindowButton(.zoomButton)?.frame.maxX ?? 70) + 12 + accessory.view.frame.width

        let size = geometry.windowSize(display: display)
        let origin = imageFrame.map { NSPoint(x: $0.midX - size.width / 2, y: $0.minY - insets.bottom) } ?? state.origin
        setFrame(NSRect(origin: origin, size: size), display: false)
        addAccessibilityActions()
    }

    var state: PinState {
        PinState(id: id, screenshot: screenshot, origin: frame.origin, display: display, isStretched: isStretched,
                 keepsProportions: keepsProportions, opacity: alphaValue, keepsOnTop: keepsOnTop, showsOnAllSpaces: showsOnAllSpaces)
    }

    override func close() {
        finishMarkup(apply: false)
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

    private func applyLevel() {
        level = keepsOnTop ? .floating : .normal
        keepOnTopButton.state = keepsOnTop ? .on : .off
    }

    private func applySpaces() {
        // Floating windows follow you to every desktop unless they're managed.
        collectionBehavior = showsOnAllSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed, .fullScreenAuxiliary]
    }

    private func showToast(_ text: String) {
        toast.show(text, in: pinView)
    }

    // MARK: Menu and title bar

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
        }
        add(String(localized: "Copy"), #selector(copyImage), "c")
        add(String(localized: "Copy Text"), #selector(copyText), "c", [.shift, .command])
        add(String(localized: "Save As…"), #selector(saveImage), "s")
        menu.addItem(.separator())
        add(String(localized: "Markup"), #selector(toggleMarkup), "a", [.shift, .command])
        add(String(localized: "Select Text"), #selector(toggleLiveText), "t")
        menu.addItem(.separator())
        add(String(localized: "Zoom In"), #selector(zoomIn), "=")
        add(String(localized: "Zoom Out"), #selector(zoomOut), "-")
        add(String(localized: "Actual Size"), #selector(actualSize), "0")
        add(String(localized: "Keep Proportions"), #selector(toggleKeepsProportions))

        let opacity = NSMenu()
        for percent in [100, 80, 60, 40, 20] {
            let item = opacity.addItem(withTitle: "\(percent)%", action: #selector(setOpacity), keyEquivalent: "")
            item.tag = percent
            item.target = self
        }
        menu.addItem(withTitle: String(localized: "Opacity"), action: nil, keyEquivalent: "").submenu = opacity
        menu.addItem(.separator())
        add(String(localized: "Keep on Top"), #selector(toggleKeepOnTop))
        add(String(localized: "Show on All Spaces"), #selector(toggleShowsOnAllSpaces))
        add(String(localized: "Click Through"), #selector(toggleClickThrough))
        menu.addItem(.separator())
        add(String(localized: "Close"), #selector(close), "w")
        return menu
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleKeepOnTop): item.state = keepsOnTop ? .on : .off
        case #selector(toggleShowsOnAllSpaces): item.state = showsOnAllSpaces ? .on : .off
        case #selector(toggleKeepsProportions): item.state = keepsProportions ? .on : .off
        case #selector(toggleClickThrough): item.state = isClickThrough ? .on : .off
        case #selector(toggleLiveText): item.state = liveTextButton.state
        case #selector(toggleMarkup): item.state = markupToolbar != nil ? .on : .off
        case #selector(setOpacity): item.state = Int((alphaValue * 100).rounded()) == item.tag ? .on : .off
        default: return super.validateMenuItem(item)
        }
        return true
    }

    private func makeTitlebarAccessory() -> NSTitlebarAccessoryViewController {
        keepOnTopButton.target = self
        keepOnTopButton.action = #selector(toggleKeepOnTop)
        keepOnTopButton.toolTip = String(localized: "Keep on top of other windows")
        liveTextButton.target = self
        liveTextButton.action = #selector(toggleLiveText)
        markupButton.target = self
        markupButton.action = #selector(toggleMarkup)

        // Centered in the title bar, as far from the corner as the window buttons are from theirs.
        let buttons = [liveTextButton, markupButton, keepOnTopButton]
        let width = buttons.reduce(0) { $0 + $1.frame.width + 2 } + 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: geometry.insets.top))
        var x: CGFloat = 0
        for button in buttons {
            button.frame.origin = NSPoint(x: x, y: (container.frame.height - button.frame.height) / 2)
            button.autoresizingMask = [.minYMargin, .maxYMargin]
            container.addSubview(button)
            x += button.frame.width + 2
        }

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        return accessory
    }

    private func addAccessibilityActions() {
        func action(_ name: String, _ perform: @escaping (PinWindow) -> Void) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self else { return false }
                perform(self)
                return true
            }
        }
        pinView.setAccessibilityCustomActions([
            action(String(localized: "Copy")) { $0.copyImage() },
            action(String(localized: "Copy Text")) { $0.copyText() },
            action(String(localized: "Save As…")) { $0.saveImage() },
            action(String(localized: "Markup")) { $0.toggleMarkup() },
            action(String(localized: "Close")) { $0.close() },
        ])
    }

    // MARK: Actions

    @objc func copyImage() {
        if let overlay = pinView.liveTextOverlay, overlay.hasActiveTextSelection {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(overlay.selectedText, forType: .string)
            showToast(String(localized: "Copied Text"))
        } else {
            screenshot.copyToPasteboard()
            showToast(String(localized: "Copied"))
        }
    }

    /// Copies all the text found in the screenshot.
    @objc func copyText() {
        withAnalysis { [weak self] analysis in
            guard let self else { return }
            let text = analysis?.transcript ?? ""
            if text.isEmpty {
                showToast(String(localized: "No Text Found"))
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                showToast(String(localized: "Copied Text"))
            }
        }
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

    @objc func toggleKeepOnTop() {
        keepsOnTop.toggle()
        applyLevel()
        onChange?(self)
    }

    @objc func toggleShowsOnAllSpaces() {
        showsOnAllSpaces.toggle()
        applySpaces()
        onChange?(self)
    }

    @objc func toggleKeepsProportions() {
        keepsProportions.toggle()
        if keepsProportions, isStretched {
            // Back to the screenshot's own shape, no bigger than it was.
            let scale = min(display.width / geometry.imageSize.width, display.height / geometry.imageSize.height)
            isStretched = false
            resize(to: geometry.display(scale: scale), around: NSPoint(x: frame.midX, y: frame.maxY))
        }
        showToast(keepsProportions ? String(localized: "Keeps Proportions") : String(localized: "Stretches Freely"))
        onChange?(self)
    }

    /// Clicks go through to the window behind. Turned off again from the menu bar icon.
    @objc func toggleClickThrough() {
        setClickThrough(!isClickThrough)
    }

    func setClickThrough(_ on: Bool) {
        isClickThrough = on
        ignoresMouseEvents = on
        if on {
            showToast(String(localized: "Click-through on. Turn it off from the menu bar icon."))
        }
    }

    @objc func setOpacity(_ sender: NSMenuItem) {
        alphaValue = CGFloat(sender.tag) / 100
        onChange?(self)
    }

    func changeOpacity(by delta: CGFloat) {
        alphaValue = max(0.15, min(alphaValue + delta, 1))
        showToast(String(localized: "Opacity \(Int((alphaValue * 100).rounded()))%"))
        onChange?(self)
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY + dy))
    }

    // MARK: Live Text

    @objc func toggleLiveText() {
        // The button is on while the text is still being found, too.
        setLiveText(liveTextButton.state != .on)
    }

    private func setLiveText(_ on: Bool) {
        guard on else {
            pinView.showLiveText(nil)
            liveTextButton.state = .off
            return
        }
        finishMarkup(apply: true)
        liveTextButton.state = .on
        withAnalysis { [weak self] analysis in
            guard let self, liveTextButton.state == .on else { return }
            if let analysis, analysis.hasResults(for: .text) || analysis.hasResults(for: .machineReadableCode) {
                pinView.showLiveText(analysis)
            } else {
                liveTextButton.state = .off
                showToast(String(localized: "No Text Found"))
            }
        }
    }

    /// Finds the text in the screenshot, once, and passes it on.
    private func withAnalysis(_ body: @escaping (ImageAnalysis?) -> Void) {
        if let analysis { return body(analysis) }
        analysisCallbacks.append(body)
        guard analysisCallbacks.count == 1 else { return } // already looking
        let screenshot = screenshot
        Task {
            let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            let result = try? await Self.analyzer.analyze(screenshot.image, orientation: .up, configuration: configuration)
            guard screenshot === self.screenshot else { return } // marked up meanwhile
            analysis = result
            let callbacks = analysisCallbacks
            analysisCallbacks = []
            callbacks.forEach { $0(result) }
        }
    }

    // MARK: Markup

    @objc func toggleMarkup() {
        if markupToolbar == nil { beginMarkup() } else { finishMarkup(apply: true) }
    }

    private func beginMarkup() {
        guard markupToolbar == nil, !isClickThrough else { return }
        setLiveText(false)
        let markup = MarkupView(base: screenshot)
        let toolbar = MarkupToolbar(markup: markup)
        markup.onChange = { [weak toolbar] in toolbar?.showMarkupState() }
        markup.onApply = { [weak self] in self?.finishMarkup(apply: true) }
        markup.onCancel = { [weak self] in self?.finishMarkup(apply: false) }
        pinView.markupView = markup
        markupToolbar = toolbar
        addChildWindow(toolbar, ordered: .above)
        placeToolbar()
        markupButton.state = .on
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(markup)
    }

    /// Ends marking up; if `apply`, the marks are drawn into the screenshot, which is copied again.
    func finishMarkup(apply: Bool) {
        guard let toolbar = markupToolbar, let markup = pinView.markupView else { return }
        markup.commitText()
        let markupState = markup.state
        removeChildWindow(toolbar)
        toolbar.orderOut(nil)
        markupToolbar = nil
        pinView.markupView = nil
        markupButton.state = .off
        makeFirstResponder(pinView)
        guard apply, !markupState.isEmpty else { return }

        let edited = MarkupRenderer.render(markupState, on: screenshot)
        replaceScreenshot(with: edited, cropped: markupState.crop)
        edited.copyToPasteboard()
        showToast(String(localized: "Copied"))
    }

    private func placeToolbar() {
        guard let toolbar = markupToolbar, let screen = screen ?? NSScreen.main else { return }
        toolbar.place(around: frame, on: screen.visibleFrame)
    }

    /// Shows a new version of the screenshot. A cropped one stays where that part was on screen, at the same zoom.
    private func replaceScreenshot(with edited: Screenshot, cropped crop: CGRect?) {
        let old = screenshot.size
        let shown = convertToScreen(pinView.convert(pinView.screenshotFrame, to: nil))
        let scale = CGSize(width: shown.width / old.width, height: shown.height / old.height)
        let kept = crop ?? CGRect(origin: .zero, size: old)
        let imageFrame = NSRect(x: shown.minX + kept.minX * scale.width, y: shown.minY + kept.minY * scale.height,
                                width: kept.width * scale.width, height: kept.height * scale.height)

        screenshot = edited
        analysis = nil
        analysisCallbacks = []
        geometry.imageSize = edited.size
        pinView.screenshot = edited
        display = geometry.clamped(imageFrame.size)
        let size = geometry.windowSize(display: display)
        setFrame(NSRect(x: imageFrame.midX - size.width / 2, y: imageFrame.minY - geometry.insets.bottom,
                        width: size.width, height: size.height), display: true)
        onChange?(self)
    }

    // MARK: Sizing

    @objc func zoomIn() { zoom(by: 1.25) }
    @objc func zoomOut() { zoom(by: 0.8) }

    @objc func actualSize() {
        isStretched = false
        resize(to: geometry.imageSize, around: NSPoint(x: frame.midX, y: frame.midY))
        showToast("100%")
    }

    /// Resizes the window, keeping `anchor` (a screen point) fixed; defaults to the center.
    func zoom(by factor: CGFloat, around anchor: NSPoint? = nil) {
        let newDisplay = geometry.zoomed(display, by: factor)
        guard abs(newDisplay.width - display.width) > 0.01 else { return }
        resize(to: newDisplay, around: anchor ?? NSPoint(x: frame.midX, y: frame.midY))
        showToast("\(Int((newDisplay.width / geometry.imageSize.width * 100).rounded()))%")
    }

    private func resize(to newDisplay: NSSize, around anchor: NSPoint) {
        display = newDisplay
        setFrame(PinGeometry.frame(resizing: frame, to: geometry.windowSize(display: newDisplay), around: anchor), display: true)
        onChange?(self)
    }

    func windowDidResize(_ notification: Notification) {
        placeToolbar()
        // Keep the exact size while the window matches it (small zoom steps round to the same size);
        // otherwise something else resized the window, like dragging an edge or the green button.
        let expected = geometry.windowSize(display: display)
        guard abs(frame.width - expected.width) > 1 || abs(frame.height - expected.height) > 1 else { return }
        display = geometry.display(fillingWindow: frame.size, keepingProportions: !isStretched)
    }

    /// Keeps the screenshot's proportions while an edge or corner is dragged, unless set to stretch freely.
    /// Holding Shift does the opposite of the setting.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Work out which edge is being dragged from the first step and stick with it. Deciding at every
        // step made corner drags flip between following the width and the height, which flickered.
        let axis = resizeAxis ?? PinGeometry.axis(from: frame.size, to: frameSize)
        if inLiveResize { resizeAxis = axis }

        let proportional = keepsProportions != NSEvent.modifierFlags.contains(.shift)
        isStretched = !proportional
        let newDisplay = geometry.display(resizingTo: frameSize, from: display, axis: axis, keepingProportions: proportional)
        return geometry.windowSize(display: newDisplay)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        resizeAxis = nil
        onChange?(self)
    }

    func windowDidMove(_ notification: Notification) {
        placeToolbar()
        onChange?(self)
    }

    /// The green button fits the screenshot to the screen, keeping its current shape.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let size = geometry.windowSize(display: geometry.display(fitting: display, in: newFrame.size))
        return NSRect(x: newFrame.midX - size.width / 2, y: newFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: Menu bar

    /// A small picture of the screenshot for the menu bar's list of pins.
    func thumbnail(height: CGFloat) -> NSImage {
        let size = screenshot.size
        let width = min(height * 2.5, max(height * 0.5, size.width * height / size.height))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { [screenshot] rect in
            let fit = min(rect.width / size.width, rect.height / size.height)
            let drawn = NSRect(x: rect.midX - size.width * fit / 2, y: rect.midY - size.height * fit / 2,
                               width: size.width * fit, height: size.height * fit)
            NSBezierPath(roundedRect: drawn, xRadius: 3, yRadius: 3).addClip()
            screenshot.nsImage.draw(in: drawn)
            return true
        }
        return image
    }
}

/// A round title bar button with a symbol, filled with the accent color while on.
private final class TitlebarButton: NSButton {
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(symbol: String, selectedSymbol: String, title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        setButtonType(.toggle)
        isBordered = false
        imagePosition = .imageOnly
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(configuration)
        alternateImage = NSImage(systemSymbolName: selectedSymbol, accessibilityDescription: title)?.withSymbolConfiguration(configuration)
        toolTip = title
        updateTint()
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
        // The action sets the state itself, so undo the click's toggle first.
        state = state == .on ? .off : .on
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
