import DropwheelCore
import Foundation

public enum ConversionError: Error, Equatable, Sendable, LocalizedError {
    case unsupported(input: String, target: FileFormat)
    case missingTool(ExternalTool)
    case missingApp(String)
    case unreadableInput(String)
    case noText(String)
    case passwordProtected(String)
    case toolFailed(tool: String, message: String)
    case writeFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupported(let input, let target):
            "\(input) can’t be converted to \(target.label)."
        case .missingTool(let tool):
            "This conversion needs \(tool.displayName). \(tool.installHint)"
        case .missingApp(let name):
            "This conversion needs \(name), which you can get free from the App Store."
        case .unreadableInput(let name):
            "\(name) couldn’t be read. It may be damaged or in an unexpected format."
        case .passwordProtected(let name):
            "\(name) is password-protected. Open it, remove the password, then convert it."
        case .noText(let name):
            "\(name) has no text to extract. It may be a scan; try converting it to images instead."
        case .toolFailed(let tool, let message):
            "\(tool) reported an error: \(message)"
        case .writeFailed(let reason):
            "The converted file couldn’t be saved: \(reason)"
        case .cancelled:
            "The conversion was cancelled."
        }
    }
}
