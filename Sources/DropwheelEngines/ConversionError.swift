import DropwheelCore
import Foundation

public enum ConversionError: Error, Equatable, Sendable, LocalizedError {
    case unsupported(input: String, target: FileFormat)
    case missingTool(ExternalTool)
    case missingApp(String)
    case unreadableInput(String)
    case noText(String)
    case passwordProtected(String)
    case notSmaller(String)
    case targetTooSmall(String)
    case nothingToSplit(String)
    case multiFrame(String)
    case invalidTrim(String)
    case toolUnavailable(tool: String, input: String)
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
        case .invalidTrim(let name):
            "Choose a part of \(name) that is inside the recording and shorter than all of it."
        case .multiFrame(let name):
            "\(name) has several pages or frames. This tool works on single images only."
        case .nothingToSplit(let name):
            "\(name) is too short to split that way."
        case .toolUnavailable(let tool, let input):
            "\(tool) isn’t available for \(input)."
        case .notSmaller(let name):
            "\(name) is already as small as this setting can make it, so no copy was saved."
        case .targetTooSmall(let name):
            "That size is too small for \(name). Choose a larger size or a preset."
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
