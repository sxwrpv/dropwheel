import DropwheelCore
import Foundation

public enum ConversionError: Error, Equatable, Sendable, LocalizedError {
    case unsupported(input: String, target: FileFormat)
    case missingTool(ExternalTool)
    case unreadableInput(String)
    case toolFailed(tool: String, message: String)
    case writeFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupported(let input, let target):
            "\(input) can’t be converted to \(target.label)."
        case .missingTool(let tool):
            "This conversion needs \(tool.rawValue). \(tool.installHint)"
        case .unreadableInput(let name):
            "\(name) couldn’t be read. It may be damaged or in an unexpected format."
        case .toolFailed(let tool, let message):
            "\(tool) reported an error: \(message)"
        case .writeFailed(let reason):
            "The converted file couldn’t be saved: \(reason)"
        case .cancelled:
            "The conversion was cancelled."
        }
    }
}
