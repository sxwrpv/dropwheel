import Foundation
import DropwheelCore
import os

/// Terminal apps the Terminal action can open.
enum TerminalApp: String, CaseIterable {
    case terminal = "com.apple.Terminal"
    case iTerm = "com.googlecode.iterm2"

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm2"
        }
    }
}

/// Reads and writes user settings in UserDefaults.
@MainActor
final class Preferences {
    private enum Key {
        static let keyBindings = "keyBindings"
        static let terminalBundleID = "terminalBundleID"
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "dev.dropwheel", category: "Preferences")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Which key opens which wheel. Editing arrives with the Settings window.
    var keyBindings: KeyBindings {
        guard let data = defaults.data(forKey: Key.keyBindings) else { return .standard }
        do {
            let decoded = try JSONDecoder().decode(KeyBindings.self, from: data)
            return decoded.isValid ? decoded : .standard
        } catch {
            logger.error("Stored key bindings are unreadable, using defaults: \(error.localizedDescription)")
            return .standard
        }
    }

    var terminalApp: TerminalApp {
        get { defaults.string(forKey: Key.terminalBundleID).flatMap(TerminalApp.init(rawValue:)) ?? .terminal }
        set { defaults.set(newValue.rawValue, forKey: Key.terminalBundleID) }
    }
}
