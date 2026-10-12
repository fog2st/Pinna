import AppKit

/// What's saved about a pin, besides its image.
struct PinRecord: Codable, Equatable {
    var id: UUID
    var date: Date
    var origin: CGPoint
    var display: CGSize
    var isStretched: Bool
    var keepsProportions: Bool
    var opacity: Double
    var keepsOnTop: Bool
    var showsOnAllSpaces: Bool

    init(_ state: PinState) {
        id = state.id
        date = state.screenshot.date
        origin = state.origin
        display = state.display
        isStretched = state.isStretched
        keepsProportions = state.keepsProportions
        opacity = state.opacity
        keepsOnTop = state.keepsOnTop
        showsOnAllSpaces = state.showsOnAllSpaces
    }

    func state(with screenshot: Screenshot) -> PinState {
        PinState(id: id, screenshot: screenshot, origin: origin, display: display, isStretched: isStretched,
                 keepsProportions: keepsProportions, opacity: opacity, keepsOnTop: keepsOnTop, showsOnAllSpaces: showsOnAllSpaces)
    }
}

/// Keeps the open pins in Application Support, so they come back when Pinna starts again.
/// Each pin's image is a PNG named after its ID; pins.json lists the pins and their settings.
@MainActor
final class PinStore {
    let directory: URL
    private let queue = DispatchQueue(label: "Pinna.PinStore")
    /// Which screenshot each saved image holds, so only new or marked-up ones are written.
    private var savedImages: [UUID: ObjectIdentifier] = [:]

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Pinna/Pins", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private var listURL: URL { directory.appending(path: "pins.json") }

    private func imageURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).png")
    }

    func load() -> [PinState] {
        guard let data = try? Data(contentsOf: listURL),
              let records = try? JSONDecoder().decode([PinRecord].self, from: data) else { return [] }
        return records.compactMap { record in
            guard let imageData = try? Data(contentsOf: imageURL(for: record.id)),
                  let screenshot = Screenshot(data: imageData, date: record.date) else { return nil }
            savedImages[record.id] = ObjectIdentifier(screenshot)
            return record.state(with: screenshot)
        }
    }

    /// Saves the pins in the background, replacing what was saved before.
    func save(_ states: [PinState]) {
        let records = states.map(PinRecord.init)
        let changed = states.filter { savedImages[$0.id] != ObjectIdentifier($0.screenshot) }
        let images = changed.map { (imageURL(for: $0.id), $0.screenshot) }
        for state in changed {
            savedImages[state.id] = ObjectIdentifier(state.screenshot)
        }
        let kept = Set(states.map(\.id))
        savedImages = savedImages.filter { kept.contains($0.key) }

        let directory = directory, listURL = listURL
        queue.async {
            let files = FileManager.default
            try? files.createDirectory(at: directory, withIntermediateDirectories: true)
            for (url, screenshot) in images {
                try? screenshot.pngData.write(to: url, options: .atomic)
            }
            if let list = try? JSONEncoder().encode(records) {
                try? list.write(to: listURL, options: .atomic)
            }
            // Remove the images of pins that were closed.
            for file in (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "png" && !kept.contains(where: { $0.uuidString == file.deletingPathExtension().lastPathComponent }) {
                try? files.removeItem(at: file)
            }
        }
    }

    /// Waits until everything is written, before Pinna quits.
    func flush() {
        queue.sync {}
    }
}
