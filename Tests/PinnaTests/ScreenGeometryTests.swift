import AppKit
import Testing
@testable import Pinna

struct ScreenGeometryTests {
    @Test func coreGraphicsRectsFlipToAppKit() {
        // A 100 × 50 window 10pt from the top of a 900pt-high main screen.
        let rect = ScreenGeometry.appKitRect(fromCG: CGRect(x: 20, y: 10, width: 100, height: 50), mainScreenHeight: 900)
        #expect(rect == NSRect(x: 20, y: 840, width: 100, height: 50))
    }

    @Test func appKitPointsFlipToCoreGraphics() {
        #expect(ScreenGeometry.cgPoint(fromAppKit: NSPoint(x: 5, y: 900), mainScreenHeight: 900) == CGPoint(x: 5, y: 0))
    }

    @Test func pixelRectCountsRowsFromTheTop() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let pixels = ScreenGeometry.pixelRect(of: NSRect(x: 10, y: 700, width: 100, height: 50), inScreen: screen, scale: 2)
        #expect(pixels == CGRect(x: 20, y: 100, width: 200, height: 100))
    }

    @Test func pixelRectWorksOnSecondaryScreens() {
        // A screen to the left of the main one, lower down.
        let screen = NSRect(x: -1200, y: -300, width: 1200, height: 900)
        let pixels = ScreenGeometry.pixelRect(of: NSRect(x: -1100, y: 500, width: 10, height: 10), inScreen: screen, scale: 1)
        #expect(pixels == CGRect(x: 100, y: 90, width: 10, height: 10))
    }

    @Test func pixelUnderAPointStaysInTheImage() {
        let screen = NSRect(x: 0, y: 0, width: 100, height: 100)
        #expect(ScreenGeometry.pixel(at: NSPoint(x: 10.6, y: 89.4), inScreen: screen, scale: 2, imageSize: (200, 200)) == (21, 21))
        #expect(ScreenGeometry.pixel(at: NSPoint(x: 100, y: 0), inScreen: screen, scale: 2, imageSize: (200, 200)) == (199, 199))
    }

    @Test func integralMovesCornersToWholePoints() {
        #expect(ScreenGeometry.integral(NSRect(x: 0.4, y: 0.6, width: 10.2, height: 10.2)) == NSRect(x: 0, y: 1, width: 11, height: 10))
    }
}
