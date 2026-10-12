import AppKit

/// Converting between the screen coordinates AppKit and CoreGraphics use.
/// AppKit measures from the bottom-left of the main screen, upwards; CoreGraphics from its top-left, downwards.
enum ScreenGeometry {
    /// The height of the main screen (the one with the menu bar), which both systems are measured from.
    @MainActor
    static var mainScreenHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func appKitRect(fromCG rect: CGRect, mainScreenHeight: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: mainScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cgPoint(fromAppKit point: NSPoint, mainScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainScreenHeight - point.y)
    }

    /// The pixels of a capture of `screenFrame`, taken at `scale`, that show `rect`. Pixel rows count from the top.
    static func pixelRect(of rect: NSRect, inScreen screenFrame: NSRect, scale: CGFloat) -> CGRect {
        let minX = ((rect.minX - screenFrame.minX) * scale).rounded()
        let minY = ((screenFrame.maxY - rect.maxY) * scale).rounded()
        let maxX = ((rect.maxX - screenFrame.minX) * scale).rounded()
        let maxY = ((screenFrame.maxY - rect.minY) * scale).rounded()
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The column and row (counting from the top) of the pixel under `point`, kept inside the image.
    static func pixel(at point: NSPoint, inScreen screenFrame: NSRect, scale: CGFloat, imageSize: (width: Int, height: Int)) -> (x: Int, y: Int) {
        let x = Int(((point.x - screenFrame.minX) * scale).rounded(.down))
        let y = Int(((screenFrame.maxY - point.y) * scale).rounded(.down))
        return (max(0, min(x, imageSize.width - 1)), max(0, min(y, imageSize.height - 1)))
    }

    /// A rect with its corners moved to whole points, so it covers whole pixels at any scale.
    static func integral(_ rect: NSRect) -> NSRect {
        let minX = rect.minX.rounded(), minY = rect.minY.rounded()
        return NSRect(x: minX, y: minY, width: rect.maxX.rounded() - minX, height: rect.maxY.rounded() - minY)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The screen the mouse is on.
    @MainActor
    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}
