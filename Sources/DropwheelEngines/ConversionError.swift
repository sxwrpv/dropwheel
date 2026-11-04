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
    /// A redaction whose boxes cover nothing.
    case nothingToHide(String)
    case invalidFrames(String)
    /// The file doesn't record how long it is.
    case unknownLength(String)
    /// A bleep with no marked parts.
    case nothingToBleep(String)
    /// A still-image visualizer with no picture chosen.
    case needsPicture(String)
    /// Audio too brief to make a video from.
    case tooShort(String)
    /// Organize Pages with every page removed.
    case noPagesLeft(String)
    /// A field the file's format wouldn't take.
    case metadataNotSaved(field: String, input: String)
    /// A field the file's format wouldn't give up.
    case metadataNotRemoved(field: String, input: String)
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
        case .nothingToHide(let name):
            "Draw at least one box over the part of \(name) to hide."
        case .invalidFrames(let name):
            "Choose a frame inside \(name), or an interval that gives 2 to \(FrameExport.maximumFrames) frames."
        case .unknownLength(let name):
            "\(name) doesn’t record how long it is, so its frames can’t be picked."
        case .nothingToBleep(let name):
            "Mark at least one part of \(name) to bleep."
        case .needsPicture(let name):
            "Choose a picture to show with \(name)."
        case .tooShort(let name):
            "\(name) is too short to make a video from."
        case .noPagesLeft(let name):
            "Keep at least one page of \(name)."
        case .metadataNotSaved(let field, let input):
            "\(field) can’t be saved in a file like \(input), so no copy was made."
        case .metadataNotRemoved(let field, let input):
            "\(field) couldn’t be removed from \(input), so no copy was made."
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
