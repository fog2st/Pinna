import AppKit

/// A mark drawn on a screenshot. Positions are in the screenshot's points, measured from its bottom-left.
struct Annotation: Identifiable {
    enum Kind {
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case pen([CGPoint])
        case highlighter([CGPoint])
        case text(String, at: CGPoint)
        case pixelate(CGRect)
    }

    let id = UUID()
    var kind: Kind
    var color: NSColor
    var size: MarkupSize
}

enum MarkupSize: Int, CaseIterable {
    case small, medium, large

    var lineWidth: CGFloat { [2, 4, 8][rawValue] }
    var fontSize: CGFloat { [14, 20, 32][rawValue] }
    /// How big the blocks of a pixelated area are.
    var pixelBlock: CGFloat { [5, 9, 15][rawValue] }
    var highlighterWidth: CGFloat { [10, 18, 30][rawValue] }
}

enum MarkupTool: CaseIterable {
    case arrow, rectangle, ellipse, pen, highlighter, text, pixelate, crop

    var title: String {
        switch self {
        case .arrow: String(localized: "Arrow")
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Ellipse")
        case .pen: String(localized: "Pen")
        case .highlighter: String(localized: "Highlighter")
        case .text: String(localized: "Text")
        case .pixelate: String(localized: "Pixelate")
        case .crop: String(localized: "Crop")
        }
    }

    var symbol: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .pixelate: "checkerboard.rectangle"
        case .crop: "crop"
        }
    }

    /// The letter that picks the tool while marking up.
    var key: String {
        switch self {
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .pixelate: "b"
        case .crop: "c"
        }
    }
}

/// Everything drawn on a screenshot so far, and the part to keep.
struct MarkupState {
    var annotations: [Annotation] = []
    var crop: CGRect?

    var isEmpty: Bool { annotations.isEmpty && crop == nil }
}

/// Draws annotations, both on screen while marking up and into the finished image.
@MainActor
enum MarkupRenderer {
    /// Draws into the current graphics context, which is set up in screenshot points.
    /// `patch` gives the pixelated picture for a pixelate annotation.
    static func draw(_ annotation: Annotation, patch: (Annotation) -> CGImage?) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let width = annotation.size.lineWidth

        switch annotation.kind {
        case .arrow(let from, let to):
            guard let (shaft, head) = arrowPaths(from: from, to: to, lineWidth: width) else { return }
            context.setStrokeColor(annotation.color.cgColor)
            context.setFillColor(annotation.color.cgColor)
            context.setLineWidth(width)
            context.addPath(shaft)
            context.strokePath()
            context.addPath(head)
            context.drawPath(using: .fillStroke)
        case .rectangle(let rect):
            context.setStrokeColor(annotation.color.cgColor)
            context.setLineWidth(width)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: min(width, rect.width / 2), cornerHeight: min(width, rect.height / 2), transform: nil))
            context.strokePath()
        case .ellipse(let rect):
            context.setStrokeColor(annotation.color.cgColor)
            context.setLineWidth(width)
            context.strokeEllipse(in: rect)
        case .pen(let points):
            context.setStrokeColor(annotation.color.cgColor)
            context.setLineWidth(width)
            context.addPath(smoothPath(through: points))
            context.strokePath()
        case .highlighter(let points):
            context.setStrokeColor(annotation.color.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(annotation.size.highlighterWidth)
            context.setLineCap(.square)
            context.addPath(smoothPath(through: points))
            context.strokePath()
        case .text(let string, let origin):
            attributedText(string, color: annotation.color, size: annotation.size).draw(at: origin)
        case .pixelate(let rect):
            if let image = patch(annotation) {
                context.interpolationQuality = .none
                context.draw(image, in: rect)
            }
        }
    }

    static func attributedText(_ string: String, color: NSColor, size: MarkupSize) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: textFont(size: size),
            .foregroundColor: color,
        ])
    }

    static func textFont(size: MarkupSize, scale: CGFloat = 1) -> NSFont {
        .systemFont(ofSize: size.fontSize * scale, weight: .semibold)
    }

    /// The finished screenshot: the annotations drawn in, then cropped.
    static func render(_ state: MarkupState, on base: Screenshot) -> Screenshot {
        let width = base.image.width, height = base.image.height
        let space = base.image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        context.draw(base.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: base.scale, y: base.scale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for annotation in state.annotations {
            draw(annotation) { pixelatedPatch(for: $0, in: base) }
        }
        NSGraphicsContext.restoreGraphicsState()

        guard var image = context.makeImage() else { return base }
        if let crop = state.crop {
            let pixels = ScreenGeometry.pixelRect(of: crop, inScreen: NSRect(origin: .zero, size: base.size), scale: base.scale)
            image = image.cropping(to: pixels) ?? image
        }
        return Screenshot(image: image, scale: base.scale)
    }

    /// The part of the screenshot under a pixelate annotation, in big square blocks, each the average of its pixels.
    static func pixelatedPatch(for annotation: Annotation, in base: Screenshot) -> CGImage? {
        guard case .pixelate(let rect) = annotation.kind else { return nil }
        let pixels = ScreenGeometry.pixelRect(of: rect, inScreen: NSRect(origin: .zero, size: base.size), scale: base.scale)
            .intersection(CGRect(x: 0, y: 0, width: base.image.width, height: base.image.height))
        guard !pixels.isEmpty, let crop = base.image.cropping(to: pixels),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let block = max(1, (annotation.size.pixelBlock * base.scale).rounded())
        let columns = Int((pixels.width / block).rounded(.up)), rows = Int((pixels.height / block).rounded(.up))
        let width = Int(pixels.width), height = Int(pixels.height)

        // Shrink to one pixel per block, which averages them, then blow back up without smoothing.
        // Blocks at the edges are evened out a little so they all fit.
        guard let small = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let large = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        small.interpolationQuality = .high
        small.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let averaged = small.makeImage() else { return nil }
        large.interpolationQuality = .none
        large.draw(averaged, in: CGRect(x: 0, y: 0, width: width, height: height))
        return large.makeImage()
    }

    // MARK: Shapes

    /// An arrow's line, and its head as a triangle, for a line `lineWidth` thick.
    static func arrowPaths(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) -> (shaft: CGPath, head: CGPath)? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let headLength = min(length, max(12, lineWidth * 4))
        let headWidth = headLength * 0.85
        let unit = CGPoint(x: dx / length, y: dy / length)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        let base = CGPoint(x: end.x - unit.x * headLength, y: end.y - unit.y * headLength)

        let shaft = CGMutablePath()
        shaft.move(to: start)
        shaft.addLine(to: CGPoint(x: base.x + unit.x, y: base.y + unit.y))
        let head = CGMutablePath()
        head.move(to: end)
        head.addLine(to: CGPoint(x: base.x + normal.x * headWidth / 2, y: base.y + normal.y * headWidth / 2))
        head.addLine(to: CGPoint(x: base.x - normal.x * headWidth / 2, y: base.y - normal.y * headWidth / 2))
        head.closeSubpath()
        return (shaft, head)
    }

    /// A line through the points, rounded off between them.
    static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
            return path
        }
        for i in 1..<points.count {
            let middle = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: middle, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// The rect between two points; with `square`, made a square (for Shift).
    static func rect(from start: CGPoint, to end: CGPoint, square: Bool) -> CGRect {
        var end = end
        if square {
            let side = max(abs(end.x - start.x), abs(end.y - start.y))
            end = CGPoint(x: start.x + (end.x < start.x ? -side : side), y: start.y + (end.y < start.y ? -side : side))
        }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// `end`, moved onto the nearest 45° line from `start` (for Shift).
    static func snapped(_ end: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }
}
