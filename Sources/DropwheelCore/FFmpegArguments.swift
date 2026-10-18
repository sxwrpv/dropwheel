/// Builds ffmpeg command lines for each audio and video target.
public enum FFmpegArguments {
    /// H.264 needs even frame dimensions.
    private static let evenDimensions = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    /// GIFs are capped in size and frame rate to keep files reasonable.
    private static let gifFilter =
        "fps=12,scale='min(720,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a"

    public static func encode(input: String, output: String, target: FileFormat) -> [String] {
        // -n refuses to overwrite: output paths are always fresh, so a clash is a bug.
        let head = ["-hide_banner", "-nostdin", "-n", "-i", input]
        let tail = ["-map_metadata", "0", "-progress", "pipe:1", "-nostats", output]
        return head + codecArguments(for: target) + tail
    }

    static func codecArguments(for target: FileFormat) -> [String] {
        switch target {
        // Audio
        case .mp3: ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case .wav: ["-vn", "-c:a", "pcm_s16le"]
        case .flac: ["-vn", "-c:a", "flac"]
        // The built-in Vorbis encoder is marked experimental and only does stereo.
        case .ogg: ["-vn", "-c:a", "vorbis", "-strict", "experimental", "-ac", "2", "-b:a", "192k"]
        case .opus: ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        case .aiff: ["-vn", "-c:a", "pcm_s16be"]
        case .wma: ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        // Video
        case .mp4, .mov, .mkv:
            ["-vf", evenDimensions, "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
             "-c:a", "aac", "-b:a", "192k", "-sn"] + (target == .mp4 ? ["-movflags", "+faststart"] : [])
        case .webm:
            ["-vf", evenDimensions, "-c:v", "libsvtav1", "-crf", "35", "-preset", "8", "-pix_fmt", "yuv420p",
             "-c:a", "libopus", "-b:a", "128k", "-sn"]
        case .avi:
            ["-vf", evenDimensions, "-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3", "-sn"]
        case .wmv:
            ["-vf", evenDimensions, "-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k", "-sn"]
        case .gif:
            ["-vf", gifFilter, "-an", "-loop", "0"]
        default:
            []
        }
    }
}

/// Turns ffmpeg's `-progress` key=value lines into a 0...1 fraction.
public struct FFmpegProgress: Sendable {
    private let durationMicroseconds: Double?

    public init(durationSeconds: Double?) {
        if let durationSeconds, durationSeconds > 0 {
            durationMicroseconds = durationSeconds * 1_000_000
        } else {
            durationMicroseconds = nil
        }
    }

    /// Returns a new fraction when the line carries one, otherwise nil.
    public mutating func consume(_ line: String) -> Double? {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "progress" where parts[1] == "end":
            return 1
        case "out_time_us":
            guard let durationMicroseconds, let elapsed = Double(parts[1]) else { return nil }
            return min(max(elapsed / durationMicroseconds, 0), 1)
        default:
            return nil
        }
    }
}
