import CoreGraphics
import DropwheelCore
import Foundation
import ImageIO

/// Crop and Trim, as chosen in their editors.
enum EditTools {
    /// Resizing a crop beyond this many pixels on a side is refused as a typo.
    private static let maximumOutputEdge = 20_000
    /// 100 megapixels: an RGBA bitmap this size already needs 400 MB.
    private static let maximumOutputPixels = 100_000_000

    static func cropImage(_ input: URL, format: FileFormat, recipe: CropRecipe, outputWidth: Int?, outputHeight: Int?,
                          output: URL) async throws(ConversionError) {
        if let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 1 {
            throw .multiFrame(input.lastPathComponent)
        }
        let loaded = try ImageConverter.load(input)
        let rect = recipe.pixelRect(imageWidth: loaded.image.width, imageHeight: loaded.image.height)
        guard var cropped = loaded.image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) else {
            throw .writeFailed("Couldn’t crop the image.")
        }
        if let width = outputWidth, let height = outputHeight {
            guard (1...maximumOutputEdge).contains(width), (1...maximumOutputEdge).contains(height),
                  width * height <= maximumOutputPixels else {
                throw .writeFailed("The output size must be between 1 and \(maximumOutputEdge) pixels.")
            }
            cropped = try resized(cropped, width: width, height: height)
        }
        let result = ImageConverter.LoadedImage(image: cropped, properties: loaded.properties, dpi: loaded.dpi)
        if format == .webp {
            try await ImageConverter.writeWebP(result, to: output)
        } else {
            try ImageConverter.write(result, as: format, to: output)
        }
    }

    /// The crop is measured on frames as ffmpeg sees them: already rotated,
    /// before any widening for non-square pixels.
    static func cropVideo(_ input: URL, format: FileFormat, recipe: CropRecipe, output: URL,
                          progress: @escaping ProgressHandler) async throws(ConversionError) {
        let info = try await FFmpegRunner.probe(input)
        guard let size = info.rotatedSize else { throw .unreadableInput(input.lastPathComponent) }
        let rect = recipe.pixelRect(imageWidth: size.width, imageHeight: size.height, even: true)
        let arguments = FFmpegArguments.command(input: input.path, options: EditPlans.cropVideoOptions(rect, format: format),
                                                output: output.path)
        try await FFmpegRunner.run(arguments, expectedSeconds: info.durationSeconds, progress: progress)
    }

    static func trim(_ input: URL, format: FileFormat, range: TrimRange, output: URL,
                     progress: @escaping ProgressHandler) async throws(ConversionError) {
        let info = try await FFmpegRunner.probe(input)
        guard let duration = info.durationSeconds, range.isValid(durationSeconds: duration),
              !range.coversWhole(durationSeconds: duration) else {
            throw .invalidTrim(input.lastPathComponent)
        }
        let arguments = EditPlans.trimArguments(input: input.path, output: output.path, range: range, format: format)
        try await FFmpegRunner.run(arguments, expectedSeconds: range.length, progress: progress)
    }

    static func trimSilence(_ input: URL, format: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        let duration = (try? await FFmpegRunner.probe(input))?.durationSeconds
        let options = ["-af", EditPlans.trimSilenceFilter] + FFmpegArguments.codecArguments(for: format)
        try await FFmpegRunner.run(FFmpegArguments.command(input: input.path, options: options, output: output.path),
                                   expectedSeconds: duration, progress: progress)
        // An all-silent recording leaves nothing; don't save an empty copy.
        let kept = (try? await FFmpegRunner.probe(output))?.durationSeconds ?? 0
        guard kept >= TrimRange.minimumLength else { throw .invalidTrim(input.lastPathComponent) }
    }

    private static func resized(_ image: CGImage, width: Int, height: Int) throws(ConversionError) -> CGImage {
        guard let context = ImageConverter.makeContext(width: width, height: height, opaque: false) else {
            throw .writeFailed("Couldn’t resize the image.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw .writeFailed("Couldn’t resize the image.") }
        return result
    }
}

/// Details and previews of media files, for the editors.
public enum MediaPreview {
    /// Samples per second decoded for the waveform. Lower rates would filter
    /// out everything above half the rate (a 440 Hz tone vanishes at 500 Hz);
    /// 8 kHz keeps the audible range and is read memory-mapped, not copied.
    private static let waveformSampleRate = 8_000

    public static func info(of url: URL) async throws(ConversionError) -> MediaInfo {
        try await FFmpegRunner.probe(url)
    }

    /// One peak per bucket across the whole recording, from 0 to 1.
    public static func waveform(of url: URL, buckets: Int) async throws(ConversionError) -> [Float] {
        peaks(of: try await decodedSamples(of: url, track: []), buckets: buckets)
    }

    /// The first audio track's real length and its peaks, about
    /// `bucketsPerSecond` of them up to `maximumBuckets`.
    public static func timeline(of url: URL, bucketsPerSecond: Int,
                                maximumBuckets: Int) async throws(ConversionError) -> AudioTimeline {
        let samples = try await decodedSamples(of: url, track: ["-map", "0:a:0"])
        let seconds = try length(of: samples, in: url)
        let buckets = max(min(Int((seconds * Double(bucketsPerSecond)).rounded()), maximumBuckets), 1)
        return AudioTimeline(seconds: seconds, peaks: peaks(of: samples, buckets: buckets))
    }

    /// The first audio track's real length, from decoding it.
    static func decodedSeconds(of url: URL) async throws(ConversionError) -> Double {
        try length(of: try await decodedSamples(of: url, track: ["-map", "0:a:0"]), in: url)
    }

    private static func length(of samples: Data, in url: URL) throws(ConversionError) -> Double {
        let seconds = Double(samples.count / MemoryLayout<Float>.size) / Double(waveformSampleRate)
        guard seconds > 0 else { throw .unreadableInput(url.lastPathComponent) }
        return seconds
    }

    private static func peaks(of samples: Data, buckets: Int) -> [Float] {
        samples.withUnsafeBytes { bytes in
            Waveform.peaks(of: bytes.bindMemory(to: Float.self), buckets: buckets).map { min($0, 1) }
        }
    }

    /// The sound as mono samples. They stay memory-mapped, not copied; the
    /// mapping outlives the temporary file, which is removed straight away.
    private static func decodedSamples(of url: URL, track: [String]) async throws(ConversionError) -> Data {
        let ffmpeg = try ToolLocator.require(.ffmpeg)
        let samplesFile = temporaryFile(extension: "f32")
        defer { discardTemporaryFile(samplesFile) }
        try await ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-v", "error", "-i", url.path] + track
            + ["-vn", "-ac", "1", "-ar", "\(waveformSampleRate)", "-f", "f32le", "-y", samplesFile.path])
        guard let data = try? Data(contentsOf: samplesFile, options: .alwaysMapped) else {
            throw .unreadableInput(url.lastPathComponent)
        }
        return data
    }

    /// Length of the picture track alone, which can be shorter than the file
    /// when the sound runs on. Nil when the container doesn't record it.
    private static func pictureDuration(of url: URL) async throws(ConversionError) -> Double? {
        let ffprobe = try ToolLocator.require(.ffprobe)
        let collector = LineCollector()
        try await ProcessRunner.run(ffprobe, arguments: ["-v", "error", "-select_streams", "v:0",
                                                         "-show_entries", "stream=duration",
                                                         "-of", "default=nw=1:nk=1", url.path]) { collector.append($0) }
        return collector.lines.lazy.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.first
    }

    /// The video frame shown at `seconds`, as displayed (rotation applied),
    /// in the pixels it is stored with.
    public static func frame(of url: URL, at seconds: Double) async throws(ConversionError) -> CGImage {
        try await extractFrame(of: url, at: seconds, options: [])
    }

    /// The frame at `seconds` as it plays: rotated, with square pixels, from
    /// the first real picture track (not cover art). `filter` runs first, in
    /// the frame's stored pixels (as a saved copy's would); `maximumEdge`
    /// keeps previews of 4K and 8K video small.
    public static func displayFrame(of url: URL, at seconds: Double, filter: String? = nil,
                                    maximumEdge: Int? = nil) async throws(ConversionError) -> CGImage {
        let shrink = maximumEdge.map { "scale=w='min(iw,\($0))':h='min(ih,\($0))':force_original_aspect_ratio=decrease" }
        let chain = [filter, EditPlans.squarePixels, shrink].compactMap { $0 }.joined(separator: ",")
        return try await extractFrame(of: url, at: seconds, options: ["-map", "0:V:0", "-vf", chain])
    }

    private static func extractFrame(of url: URL, at seconds: Double, options: [String]) async throws(ConversionError) -> CGImage {
        let ffmpeg = try ToolLocator.require(.ffmpeg)
        let frameFile = temporaryFile(extension: "png")
        defer { discardTemporaryFile(frameFile) }
        let output = options + ["-frames:v", "1", "-an", "-y", frameFile.path]
        try await ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-v", "error",
                                                        "-ss", MediaToolPlans.number(max(seconds, 0)), "-i", url.path] + output)
        // Past the last picture (sound can run longer) ffmpeg writes nothing;
        // show the picture track's final frame instead.
        if !FileManager.default.fileExists(atPath: frameFile.path), let pictureEnd = try await pictureDuration(of: url) {
            try await ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-v", "error",
                                                            "-ss", MediaToolPlans.number(max(pictureEnd - 0.1, 0)),
                                                            "-i", url.path] + output)
        }
        guard let image = decodedImage(at: frameFile) else { throw .unreadableInput(url.lastPathComponent) }
        return image
    }

    /// A path for a temporary file, removed at quit if nothing has by then.
    static func temporaryFile(extension fileExtension: String) -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-\(UUID().uuidString).\(fileExtension)")
        WorkInProgress.shared.add(file)
        return file
    }

    static func discardTemporaryFile(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        WorkInProgress.shared.remove(file)
    }

    /// Reads the file into memory and decodes now: images decode lazily, and
    /// callers delete their temporary files as soon as they return.
    static func decodedImage(at file: URL) -> CGImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}
