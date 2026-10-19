import DropwheelCore
import Foundation

/// The audio and video tools, all through ffmpeg.
enum MediaTools {
    private static let presetCRF: [CompressionLevel: Int] = [.light: 23, .balanced: 28, .strong: 32]
    private static let presetAudioKbps: [CompressionLevel: Int] = [.light: 192, .balanced: 128, .strong: 96]
    private static let videoAudioKbps = 128
    /// The strong preset also scales video down to this width.
    private static let strongMaximumWidth = 1280
    private static let evenDimensions = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    private static let defaultSampleRate = 48_000
    private static let defaultFramesPerSecond = 30.0
    private static let maximumJoinFramesPerSecond = 60.0
    private static let losslessAudio: Set<FileFormat> = [.wav, .flac, .aiff]

    /// What Compress writes: video becomes MP4, lossless audio becomes M4A,
    /// and lossy audio keeps its format.
    static func compressedFormat(for input: FileFormat) -> FileFormat {
        if input.family == .video { return .mp4 }
        return losslessAudio.contains(input) ? .m4a : input
    }

    // MARK: Compress

    static func compress(_ input: URL, format: FileFormat, goal: CompressionGoal, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        let info = try await FFmpegRunner.probe(input)
        let originalBytes = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let target = goal.targetBytes(originalBytes: originalBytes)
        let options: [String]
        if format.family == .video {
            options = try videoCompression(goal: goal, targetBytes: target, info: info, name: input.lastPathComponent)
        } else {
            options = try audioCompression(goal: goal, targetBytes: target, info: info, output: compressedFormat(for: format),
                                           name: input.lastPathComponent)
        }
        try await FFmpegRunner.run(FFmpegArguments.command(input: input.path, options: options, output: output.path),
                                   expectedSeconds: info.durationSeconds, progress: progress)
    }

    private static func videoCompression(goal: CompressionGoal, targetBytes: Int?, info: MediaInfo, name: String) throws(ConversionError) -> [String] {
        var filter = evenDimensions
        let rate: [String]
        if let targetBytes {
            // One-pass average bitrate: the result lands close to the target, not exactly on it.
            let audioShare = info.hasAudio ? videoAudioKbps : 0
            guard let duration = info.durationSeconds,
                  let kbps = MediaToolPlans.videoBitrateKbps(targetBytes: targetBytes, durationSeconds: duration, audioKbps: audioShare) else {
                throw .targetTooSmall(name)
            }
            rate = ["-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k"]
        } else {
            let level: CompressionLevel
            if case .level(let chosen) = goal { level = chosen } else { level = .balanced }
            rate = ["-crf", "\(presetCRF[level] ?? 28)"]
            if level == .strong {
                filter = "scale='trunc(min(\(strongMaximumWidth),iw)/2)*2':-2"
            }
        }
        return ["-vf", filter, "-c:v", "libx264", "-preset", "medium"] + rate
            + ["-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "\(videoAudioKbps)k", "-movflags", "+faststart", "-sn"]
    }

    private static func audioCompression(goal: CompressionGoal, targetBytes: Int?, info: MediaInfo, output: FileFormat, name: String) throws(ConversionError) -> [String] {
        let kbps: Int
        if let targetBytes {
            guard let duration = info.durationSeconds,
                  let fitted = MediaToolPlans.audioBitrateKbps(targetBytes: targetBytes, durationSeconds: duration) else {
                throw .targetTooSmall(name)
            }
            kbps = fitted
        } else {
            let level: CompressionLevel
            if case .level(let chosen) = goal { level = chosen } else { level = .balanced }
            kbps = presetAudioKbps[level] ?? 128
        }
        return audioEncoder(for: output) + ["-b:a", "\(kbps)k"]
    }

    private static func audioEncoder(for format: FileFormat) -> [String] {
        switch format {
        case .mp3: ["-vn", "-c:a", "libmp3lame"]
        case .ogg: ["-vn", "-c:a", "vorbis", "-strict", "experimental", "-ac", "2"]
        case .opus: ["-vn", "-c:a", "libopus"]
        case .wma: ["-vn", "-c:a", "wmav2"]
        default: ["-vn", "-c:a", "aac"]
        }
    }

    // MARK: Metadata

    /// Copies every stream untouched, dropping file tags and chapters. Data
    /// tracks (timecode, GPS from action cameras) are left out: many
    /// containers can't hold them, and they can carry location.
    static func stripMetadata(_ input: URL, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        let duration = (try? await FFmpegRunner.probe(input))?.durationSeconds
        let options = ["-map", "0", "-map", "-0:d", "-c", "copy", "-fflags", "+bitexact"]
        let arguments = FFmpegArguments.command(input: input.path, options: options, output: output.path, keepMetadata: false)
        try await FFmpegRunner.run(arguments, expectedSeconds: duration, progress: progress)
    }

    // MARK: Loudness and channels

    /// Two passes: measure the loudness, then apply one correction for the
    /// whole recording, so quiet and loud passages keep their balance.
    static func normalize(_ input: URL, format: FileFormat, target: LoudnessTarget, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        let info = try await FFmpegRunner.probe(input)
        let measure = ["-hide_banner", "-nostdin", "-i", input.path, "-vn", "-sn", "-dn",
                       "-af", MediaToolPlans.loudnessMeasurementFilter(target: target),
                       "-progress", "pipe:1", "-nostats", "-f", "null", "-"]
        let report = try await FFmpegRunner.run(measure, expectedSeconds: info.durationSeconds,
                                                progress: FFmpegRunner.portion(progress, from: 0, to: 0.5))
        guard let measured = LoudnessMeasurement.parse(report) else {
            throw .toolFailed(tool: "ffmpeg", message: "Couldn’t measure the loudness. The recording may be silent.")
        }
        let options = ["-af", MediaToolPlans.loudnormFilter(target: target, measured: measured),
                       "-ar", "\(info.sampleRate ?? defaultSampleRate)"] + FFmpegArguments.codecArguments(for: format)
        try await FFmpegRunner.run(FFmpegArguments.command(input: input.path, options: options, output: output.path),
                                   expectedSeconds: info.durationSeconds,
                                   progress: FFmpegRunner.portion(progress, from: 0.5, to: 1))
    }

    static func changeChannels(_ input: URL, format: FileFormat, layout: ChannelLayout, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        let duration = (try? await FFmpegRunner.probe(input))?.durationSeconds
        // The built-in Vorbis encoder only writes stereo; Opus in an Ogg file plays everywhere Ogg does.
        let codec = format == .ogg && layout == .mono
            ? ["-vn", "-c:a", "libopus", "-b:a", "96k"]
            : FFmpegArguments.codecArguments(for: format)
        let options = codec + ["-ac", "\(layout.channelCount)"]
        try await FFmpegRunner.run(FFmpegArguments.command(input: input.path, options: options, output: output.path),
                                   expectedSeconds: duration, progress: progress)
    }

    // MARK: Video

    /// Speeds the picture up or down; the sound follows without changing pitch.
    static func changeSpeed(_ input: URL, format: FileFormat, factor: Double, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        let info = try await FFmpegRunner.probe(input)
        let filters = MediaToolPlans.speedFilters(factor: factor, hasAudio: info.hasAudio)
        var options = FFmpegArguments.codecArguments(for: format)
        if let index = options.firstIndex(of: "-vf"), index + 1 < options.count {
            options[index + 1] = filters.video + "," + options[index + 1]
        } else {
            options = ["-vf", filters.video] + options
        }
        options += filters.audio.map { ["-af", $0] } ?? ["-an"]
        try await FFmpegRunner.run(FFmpegArguments.command(input: input.path, options: options, output: output.path),
                                   expectedSeconds: info.durationSeconds.map { $0 / factor }, progress: progress)
    }

    /// Writes each part into the folder at `output`, cut at exact times.
    static func split(_ input: URL, format: FileFormat, plan: SplitPlan, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        let info = try await FFmpegRunner.probe(input)
        let ranges = MediaToolPlans.splitRanges(durationSeconds: info.durationSeconds ?? 0, plan: plan)
        guard ranges.count >= 2 else { throw .nothingToSplit(input.lastPathComponent) }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        let digits = max(2, String(ranges.count).count)
        let stem = input.formatStem
        for (index, range) in ranges.enumerated() {
            let number = String(index + 1)
            let name = "\(stem) \(String(repeating: "0", count: digits - number.count))\(number).\(format.preferredExtension)"
            let arguments = FFmpegArguments.command(
                inputOptions: ["-ss", MediaToolPlans.number(range.start)],
                input: input.path,
                options: ["-t", MediaToolPlans.number(range.length)] + FFmpegArguments.codecArguments(for: format),
                output: output.appendingPathComponent(name).path
            )
            let share = 1.0 / Double(ranges.count)
            try await FFmpegRunner.run(arguments, expectedSeconds: range.length,
                                       progress: FFmpegRunner.portion(progress, from: Double(index) * share, to: Double(index + 1) * share))
        }
    }

    /// Joins clips in selection order into one MP4 sized like the first clip.
    static func join(_ inputs: [URL], output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        var clips: [JoinClip] = []
        var first: MediaInfo?
        for input in inputs {
            let info = try await FFmpegRunner.probe(input)
            guard info.hasVideo, let duration = info.durationSeconds, duration > 0 else {
                throw .unreadableInput(input.lastPathComponent)
            }
            first = first ?? info
            clips.append(JoinClip(path: input.path, hasAudio: info.hasAudio, durationSeconds: duration))
        }
        // The displayed size, so a portrait phone clip first gives a portrait result.
        guard let canvas = first, let width = canvas.displayWidth, let height = canvas.displayHeight else {
            throw .unreadableInput(inputs.first?.lastPathComponent ?? "video")
        }
        let framesPerSecond = min(canvas.framesPerSecond ?? defaultFramesPerSecond, maximumJoinFramesPerSecond)
        let arguments = MediaToolPlans.joinArguments(clips: clips, width: width - width % 2, height: height - height % 2,
                                                     framesPerSecond: framesPerSecond, output: output.path)
        try await FFmpegRunner.run(arguments, expectedSeconds: clips.map(\.durationSeconds).reduce(0, +), progress: progress)
    }
}
