import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An image to pin: a screenshot, or a picture from the clipboard or a file.
/// `scale` is pixels per point, so a Retina screenshot (2) shows at the size it had on screen.
final class Screenshot: @unchecked Sendable {
    let image: CGImage
    let scale: CGFloat
    let date: Date
    private let lock = NSLock()
    private var png: Data?

    init(image: CGImage, scale: CGFloat, date: Date = Date(), pngData: Data? = nil) {
        self.image = image
        self.scale = scale
        self.date = date
        png = pngData
    }

    /// Reads image data in any format ImageIO knows. The scale comes from its resolution: 144 dpi is 2, like a Retina screenshot.
    convenience init?(data: Data, date: Date = Date()) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let (image, scale) = Self.decode(source) else { return nil }
        let isPNG = CGImageSourceGetType(source) as String? == UTType.png.identifier
        self.init(image: image, scale: scale, date: date, pngData: isPNG ? data : nil)
    }

    convenience init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    private static var imageFileOptions: [NSPasteboard.ReadingOptionKey: Any] {
        [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier]]
    }

    /// Whether a pasteboard has an image, or an image file, to pin.
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: imageFileOptions) || NSImage.canInit(with: pasteboard)
    }

    /// The image from a pasteboard: a copied image file, image data, or anything else NSImage can read (like PDF).
    static func fromPasteboard(_ pasteboard: NSPasteboard) -> Screenshot? {
        // Check files first: for a file copied in Finder, the image data on the pasteboard is just its icon.
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: imageFileOptions) as? [URL])?.first {
            return Screenshot(contentsOf: url)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let screenshot = Screenshot(data: data) {
                return screenshot
            }
        }
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation {
            return Screenshot(data: tiff)
        }
        return nil
    }

    /// Size in points.
    var size: NSSize {
        NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    var nsImage: NSImage { NSImage(cgImage: image, size: size) }

    /// PNG with the scale saved as its resolution, so other apps show it at the right size too. Made once, then kept.
    var pngData: Data {
        lock.withLock {
            if let png { return png }
            let data = Self.encodePNG(image, scale: scale)
            png = data
            return data
        }
    }

    var suggestedFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Pinna \(formatter.string(from: date)).png"
    }

    /// Puts the PNG on the clipboard. TIFF, for apps that don't read PNG, is only made if one asks:
    /// for a full-screen capture it's tens of megabytes.
    @MainActor
    func copyToPasteboard() {
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        let provider = TIFFProvider(screenshot: self)
        item.setDataProvider(provider, forTypes: [.tiff])
        let pasteboard = NSPasteboard.general
        provider.changeCount = pasteboard.clearContents()
        pasteboard.writeObjects([item])
        TIFFProvider.current = provider
    }

    /// Resolves the promised TIFF while Pinna can still make it.
    @MainActor
    static func settlePasteboard() {
        guard let provider = TIFFProvider.current, NSPasteboard.general.changeCount == provider.changeCount else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(provider.screenshot.pngData, forType: .png)
    }

    // MARK: Encoding

    static func encodePNG(_ image: CGImage, scale: CGFloat) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        let dpi = 72 * scale
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// The image, turned upright, and its scale.
    private static func decode(_ source: CGImageSource) -> (CGImage, CGFloat)? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let image: CGImage?
        if orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            ] as CFDictionary)
        }
        guard let image else { return nil }
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        return (image, scale(forDPI: dpi))
    }

    /// Only screen resolutions count; a 300 dpi photo still shows one pixel per point.
    static func scale(forDPI dpi: Double) -> CGFloat {
        [2, 3].first { abs(dpi - 72 * $0) < 1 } ?? 1
    }
}

/// Makes the clipboard's TIFF when an app asks for it.
private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    /// The pasteboard doesn't promise to keep its provider, so the latest one is kept here.
    @MainActor static var current: TIFFProvider?
    let screenshot: Screenshot
    /// The pasteboard's change count once the screenshot was put on it; it changes when something else is copied.
    var changeCount = 0

    init(screenshot: Screenshot) {
        self.screenshot = screenshot
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let tiff = screenshot.nsImage.tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
    }
}
