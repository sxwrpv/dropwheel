import Foundation

/// Command-line tools some conversions rely on.
public enum ExternalTool: String, CaseIterable, Sendable {
    case ffmpeg
    case ffprobe
    case cwebp

    /// How the user can install the tool.
    public var installHint: String {
        switch self {
        case .ffmpeg, .ffprobe: "Install it with: brew install ffmpeg"
        case .cwebp: "Install it with: brew install webp"
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
        for directory in searchDirectories + pathDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(tool.rawValue)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func require(_ tool: ExternalTool) throws(ConversionError) -> URL {
        guard let url = url(for: tool) else { throw .missingTool(tool) }
        return url
    }
}
