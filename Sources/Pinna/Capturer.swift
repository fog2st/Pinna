import AppKit

struct Screenshot {
    let image: NSImage
    let pngData: Data
    let date = Date()

    func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        if let tiff = image.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff) // for apps that don't read PNG
        }
    }

    var suggestedFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Pinna \(formatter.string(from: date)).png"
    }
}

/// Takes screenshots with the system's interactive `screencapture` UI:
/// drag to select an area, press Space to pick a window, Esc to cancel.
@MainActor
final class Capturer {
    private var isCapturing = false
    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?

    /// Returns nil if the user cancelled. `frame` is where the selection was on screen, when it can be worked out.
    func capture() async -> (Screenshot, NSRect?)? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pinna-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        // screencapture doesn't say where the selection was, so watch the drag to pin it back in place.
        dragStart = nil
        dragEnd = nil
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, let location = event.cgEvent?.location else { return }
            // CoreGraphics measures from the top of the main screen; AppKit from the bottom.
            let point = NSPoint(x: location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - location.y)
            if event.type == .leftMouseDown { dragStart = point } else { dragEnd = point }
        }
        await runScreencapture(output: url)
        if let monitor { NSEvent.removeMonitor(monitor) }

        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        return (Screenshot(image: image, pngData: data), selectionFrame(matching: image.size))
    }

    private func runScreencapture(output url: URL) async {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-o", url.path] // interactive, no window shadow
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                NSLog("Pinna: couldn't run screencapture: \(error)")
                continuation.resume()
            }
        }
    }

    private func selectionFrame(matching size: NSSize) -> NSRect? {
        guard let start = dragStart else { return nil }
        let end = dragEnd ?? NSEvent.mouseLocation
        let dragged = NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                             width: abs(end.x - start.x), height: abs(end.y - start.y))
        // A mismatch means a window was picked or the selection was adjusted mid-drag.
        guard abs(dragged.width - size.width) <= 2, abs(dragged.height - size.height) <= 2 else { return nil }
        return NSRect(origin: dragged.origin, size: size)
    }
}
