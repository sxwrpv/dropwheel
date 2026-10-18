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

/// What dropping onto a slice does. File tools join in a later phase.
public enum WheelAction: Equatable, Sendable {
    case fileAction(FileActionKind)
    case convert(FileFormat)
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

    public static func conversion(to format: FileFormat) -> WheelItem {
        WheelItem(
            id: "convert.\(format.rawValue)",
            label: format.label,
            title: "Convert to \(format.label)",
            symbolName: format.symbolName,
            action: .convert(format)
        )
    }
}

/// Supplies the slices for each wheel.
public enum WheelCatalog {
    /// `selection` describes the dragged items; only the conversions wheel uses it.
    public static func items(
        for wheel: WheelKind,
        selection: [SelectionItem] = [],
        capabilities: FormatCapabilities = .unrestricted
    ) -> [WheelItem] {
        switch wheel {
        case .actions:
            FileActionKind.allCases.map(WheelItem.fileAction)
        case .conversions:
            ConversionMatrix.targets(for: selection, capabilities: capabilities).map(WheelItem.conversion)
        case .tools:
            // Filled in by the file tools phase.
            []
        }
    }
}
