import DropwheelCore
import Foundation

/// SRT ↔ WebVTT, and either to plain text.
struct SubtitleConverter: Converter {
    func convert(_ input: URL, to target: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        progress(0)
        let source = try TextFile.read(input)
        let converted: String
        do {
            converted = try Subtitles.convert(source, to: target)
        } catch {
            switch error {
            case .noCues: throw .unreadableInput(input.lastPathComponent)
            case .unsupportedTarget(let format): throw .unsupported(input: input.lastPathComponent, target: format)
            }
        }
        try TextFile.write(converted, to: output)
        progress(1)
    }
}
