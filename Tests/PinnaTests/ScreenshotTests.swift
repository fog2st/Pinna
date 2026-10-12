import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Pinna

/// A solid-color image, `width` × `height` pixels.
func makeImage(width: Int, height: Int, color: CGColor = CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

struct ScreenshotTests {
    @Test func sizeIsInPoints() {
        let screenshot = Screenshot(image: makeImage(width: 200, height: 100), scale: 2)
        #expect(screenshot.size == NSSize(width: 100, height: 50))
    }

    @Test func pngKeepsTheScale() throws {
        let original = Screenshot(image: makeImage(width: 200, height: 100), scale: 2)
        let reopened = try #require(Screenshot(data: original.pngData))
        #expect(reopened.scale == 2)
        #expect(reopened.size == NSSize(width: 100, height: 50))
    }

    @Test func pngIsMadeOnce() {
        let screenshot = Screenshot(image: makeImage(width: 20, height: 20), scale: 1)
        #expect(screenshot.pngData == screenshot.pngData)
    }

    @Test func onlyScreenResolutionsCountAsScales() {
        #expect(Screenshot.scale(forDPI: 72) == 1)
        #expect(Screenshot.scale(forDPI: 144) == 2)
        #expect(Screenshot.scale(forDPI: 216) == 3)
        #expect(Screenshot.scale(forDPI: 300) == 1)
    }

    @Test func readsOtherFormats() throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, makeImage(width: 30, height: 10), nil)
        CGImageDestinationFinalize(destination)
        let screenshot = try #require(Screenshot(data: data as Data))
        #expect(screenshot.size == NSSize(width: 30, height: 10))
    }

    @Test func turnsRotatedPhotosUpright() throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        // Orientation 6: stored sideways, shown rotated 90°.
        CGImageDestinationAddImage(destination, makeImage(width: 30, height: 10), [kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(destination)
        let screenshot = try #require(Screenshot(data: data as Data))
        #expect(screenshot.size == NSSize(width: 10, height: 30))
    }

    @Test func rejectsData() {
        #expect(Screenshot(data: Data("not an image".utf8)) == nil)
    }

    @Test func filenameHasTheDate() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 5, minute: 6, second: 7))!
        let screenshot = Screenshot(image: makeImage(width: 1, height: 1), scale: 1, date: date)
        #expect(screenshot.suggestedFilename == "Pinna 2026-03-04 at 05.06.07.png")
    }
}
