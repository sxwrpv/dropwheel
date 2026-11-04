import Foundation

/// Command-line tools some conversions rely on.
public enum ExternalTool: String, CaseIterable, Sendable {
    case ffmpeg
    case ffprobe
    case cwebp
    case webpmux
    case pandoc
    case soffice

    /// How the user can install the tool.
    public var installHint: String {
        switch self {
        case .ffmpeg, .ffprobe: "Install it with: brew install ffmpeg"
        case .cwebp, .webpmux: "Install it with: brew install webp"
        case .pandoc: "Install it with: brew install pandoc"
        case .soffice: "Install LibreOffice with: brew install --cask libreoffice"
        }
    }

    /// Display name for messages.
    public var displayName: String {
        self == .soffice ? "LibreOffice" : rawValue
    }

    /// Places outside PATH where the tool lives, such as inside an app bundle.
    fileprivate var bundledLocations: [String] {
        switch self {
        case .soffice:
            ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
             NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
        default:
            []
        }
    }
}

/// Finds external tools. Apps opened from Finder don't inherit the shell's
/// PATH, so the usual Homebrew locations are checked explicitly.
public enum ToolLocator {
    private static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// `DROPWHEEL_FFMPEG=/path/to/ffmpeg` and friends override the search.
    public static func url(for tool: ExternalTool) -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["DROPWHEEL_\(tool.rawValue.uppercased())"],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") }
        let candidates = tool.bundledLocations
            + (searchDirectories + pathDirectories).map { "\($0)/\(tool.rawValue)" }
        return candidates.first(where: fileManager.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    static func require(_ tool: ExternalTool) throws(ConversionError) -> URL {
        guard let url = url(for: tool) else { throw .missingTool(tool) }
        return url
    }
}
