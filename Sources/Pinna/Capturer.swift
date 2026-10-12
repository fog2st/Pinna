import AppKit
import ScreenCaptureKit

/// A screenshot and where it was on screen, so it can be pinned right back in place.
struct Capture {
    let screenshot: Screenshot
    let frame: NSRect
}

/// Takes screenshots. The screens are frozen first, then shown full-screen to select from, so menus and
/// hover effects stay put: drag to select an area, press Space to pick a window, Esc to cancel.
@MainActor
final class Capturer {
    /// The area captured last, for Capture Same Area Again.
    private(set) var lastArea: NSRect?
    private var isCapturing = false

    /// Returns nil if the user cancelled.
    func capture() async throws -> Capture? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        var screens: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
            let image = try await Self.captureDisplay(display, of: screen, excluding: [])
            screens.append(FrozenScreen(frame: screen.frame, scale: screen.backingScaleFactor, image: image))
        }
        guard !screens.isEmpty else { return nil }

        let session = CaptureSession(screens: screens, windows: PickableWindow.onScreen())
        switch await session.run() {
        case nil:
            return nil
        case .area(let rect):
            lastArea = rect
            return Self.crop(rect, from: screens)
        case .window(let window):
            lastArea = window.frame
            if let scWindow = content.windows.first(where: { $0.windowID == window.id }),
               let screenshot = try? await Self.captureWindow(scWindow) {
                return Capture(screenshot: screenshot, frame: window.frame)
            }
            return Self.crop(window.frame, from: screens)
        }
    }

    /// Captures the last area again, straight away. Pinna's own windows are left out, since a pin often sits right on it.
    func captureLastArea() async throws -> Capture? {
        guard let area = lastArea, !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        let screen = NSScreen.screens.max {
            $0.frame.intersection(area).width * $0.frame.intersection(area).height
                < $1.frame.intersection(area).width * $1.frame.intersection(area).height
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let screen, let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
        let pinna = content.applications.filter { $0.processID == getpid() }
        let image = try await Self.captureDisplay(display, of: screen, excluding: pinna)
        let frozen = FrozenScreen(frame: screen.frame, scale: screen.backingScaleFactor, image: image)
        return Self.crop(area.intersection(screen.frame), from: [frozen])
    }

    // MARK: Capturing

    private static func captureDisplay(_ display: SCDisplay, of screen: NSScreen,
                                       excluding apps: [SCRunningApplication]) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        configuration.height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Just the window, without its shadow or whatever covers it.
    private static func captureWindow(_ window: SCWindow) async throws -> Screenshot {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return Screenshot(image: image, scale: scale)
    }

    private static func crop(_ rect: NSRect, from screens: [FrozenScreen]) -> Capture? {
        guard let screen = screens.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }) ?? screens.first else { return nil }
        let visible = rect.intersection(screen.frame)
        let pixels = ScreenGeometry.pixelRect(of: visible, inScreen: screen.frame, scale: screen.scale)
        guard !visible.isEmpty, let image = screen.image.cropping(to: pixels) else { return nil }
        return Capture(screenshot: Screenshot(image: image, scale: screen.scale), frame: visible)
    }
}

/// A screen as it looked when the capture started.
struct FrozenScreen {
    let frame: NSRect
    let scale: CGFloat
    let image: CGImage

    /// The column and row (from the top) of the pixel under a point.
    func pixel(at point: NSPoint) -> (x: Int, y: Int) {
        ScreenGeometry.pixel(at: point, inScreen: frame, scale: scale, imageSize: (image.width, image.height))
    }

    /// The pixel under a point, as an sRGB color.
    func color(at point: NSPoint) -> NSColor? {
        let pixel = pixel(at: point)
        guard let single = image.cropping(to: CGRect(x: pixel.x, y: pixel.y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(single, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return NSColor(srgbRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
    }
}

/// A window that can be picked with Space.
struct PickableWindow {
    let id: CGWindowID
    let frame: NSRect

    /// The windows on screen, front to back: regular and floating ones, not the menu bar, Dock or desktop.
    @MainActor
    static func onScreen() -> [PickableWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let mainScreenHeight = ScreenGeometry.mainScreenHeight
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer] as? Int, layer >= 0, layer < Int(CGWindowLevelForKey(.dockWindow)),
                  info[kCGWindowAlpha] as? Double ?? 1 > 0,
                  let id = info[kCGWindowNumber] as? CGWindowID,
                  let bounds = info[kCGWindowBounds].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }),
                  bounds.width >= 20, bounds.height >= 20 else { return nil }
            return PickableWindow(id: id, frame: ScreenGeometry.appKitRect(fromCG: bounds, mainScreenHeight: mainScreenHeight))
        }
    }
}

extension NSColor {
    /// Like "#1E90FF".
    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        let parts = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }
}
