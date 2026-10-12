import Foundation

/// The settings other than shortcuts, saved in UserDefaults.
enum Preferences {
    private enum Key {
        static let keepsProportions = "KeepsProportions"
        static let showsOnAllSpaces = "ShowsOnAllSpaces"
        static let keepsOnTop = "KeepsOnTop"
        static let restoresPins = "RestoresPins"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.keepsProportions: true,
            Key.showsOnAllSpaces: false,
            Key.keepsOnTop: true,
            Key.restoresPins: true,
        ])
    }

    /// Whether a new pin's window keeps the screenshot's proportions, or resizes freely around a fitted image.
    static var keepsProportions: Bool {
        get { UserDefaults.standard.bool(forKey: Key.keepsProportions) }
        set { UserDefaults.standard.set(newValue, forKey: Key.keepsProportions) }
    }

    /// Whether new pins appear on every Space, full-screen apps included, rather than just the one they were taken on.
    static var showsOnAllSpaces: Bool {
        get { UserDefaults.standard.bool(forKey: Key.showsOnAllSpaces) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showsOnAllSpaces) }
    }

    /// Whether new pins float above other windows.
    static var keepsOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: Key.keepsOnTop) }
        set { UserDefaults.standard.set(newValue, forKey: Key.keepsOnTop) }
    }

    /// Whether the pins open when Pinna quit come back when it starts again.
    static var restoresPins: Bool {
        get { UserDefaults.standard.bool(forKey: Key.restoresPins) }
        set { UserDefaults.standard.set(newValue, forKey: Key.restoresPins) }
    }
}
