import AppKit

/// The sizing rules for a pin: how big the window is for a given screenshot size, and the other way round.
/// "Display size" is the size the screenshot is shown at, in points.
struct PinGeometry {
    /// The screenshot's real size, in points.
    var imageSize: NSSize
    /// Room around the screenshot: the title bar above it, a thin border on the other sides.
    var insets: NSEdgeInsets
    /// Room for the title bar's buttons; narrower screenshots are centered.
    var minWidth: CGFloat

    /// How far a screenshot can be zoomed out or in, relative to its real size.
    static let scaleRange: ClosedRange<CGFloat> = 0.1...8

    /// Which edge is being dragged, worked out at the start of a resize.
    enum ResizeAxis { case width, height, corner }

    func windowSize(display: NSSize) -> NSSize {
        NSSize(width: max(display.width.rounded() + insets.left + insets.right, minWidth),
               height: display.height.rounded() + insets.top + insets.bottom)
    }

    /// The room for the screenshot inside a window of `size`.
    func contentSize(window size: NSSize) -> NSSize {
        NSSize(width: max(0, size.width - insets.left - insets.right), height: max(0, size.height - insets.top - insets.bottom))
    }

    /// The scales at which the screenshot would fill a window of `size` across and down.
    func fittingScales(window size: NSSize) -> (width: CGFloat, height: CGFloat) {
        let content = contentSize(window: size)
        return (content.width / imageSize.width, content.height / imageSize.height)
    }

    /// The screenshot at `scale`, within the zoom limits.
    func display(scale: CGFloat) -> NSSize {
        let scale = clamp(scale)
        return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// Fits within a display size while keeping the screenshot's proportions and zoom limits.
    func clamped(_ display: NSSize) -> NSSize {
        self.display(scale: min(display.width / imageSize.width, display.height / imageSize.height))
    }

    /// The screenshot always fits inside the window without changing its proportions.
    func display(fillingWindow size: NSSize) -> NSSize {
        let fitting = fittingScales(window: size)
        let scale = max(0, min(fitting.width, fitting.height, Self.scaleRange.upperBound))
        return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// A free resize only limits the minimum size; width and height remain independent.
    func constrainedWindowSize(_ proposed: NSSize) -> NSSize {
        let minimum = windowSize(display: display(scale: Self.scaleRange.lowerBound))
        return NSSize(width: max(minimum.width, proposed.width), height: max(minimum.height, proposed.height))
    }

    /// Centers the proportionally fitted screenshot in the space below the title bar.
    func imageFrame(in bounds: NSRect) -> NSRect {
        let size = display(fillingWindow: bounds.size)
        let area = NSRect(x: bounds.minX + insets.left, y: bounds.minY + insets.bottom,
                          width: contentSize(window: bounds.size).width, height: contentSize(window: bounds.size).height)
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The display size for a window being resized to `proposed`, starting from `current`.
    func display(resizingTo proposed: NSSize, from current: NSSize, axis: ResizeAxis, keepingProportions: Bool) -> NSSize {
        guard keepingProportions else {
            return display(fillingWindow: proposed)
        }
        let fitting = fittingScales(window: proposed)
        let scale = current.width / imageSize.width
        // A screenshot narrower than the title bar can only follow the height.
        let fillsWidth = windowSize(display: current).width > minWidth
        let newScale = switch axis {
        case .width: fillsWidth ? fitting.width : scale
        case .height: fitting.height
        case .corner: fillsWidth ? max(fitting.width, fitting.height) : fitting.height
        }
        return display(scale: newScale)
    }

    /// The axis a resize follows, from how its first step changed the size.
    static func axis(from current: NSSize, to proposed: NSSize) -> ResizeAxis {
        proposed.height == current.height ? .width : proposed.width == current.width ? .height : .corner
    }

    /// `display` scaled by `factor`, keeping its shape, within the zoom limits.
    func zoomed(_ display: NSSize, by factor: CGFloat) -> NSSize {
        self.display(scale: min(display.width / imageSize.width, display.height / imageSize.height) * factor)
    }

    /// The largest display size, with the same shape, whose window fits in `bounds`.
    func display(fitting display: NSSize, in bounds: NSSize) -> NSSize {
        let room = contentSize(window: bounds)
        return zoomed(display, by: min(room.width / display.width, room.height / display.height))
    }

    /// Where a window of `newSize` goes so that `anchor` (a screen point) stays put, relative to `frame`.
    static func frame(resizing frame: NSRect, to newSize: NSSize, around anchor: NSPoint) -> NSRect {
        NSRect(x: anchor.x - (anchor.x - frame.minX) * newSize.width / frame.width,
               y: anchor.y - (anchor.y - frame.minY) * newSize.height / frame.height,
               width: newSize.width, height: newSize.height)
    }

    private func clamp(_ scale: CGFloat) -> CGFloat {
        max(Self.scaleRange.lowerBound, min(scale, Self.scaleRange.upperBound))
    }
}
