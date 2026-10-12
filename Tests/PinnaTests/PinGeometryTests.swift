import AppKit
import Testing
@testable import Pinna

struct PinGeometryTests {
    // A 400 × 200 screenshot, a 28pt title bar and 6pt border, and room for 160pt of title bar buttons.
    let geometry = PinGeometry(imageSize: NSSize(width: 400, height: 200),
                               insets: NSEdgeInsets(top: 28, left: 6, bottom: 6, right: 6), minWidth: 160)

    @Test func windowAddsTheBorderAndTitleBar() {
        #expect(geometry.windowSize(display: NSSize(width: 400, height: 200)) == NSSize(width: 412, height: 234))
    }

    @Test func narrowScreenshotsGetTheMinimumWidth() {
        #expect(geometry.windowSize(display: NSSize(width: 40, height: 20)) == NSSize(width: 160, height: 54))
    }

    @Test func proportionalResizeFollowsTheDraggedEdge() {
        let current = NSSize(width: 400, height: 200)
        let wider = geometry.display(resizingTo: NSSize(width: 812, height: 234), from: current, axis: .width, keepingProportions: true)
        #expect(wider == NSSize(width: 800, height: 400))
        let taller = geometry.display(resizingTo: NSSize(width: 412, height: 134), from: current, axis: .height, keepingProportions: true)
        #expect(taller == NSSize(width: 200, height: 100))
    }

    @Test func proportionalCornerResizeFollowsTheLargerChange() {
        let display = geometry.display(resizingTo: NSSize(width: 612, height: 250), from: NSSize(width: 400, height: 200),
                                       axis: .corner, keepingProportions: true)
        #expect(display == NSSize(width: 600, height: 300))
    }

    @Test func freeResizeStretchesToTheWindow() {
        let display = geometry.display(resizingTo: NSSize(width: 312, height: 434), from: NSSize(width: 400, height: 200),
                                       axis: .corner, keepingProportions: false)
        #expect(display == NSSize(width: 300, height: 400))
    }

    @Test func freeResizeStaysWithinTheZoomLimits() {
        let display = geometry.display(resizingTo: NSSize(width: 160, height: 34), from: NSSize(width: 400, height: 200),
                                       axis: .corner, keepingProportions: false)
        #expect(display.height == 20) // 0.1 × 200
    }

    @Test func zoomKeepsAStretchedShape() {
        let zoomed = geometry.zoomed(NSSize(width: 400, height: 400), by: 0.5)
        #expect(zoomed == NSSize(width: 200, height: 200))
    }

    @Test func zoomStopsAtTheLimitWithoutChangingShape() {
        // Height is at 2×, width at 1×: zooming in 10× is held to 4×, where the height reaches 8×.
        let zoomed = geometry.zoomed(NSSize(width: 400, height: 400), by: 10)
        #expect(zoomed == NSSize(width: 1600, height: 1600))
    }

    @Test func fittingKeepsTheShape() {
        let display = geometry.display(fitting: NSSize(width: 400, height: 200), in: NSSize(width: 1012, height: 334))
        #expect(display == NSSize(width: 600, height: 300))
    }

    @Test func axisComesFromTheFirstStep() {
        let current = NSSize(width: 100, height: 100)
        #expect(PinGeometry.axis(from: current, to: NSSize(width: 120, height: 100)) == .width)
        #expect(PinGeometry.axis(from: current, to: NSSize(width: 100, height: 90)) == .height)
        #expect(PinGeometry.axis(from: current, to: NSSize(width: 120, height: 90)) == .corner)
    }

    @Test func resizingAroundAPointKeepsItInPlace() {
        let frame = NSRect(x: 100, y: 100, width: 200, height: 100)
        let anchor = NSPoint(x: 150, y: 125) // a quarter of the way in
        let resized = PinGeometry.frame(resizing: frame, to: NSSize(width: 400, height: 200), around: anchor)
        #expect(resized == NSRect(x: 50, y: 75, width: 400, height: 200))
    }
}
