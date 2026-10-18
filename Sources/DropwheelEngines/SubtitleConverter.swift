import DropwheelCore
import Foundation

/// SRT ↔ WebVTT, and either to plain text.
struct SubtitleConverter: Converter {
    func convert(_ input: URL, to target: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        progress(0)
        let source = try Self.readText(input)
        let converted: String
        do {
            converted = try Subtitles.convert(source, to: target)
        } catch {
            switch error {
            case .noCues: throw .unreadableInput(input.lastPathComponent)
            case .unsupportedTarget(let format): throw .unsupported(input: input.lastPathComponent, target: format)
            }
        }
        do {
            try converted.write(to: output, atomically: true, encoding: .utf8)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        progress(1)
    }

    /// Subtitle files are often not UTF-8. UTF-16 is only tried when a
    /// byte-order mark says so, because UTF-16 decoding accepts almost any
    /// bytes and would turn Windows-1252 text into nonsense.
    private static func readText(_ url: URL) throws(ConversionError) -> String {
        guard let data = try? Data(contentsOf: url) else { throw .unreadableInput(url.lastPathComponent) }
        let hasUTF16Mark = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let encodings: [String.Encoding] = hasUTF16Mark ? [.utf16] : [.utf8, .windowsCP1252, .isoLatin1]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw .unreadableInput(url.lastPathComponent)
    }
}
