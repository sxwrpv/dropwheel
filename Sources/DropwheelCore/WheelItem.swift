/// The six actions on the File actions wheel. They work on any file or folder.
public enum FileActionKind: String, CaseIterable, Sendable {
    case airDrop
    case float
    case copy
    case move
    case copyPath
    case terminal

    public var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .float: "Float"
        case .copy: "Copy"
        case .move: "Move"
        case .copyPath: "Copy Path"
        case .terminal: "Terminal"
        }
    }

    /// SF Symbol shown on the slice.
    public var symbolName: String {
        switch self {
        case .airDrop: "dot.radiowaves.left.and.right"
        case .float: "tray.and.arrow.down"
        case .copy: "doc.on.doc"
        case .move: "folder"
        case .copyPath: "link"
        case .terminal: "terminal"
        }
    }
}

/// What dropping onto a slice does. Conversions and tools join in later phases.
public enum WheelAction: Equatable, Sendable {
    case fileAction(FileActionKind)
}

public struct WheelItem: Equatable, Identifiable, Sendable {
    public let id: String
    /// Short uppercase label drawn on the slice.
    public let label: String
    /// Longer title shown in the hub while the slice is hovered.
    public let title: String
    public let symbolName: String
    public let action: WheelAction

    public init(id: String, label: String, title: String, symbolName: String, action: WheelAction) {
        self.id = id
        self.label = label
        self.title = title
        self.symbolName = symbolName
        self.action = action
    }

    public static func fileAction(_ kind: FileActionKind) -> WheelItem {
        WheelItem(
            id: "action.\(kind.rawValue)",
            label: kind.title.uppercased(),
            title: kind.title,
            symbolName: kind.symbolName,
            action: .fileAction(kind)
        )
    }
}

/// Supplies the slices for each wheel.
public enum WheelCatalog {
    public static func items(for wheel: WheelKind) -> [WheelItem] {
        switch wheel {
        case .actions:
            FileActionKind.allCases.map(WheelItem.fileAction)
        case .conversions, .tools:
            // Filled in by the conversion and tool phases.
            []
        }
    }
}
