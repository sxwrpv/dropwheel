/// A modifier key the user can tap mid-drag to open a wheel.
public enum ModifierKey: String, CaseIterable, Codable, Sendable {
    case shift
    case control
    case option
    case command

    public var symbol: String {
        switch self {
        case .shift: "⇧"
        case .control: "⌃"
        case .option: "⌥"
        case .command: "⌘"
        }
    }
}

/// The three wheels. Each one is opened by its own modifier key.
public enum WheelKind: String, CaseIterable, Codable, Sendable {
    case conversions
    case tools
    case actions

    public var title: String {
        switch self {
        case .conversions: "Convert formats"
        case .tools: "File tools"
        case .actions: "File actions"
        }
    }
}

/// Which modifier opens which wheel. Every wheel has a distinct key.
public struct KeyBindings: Equatable, Codable, Sendable {
    public static let standard = KeyBindings(
        conversions: .shift,
        tools: .command,
        actions: .control
    )

    public let conversions: ModifierKey
    public let tools: ModifierKey
    public let actions: ModifierKey

    public init(conversions: ModifierKey, tools: ModifierKey, actions: ModifierKey) {
        self.conversions = conversions
        self.tools = tools
        self.actions = actions
    }

    public var isValid: Bool {
        Set([conversions, tools, actions]).count == 3
    }

    public func key(for wheel: WheelKind) -> ModifierKey {
        switch wheel {
        case .conversions: conversions
        case .tools: tools
        case .actions: actions
        }
    }

    public func wheel(for key: ModifierKey) -> WheelKind? {
        WheelKind.allCases.first { self.key(for: $0) == key }
    }

    /// Returns a copy with `wheel` bound to `key`. If another wheel already
    /// used `key`, the two wheels swap keys so bindings stay unique.
    public func rebinding(_ wheel: WheelKind, to key: ModifierKey) -> KeyBindings {
        let previousKey = self.key(for: wheel)
        let displaced = self.wheel(for: key)
        func resolved(_ candidate: WheelKind) -> ModifierKey {
            if candidate == wheel { return key }
            if candidate == displaced { return previousKey }
            return self.key(for: candidate)
        }
        return KeyBindings(
            conversions: resolved(.conversions),
            tools: resolved(.tools),
            actions: resolved(.actions)
        )
    }
}
