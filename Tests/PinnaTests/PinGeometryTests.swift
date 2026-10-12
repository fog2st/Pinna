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

    @Test func freeResizeFitsWithoutStretching() {
        let display = geometry.display(resizingTo: NSSize(width: 312, height: 434), from: NSSize(width: 400, height: 200),
                                       axis: .corner, keepingProportions: false)
        #expect(display == NSSize(width: 300, height: 150))
    }

    @Test func freeWindowDimensionsStayIndependent() {
        let current = NSSize(width: 412, height: 234)
        for proposed in [NSSize(width: 812, height: current.height), NSSize(width: current.width, height: 434),
                         NSSize(width: 312, height: 434)] {
            #expect(geometry.constrainedWindowSize(proposed) == proposed)
            let shown = geometry.display(fillingWindow: proposed)
            let room = geometry.contentSize(window: proposed)
            #expect(shown.width / shown.height == 2)
            #expect(shown.width <= room.width && shown.height <= room.height)
        }
    }

    @Test func freeResizeHasEnoughRoomAtTheMinimumZoom() {
        let size = geometry.constrainedWindowSize(NSSize(width: 10, height: 10))
        #expect(size == NSSize(width: 160, height: 54))
        #expect(geometry.display(fillingWindow: size) == NSSize(width: 40, height: 20))
    }

    @Test func fittedImageIsCenteredBelowTheTitleBar() {
        let bounds = NSRect(x: 10, y: 20, width: 312, height: 434)
        let shown = geometry.imageFrame(in: bounds)
        #expect(shown == NSRect(x: 16, y: 151, width: 300, height: 150))
    }

    @Test func fractionalSizesKeepTheExactAspectRatio() {
        let portrait = PinGeometry(imageSize: NSSize(width: 317, height: 613), insets: geometry.insets, minWidth: 160)
        let shown = portrait.imageFrame(in: NSRect(x: 0, y: 0, width: 401.5, height: 240.5))
        #expect(abs(shown.width / shown.height - 317.0 / 613.0) < 0.000001)
        #expect(shown.minY == 6)
    }

    @Test func oversizedWindowCapsImageZoomWithoutDistortion() {
        #expect(geometry.display(fillingWindow: NSSize(width: 10012, height: 10034)) == NSSize(width: 3200, height: 1600))
    }

    @Test func imageStillFitsATinyContentView() {
        #expect(geometry.imageFrame(in: NSRect(x: 0, y: 0, width: 100, height: 10)).size == .zero)
    }

    @Test func zoomRestoresTheImagesProportions() {
        let zoomed = geometry.zoomed(NSSize(width: 400, height: 400), by: 0.5)
        #expect(zoomed == NSSize(width: 200, height: 100))
    }

    @Test func zoomStopsAtTheLimitWithoutChangingShape() {
        let zoomed = geometry.zoomed(NSSize(width: 400, height: 200), by: 10)
        #expect(zoomed == NSSize(width: 3200, height: 1600))
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
