import DropwheelCore
import Foundation

/// Audio and video conversions through ffmpeg, with live progress.
struct MediaConverter: Converter {
    func convert(_ input: URL, to target: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        let ffmpeg = try ToolLocator.require(.ffmpeg)
        let duration = await Self.duration(of: input)
        let tracker = ProgressTracker(parser: FFmpegProgress(durationSeconds: duration), report: progress)
        let arguments = FFmpegArguments.encode(input: input.path, output: output.path, target: target)

        progress(0)
        try await ProcessRunner.run(ffmpeg, arguments: arguments) { line in
            tracker.consume(line)
        }
        progress(1)
    }

    /// Length in seconds from ffprobe, or nil when it isn't available.
    /// Without it, progress jumps from 0 to 1.
    private static func duration(of input: URL) async -> Double? {
        guard let ffprobe = ToolLocator.url(for: .ffprobe) else { return nil }
        let collector = LineCollector()
        let arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", input.path]
        do {
            try await ProcessRunner.run(ffprobe, arguments: arguments) { collector.append($0) }
        } catch {
            return nil
        }
        return collector.lines.lazy.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.first
    }
}

/// Feeds ffmpeg's progress lines, which arrive on a background thread, to the parser.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: FFmpegProgress
    private let report: ProgressHandler

    init(parser: FFmpegProgress, report: @escaping ProgressHandler) {
        self.parser = parser
        self.report = report
    }

    func consume(_ line: String) {
        let fraction = lock.withLock { parser.consume(line) }
        if let fraction { report(fraction) }
    }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] { lock.withLock { storage } }

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }
}
