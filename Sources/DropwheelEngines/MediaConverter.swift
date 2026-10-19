import DropwheelCore
import Foundation

/// Audio and video conversions through ffmpeg, with live progress.
struct MediaConverter: Converter {
    func convert(_ input: URL, to target: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        _ = try ToolLocator.require(.ffmpeg)
        // Without a duration, progress simply jumps from 0 to 1.
        let duration = (try? await FFmpegRunner.probe(input))?.durationSeconds
        progress(0)
        try await FFmpegRunner.run(FFmpegArguments.encode(input: input.path, output: output.path, target: target),
                                   expectedSeconds: duration, progress: progress)
        progress(1)
    }
}
