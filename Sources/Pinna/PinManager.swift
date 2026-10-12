import AppKit

/// Keeps track of the pins: opens, closes, hides and brings them back, and saves them for next time.
@MainActor
final class PinManager {
    /// Open pins, oldest first.
    private(set) var pins: [PinWindow] = []
    /// Closed pins, most recent last, for Reopen Closed Pin.
    private var closed: [PinState] = []
    private let store = PinStore()
    private var saveTask: Task<Void, Never>?
    /// While a pin is being replaced by a copy on another Space, closing it doesn't count.
    private var isReplacing = false

    var canReopen: Bool { !closed.isEmpty }
    /// Whether any pin is showing, rather than closed or hidden with Hide All Pins.
    var hasShownPins: Bool { pins.contains { !$0.isHiddenByUser } }

    // MARK: Opening

    /// Opens the pins saved when Pinna last quit.
    func restoreSavedPins() {
        guard Preferences.restoresPins else { return }
        for state in store.load() {
            let pin = add(state)
            // Displays may have changed since; keep pins on screen.
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(pin.frame) }) {
                pin.center()
            }
            show(pin)
        }
    }

    /// Pins a screenshot. With `imageFrame`, it goes right there; otherwise it's centered on the mouse,
    /// shrunk if it's bigger than most of the screen. `cascade` steps each of several pins down and to the right.
    @discardableResult
    func pin(_ screenshot: Screenshot, at imageFrame: NSRect? = nil, cascade: Int = 0) -> PinWindow {
        let (display, frame) = imageFrame.map { (screenshot.size, $0) } ?? Self.placement(for: screenshot.size, cascade: cascade)
        let pin = add(PinState(screenshot: screenshot, origin: frame.origin, display: display), imageFrame: frame)
        show(pin)
        scheduleSave()
        return pin
    }

    func reopenClosedPin() {
        guard let state = closed.popLast() else { return }
        show(add(state))
        scheduleSave()
    }

    private func add(_ state: PinState, imageFrame: NSRect? = nil) -> PinWindow {
        let pin = PinWindow(state: state, imageFrame: imageFrame)
        pin.onClose = { [weak self] in self?.pinDidClose($0) }
        pin.onChange = { [weak self] _ in self?.scheduleSave() }
        pins.append(pin)
        return pin
    }

    private func show(_ pin: PinWindow) {
        pin.isHiddenByUser = false
        pin.orderFrontRegardless() // without stealing focus from the current app
    }

    private func pinDidClose(_ pin: PinWindow) {
        pins.removeAll { $0 === pin }
        if !isReplacing {
            closed.append(pin.state)
            if closed.count > 20 { closed.removeFirst() }
        }
        scheduleSave()
    }

    // MARK: All pins

    func closeAll() {
        pins.forEach { $0.close() }
    }

    /// Hides every pin, or shows them again if they're all hidden.
    func toggleVisibility() {
        if hasShownPins {
            // A markup toolbar, as a child window, hides and comes back with its pin.
            for pin in pins {
                pin.isHiddenByUser = true
                pin.orderOut(nil)
            }
        } else {
            pins.forEach(show)
        }
    }

    /// Brings a pin to the current Space, full-screen apps included, in front, with click-through off.
    func bringHere(_ pin: PinWindow) {
        pin.setClickThrough(false)
        if pin.isMiniaturized {
            pin.deminiaturize(nil)
        }
        if pin.isOnActiveSpace || pin.showsOnAllSpaces {
            show(pin)
            return
        }
        // macOS has no way to move a window to another Space, but a new window opens on the current one.
        let state = pin.state
        isReplacing = true
        pin.close()
        isReplacing = false
        show(add(state))
        scheduleSave()
    }

    func bringAllHere() {
        pins.forEach(bringHere)
    }

    // MARK: Saving

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        store.save(Preferences.restoresPins ? pins.map(\.state) : [])
    }

    /// Saves and waits for the files to be written, before quitting.
    func saveAndWait() {
        saveNow()
        store.flush()
    }

    // MARK: Placement

    /// The size and place for a pin that wasn't captured from the screen: centered on the mouse, within the screen.
    private static func placement(for size: NSSize, cascade: Int) -> (display: NSSize, imageFrame: NSRect) {
        let visible = NSScreen.underMouse?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let titlebar: CGFloat = 32
        let fit = min(1, visible.width * 0.8 / size.width, (visible.height - titlebar) * 0.8 / size.height)
        let display = NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        let mouse = NSEvent.mouseLocation
        let step = CGFloat(cascade) * 24
        var frame = NSRect(x: mouse.x - display.width / 2 + step, y: mouse.y - display.height / 2 - step,
                           width: display.width, height: display.height)
        frame.origin.x = max(visible.minX + 6, min(frame.minX, visible.maxX - display.width - 6))
        frame.origin.y = max(visible.minY + 6, min(frame.minY, visible.maxY - display.height - titlebar))
        return (display, frame)
    }
}
