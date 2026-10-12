import AppKit

/// A dark rounded label, like "1280 × 720" next to a selection, or a pin's zoom level.
final class HUDLabel: NSTextField {
    init(fontSize: CGFloat = 12) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        textColor = .white
        alignment = .center
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        let size = super.fittingSize
        return NSSize(width: size.width + 14, height: size.height + 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Center the text in the padded box.
        let size = super.fittingSize
        let rect = NSRect(x: 7, y: (bounds.height - size.height) / 2, width: bounds.width - 14, height: size.height)
        attributedStringValue.draw(in: rect)
    }
}

/// Briefly shows a HUD label in the middle of a view, like "150%" while zooming.
@MainActor
final class Toast {
    private let label = HUDLabel(fontSize: 13)
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, in view: NSView) {
        if label.superview !== view {
            label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            view.addSubview(label)
        }
        label.stringValue = text
        let size = label.fittingSize
        label.frame = NSRect(x: ((view.bounds.width - size.width) / 2).rounded(), y: ((view.bounds.height - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
        label.alphaValue = 1
        label.isHidden = false
        hideTask?.cancel()
        hideTask = Task { [label] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                label.animator().alphaValue = 0
            }, completionHandler: nil)
        }
    }
}
