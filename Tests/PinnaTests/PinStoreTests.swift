import AppKit
import Testing
@testable import Pinna

@MainActor
struct PinStoreTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PinnaTests-\(UUID().uuidString)")

    private func state(width: Int = 40) -> PinState {
        PinState(screenshot: Screenshot(image: makeImage(width: width, height: 20), scale: 2),
                 origin: NSPoint(x: 10, y: 20), display: NSSize(width: 30, height: 40), isStretched: true,
                 keepsProportions: false, opacity: 0.6, keepsOnTop: false, showsOnAllSpaces: true)
    }

    @Test func pinsComeBack() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = state()
        let store = PinStore(directory: directory)
        store.save([saved])
        store.flush()

        let loaded = PinStore(directory: directory).load()
        let pin = try #require(loaded.first)
        #expect(loaded.count == 1)
        #expect(PinRecord(pin) == PinRecord(saved))
        #expect(pin.screenshot.size == saved.screenshot.size)
        #expect(pin.screenshot.scale == 2)
    }

    @Test func closedPinsAreRemoved() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PinStore(directory: directory)
        let first = state(), second = state(width: 60)
        store.save([first, second])
        store.save([second])
        store.flush()

        let images = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }
        #expect(images == ["\(second.id.uuidString).png"])
        #expect(PinStore(directory: directory).load().map(\.id) == [second.id])
    }

    @Test func nothingSavedLoadsNothing() {
        #expect(PinStore(directory: directory).load().isEmpty)
    }
}
