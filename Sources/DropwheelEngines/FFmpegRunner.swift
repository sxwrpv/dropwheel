import DropwheelCore
import Foundation

/// Runs ffmpeg with live progress, and reads media details with ffprobe.
enum FFmpegRunner {
    /// Runs ffmpeg with `arguments` (which must include `-progress pipe:1`).
    /// `expectedSeconds` is the length of the output, used for progress.
    /// Returns the end of ffmpeg's stderr.
    @discardableResult
    static func run(_ arguments: [String], expectedSeconds: Double?, progress: @escaping ProgressHandler) async throws(ConversionError) -> String {
        let ffmpeg = try ToolLocator.require(.ffmpeg)
        let tracker = ProgressTracker(parser: FFmpegProgress(durationSeconds: expectedSeconds), report: progress)
        return try await ProcessRunner.run(ffmpeg, arguments: arguments) { line in
            tracker.consume(line)
        }
    }

    /// Details of a media file. Throws if ffprobe is missing or can't read it.
    static func probe(_ url: URL) async throws(ConversionError) -> MediaInfo {
        let ffprobe = try ToolLocator.require(.ffprobe)
        let collector = LineCollector()
        let arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]
        try await ProcessRunner.run(ffprobe, arguments: arguments) { collector.append($0) }
        guard let info = MediaInfo.parse(ffprobeJSON: Data(collector.lines.joined(separator: "\n").utf8)) else {
            throw .unreadableInput(url.lastPathComponent)
        }
        return info
    }

    /// Maps a 0...1 sub-task onto part of the overall progress.
    static func portion(_ progress: @escaping ProgressHandler, from start: Double, to end: Double) -> ProgressHandler {
        { fraction in progress(start + (end - start) * fraction) }
    }
}

/// Feeds ffmpeg's progress lines, which arrive on a background thread, to the parser.
final class ProgressTracker: @unchecked Sendable {
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

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] { lock.withLock { storage } }

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }
}
