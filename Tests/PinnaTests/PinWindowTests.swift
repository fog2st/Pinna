import AppKit
import Testing
@testable import Pinna

@Suite(.serialized)
@MainActor
struct PinWindowTests {
    private func window(size: NSSize? = nil, display: NSSize = NSSize(width: 400, height: 200)) -> PinWindow {
        _ = NSApplication.shared
        let screenshot = Screenshot(image: makeImage(width: 400, height: 200), scale: 1)
        return PinWindow(state: PinState(screenshot: screenshot, origin: NSPoint(x: 100, y: 100),
                                        display: display, windowSize: size, keepsProportions: false))
    }

    @Test func freeResizeAcceptsTheProposedWindowShape() {
        let pin = window()
        defer { pin.close() }
        // Test the free mode even if Shift is currently held on the user's keyboard.
        if NSEvent.modifierFlags.contains(.shift) { pin.toggleKeepsProportions() }
        for proposed in [NSSize(width: 812, height: 234), NSSize(width: 412, height: 434), NSSize(width: 312, height: 434)] {
            #expect(pin.windowWillResize(pin, to: proposed) == proposed)
        }
    }

    @Test func freeWindowAndImageSurviveReopening() throws {
        let size = NSSize(width: 312, height: 434)
        let pin = window(size: size)
        defer { pin.close() }
        let state = pin.state
        let restored = PinWindow(state: PinRecord(state).state(with: state.screenshot))
        defer { restored.close() }
        let view = try #require(restored.contentView as? PinView)
        #expect(restored.frame.size == size)
        #expect(view.screenshotFrame.size == NSSize(width: 300, height: 150))
        #expect(restored.state.windowSize == size)
        #expect(restored.state.display == view.screenshotFrame.size)
    }

    @Test func legacyStretchedSizeBecomesAFittedImage() throws {
        let pin = window(display: NSSize(width: 300, height: 400))
        defer { pin.close() }
        let view = try #require(pin.contentView as? PinView)
        #expect(pin.frame.width == 312)
        #expect(view.screenshotFrame.size == NSSize(width: 300, height: 150))
        #expect(pin.state.display == view.screenshotFrame.size)
    }

    @Test func zoomPreservesTheFreeWindowsContentShape() throws {
        let pin = window(size: NSSize(width: 312, height: 434))
        defer { pin.close() }
        pin.zoom(by: 2)
        let view = try #require(pin.contentView as? PinView)
        #expect(pin.frame.width == 612)
        #expect(view.screenshotFrame.size == NSSize(width: 600, height: 300))
        pin.toggleKeepsProportions()
        #expect(pin.frame.height < 400)
        #expect(view.screenshotFrame.size == NSSize(width: 600, height: 300))
    }

    @Test func markupTracksTheFittedImageDuringResize() throws {
        let pin = window(size: NSSize(width: 312, height: 434))
        defer { pin.close() }
        let view = try #require(pin.contentView as? PinView)
        let markup = MarkupView(base: pin.screenshot)
        view.markupView = markup
        pin.setFrame(NSRect(x: 100, y: 100, width: 812, height: 234), display: false)
        #expect(markup.frame == view.screenshotFrame)
        #expect(abs(view.screenshotFrame.width / view.screenshotFrame.height - 2) < 0.000001)
        #expect(view.bounds.contains(view.screenshotFrame))
    }

    @Test func zoomOutFromAnOversizedFreeWindowReducesTheImage() throws {
        let pin = window(size: NSSize(width: 20012, height: 20038))
        defer { pin.close() }
        let before = pin.state.display
        pin.zoom(by: 0.8)
        let view = try #require(pin.contentView as? PinView)
        #expect(abs(view.screenshotFrame.width - before.width * 0.8) <= 1)
        #expect(view.screenshotFrame.width / view.screenshotFrame.height == 2)
    }
}
