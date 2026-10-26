import Foundation

/// One piece of a split, in seconds.
public struct SplitRange: Equatable, Sendable {
    public let start: Double
    public let length: Double

    public init(start: Double, length: Double) {
        self.start = start
        self.length = length
    }
}

/// A clip to join, as far as the filter graph needs to know.
public struct JoinClip: Equatable, Sendable {
    public let path: String
    public let hasAudio: Bool
    public let durationSeconds: Double

    public init(path: String, hasAudio: Bool, durationSeconds: Double) {
        self.path = path
        self.hasAudio = hasAudio
        self.durationSeconds = durationSeconds
    }
}

/// ffmpeg command plans for the audio and video tools.
public enum MediaToolPlans {
    /// Below this the picture falls apart, so a target that needs less is refused.
    static let minimumVideoKbps = 100
    static let minimumAudioKbps = 32
    static let maximumAudioKbps = 320
    /// One-pass encoders land near, not exactly on, the requested bitrate,
    /// so a target size keeps 5% in reserve.
    static let targetHeadroom = 0.95
    /// Split parts shorter than this are folded into their neighbour or refused.
    static let minimumPartSeconds = 1.0
    private static let joinSampleRate = 48_000
    private static let truePeakDB = "-1.5"
    private static let loudnessRange = "11"

    // MARK: Bitrates

    public static func videoBitrateKbps(targetBytes: Int, durationSeconds: Double, audioKbps: Int) -> Int? {
        guard durationSeconds > 0, targetBytes > 0 else { return nil }
        let totalKbps = Double(targetBytes) * 8 * targetHeadroom / durationSeconds / 1000
        let videoKbps = Int(totalKbps.rounded()) - audioKbps
        return videoKbps >= minimumVideoKbps ? videoKbps : nil
    }

    public static func audioBitrateKbps(targetBytes: Int, durationSeconds: Double) -> Int? {
        guard durationSeconds > 0, targetBytes > 0 else { return nil }
        let kbps = Int(Double(targetBytes) * 8 / durationSeconds / 1000)
        guard kbps >= minimumAudioKbps else { return nil }
        return min(kbps, maximumAudioKbps)
    }

    // MARK: Speed

    /// atempo accepts 0.5–2 reliably, so larger changes are chained.
    public static func atempoChain(for factor: Double) -> [Double] {
        guard factor.isFinite, factor > 0 else { return [] }
        var remaining = factor
        var chain: [Double] = []
        while remaining > 2 {
            chain.append(2)
            remaining /= 2
        }
        while remaining < 0.5 {
            chain.append(0.5)
            remaining /= 0.5
        }
        return chain + [remaining]
    }

    /// Video and audio filters for a speed change. Audio keeps its pitch.
    public static func speedFilters(factor: Double, hasAudio: Bool) -> (video: String, audio: String?) {
        let video = "setpts=PTS/\(number(factor))"
        let audio = hasAudio ? atempoChain(for: factor).map { "atempo=\(number($0))" }.joined(separator: ",") : nil
        return (video, audio)
    }

    // MARK: Splitting

    public static func splitRanges(durationSeconds: Double, plan: SplitPlan) -> [SplitRange] {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }
        switch plan {
        case .equalParts(let count):
            guard count >= 2 else { return [] }
            let length = durationSeconds / Double(count)
            guard length >= minimumPartSeconds else { return [] }
            return (0..<count).map { SplitRange(start: Double($0) * length, length: length) }
        case .everySeconds(let seconds):
            guard seconds > 0, durationSeconds > Double(seconds) else { return [] }
            var ranges = stride(from: 0.0, to: durationSeconds, by: Double(seconds)).map { start in
                SplitRange(start: start, length: min(Double(seconds), durationSeconds - start))
            }
            // A sliver at the end (say 0.4 s) joins the part before it.
            if ranges.count > 1, let last = ranges.last, last.length < minimumPartSeconds {
                ranges.removeLast()
                let previous = ranges.removeLast()
                ranges.append(SplitRange(start: previous.start, length: previous.length + last.length))
            }
            return ranges.count >= 2 ? ranges : []
        }
    }

    // MARK: Joining

    /// Scales and letterboxes each clip onto the first clip's canvas, and
    /// stands in silence for clips without audio, so concat sees matching streams.
    public static func joinArguments(clips: [JoinClip], width: Int, height: Int, framesPerSecond: Double, output: String) -> [String] {
        var inputs = clips.flatMap { ["-i", $0.path] }
        var silentInputIndex = clips.count
        var graph: [String] = []
        var concatInputs = ""

        for (index, clip) in clips.enumerated() {
            // Square any anamorphic pixels first, so the fit below sees the displayed shape.
            graph.append("[\(index):v]scale=iw*sar:ih,setsar=1,scale=\(width):\(height):force_original_aspect_ratio=decrease,"
                + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(number(framesPerSecond)),format=yuv420p[v\(index)]")
            let audioSource: String
            if clip.hasAudio {
                audioSource = "[\(index):a]"
            } else {
                inputs += ["-f", "lavfi", "-t", number(clip.durationSeconds), "-i", "anullsrc=r=\(joinSampleRate):cl=stereo"]
                audioSource = "[\(silentInputIndex):a]"
                silentInputIndex += 1
            }
            graph.append("\(audioSource)aresample=\(joinSampleRate),aformat=channel_layouts=stereo[a\(index)]")
            concatInputs += "[v\(index)][a\(index)]"
        }
        graph.append("\(concatInputs)concat=n=\(clips.count):v=1:a=1[v][a]")

        return ["-hide_banner", "-nostdin", "-n"] + inputs + [
            "-filter_complex", graph.joined(separator: ";"),
            "-map", "[v]", "-map", "[a]",
            "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats", output,
        ]
    }

    // MARK: Loudness

    /// First pass: measure only.
    public static func loudnessMeasurementFilter(target: LoudnessTarget) -> String {
        "loudnorm=I=\(target.integratedLUFS):TP=\(truePeakDB):LRA=\(loudnessRange):print_format=json"
    }

    /// Second pass: apply the measured correction as a plain gain change.
    public static func loudnormFilter(target: LoudnessTarget, measured: LoudnessMeasurement) -> String {
        "loudnorm=I=\(target.integratedLUFS):TP=\(truePeakDB):LRA=\(loudnessRange)"
            + ":measured_I=\(measured.integrated):measured_TP=\(measured.truePeak)"
            + ":measured_LRA=\(measured.range):measured_thresh=\(measured.threshold)"
            + ":offset=\(measured.offset):linear=true"
    }

    /// "2" rather than "2.0", so filter strings and file names stay tidy.
    public static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// "2x", "0.5x": used in the names of speed-changed copies.
    public static func speedLabel(_ factor: Double) -> String {
        number(factor) + "x"
    }
}

/// The first-pass report from ffmpeg's loudnorm filter.
public struct LoudnessMeasurement: Equatable, Sendable {
    public let integrated: String
    public let truePeak: String
    public let range: String
    public let threshold: String
    public let offset: String

    public init(integrated: String, truePeak: String, range: String, threshold: String, offset: String) {
        self.integrated = integrated
        self.truePeak = truePeak
        self.range = range
        self.threshold = threshold
        self.offset = offset
    }

    /// Reads the JSON block loudnorm prints at the end of its stderr output.
    public static func parse(_ report: String) -> LoudnessMeasurement? {
        guard let open = report.lastIndex(of: "{"),
              let close = report[open...].firstIndex(of: "}"),
              let values = try? JSONDecoder().decode([String: String].self, from: Data(report[open...close].utf8)),
              let integrated = values["input_i"], let truePeak = values["input_tp"], let range = values["input_lra"],
              let threshold = values["input_thresh"], let offset = values["target_offset"] else { return nil }
        // "-inf" (silence) in any field can't be applied in the second pass.
        let all = [integrated, truePeak, range, threshold, offset]
        guard all.allSatisfy({ Double($0)?.isFinite == true }) else { return nil }
        return LoudnessMeasurement(integrated: integrated, truePeak: truePeak, range: range, threshold: threshold, offset: offset)
    }
}

/// What ffprobe reports about a media file.
public struct MediaInfo: Equatable, Sendable {
    public let durationSeconds: Double?
    /// Coded picture size, as stored.
    public let width: Int?
    public let height: Int?
    /// Size as shown: rotated for portrait phone video, widened for anamorphic pixels.
    public let displayWidth: Int?
    public let displayHeight: Int?
    public let framesPerSecond: Double?
    public let sampleRate: Int?
    public let channels: Int?
    public let hasAudio: Bool
    public let hasVideo: Bool
    /// True for video turned a quarter turn for display, such as portrait phone clips.
    public let isSideways: Bool

    /// The picture's size after rotation, in stored pixels. ffmpeg rotates
    /// frames before filtering, so crops are measured in this space.
    public var rotatedSize: (width: Int, height: Int)? {
        guard let width, let height else { return nil }
        return isSideways ? (height, width) : (width, height)
    }

    /// Parses `ffprobe -print_format json -show_format -show_streams`.
    /// Album art in audio files is not counted as video.
    public static func parse(ffprobeJSON data: Data) -> MediaInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let streams = root["streams"] as? [[String: Any]] ?? []
        let isCoverArt: ([String: Any]) -> Bool = { stream in
            (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1
        }
        let video = streams.first { $0["codec_type"] as? String == "video" && !isCoverArt($0) }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        let display = video.flatMap(displaySize)
        return MediaInfo(
            durationSeconds: duration(root: root, streams: streams),
            width: video?["width"] as? Int,
            height: video?["height"] as? Int,
            displayWidth: display?.width,
            displayHeight: display?.height,
            framesPerSecond: video.flatMap(frameRate),
            sampleRate: (audio?["sample_rate"] as? String).flatMap(Int.init),
            channels: audio?["channels"] as? Int,
            hasAudio: audio != nil,
            hasVideo: video != nil,
            isSideways: video.map(isSideways) ?? false
        )
    }

    /// The container's duration, or the longest stream's when the container
    /// doesn't say (browser-recorded WebM, raw AAC).
    private static func duration(root: [String: Any], streams: [[String: Any]]) -> Double? {
        if let format = ((root["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init), format > 0 {
            return format
        }
        return streams.compactMap { ($0["duration"] as? String).flatMap(Double.init) }.max()
    }

    /// The average rate; `r_frame_rate` can be a misleading maximum for
    /// variable-rate phone video.
    private static func frameRate(of stream: [String: Any]) -> Double? {
        for key in ["avg_frame_rate", "r_frame_rate"] {
            if let rate = (stream[key] as? String).flatMap(fraction), rate > 0 { return rate }
        }
        return nil
    }

    private static func displaySize(of stream: [String: Any]) -> (width: Int, height: Int)? {
        guard let width = stream["width"] as? Int, let height = stream["height"] as? Int else { return nil }
        let aspect = (stream["sample_aspect_ratio"] as? String).flatMap(ratio) ?? 1
        let shownWidth = Int((Double(width) * aspect).rounded())
        return isSideways(stream) ? (height, shownWidth) : (shownWidth, height)
    }

    /// True when a display matrix (or the older "rotate" tag) turns the picture a quarter turn.
    private static func isSideways(_ stream: [String: Any]) -> Bool {
        let sideData = stream["side_data_list"] as? [[String: Any]] ?? []
        let matrixRotation = sideData.compactMap { ($0["rotation"] as? NSNumber)?.intValue }.first
        let tagRotation = ((stream["tags"] as? [String: Any])?["rotate"] as? String).flatMap(Int.init)
        guard let rotation = matrixRotation ?? tagRotation else { return false }
        return abs(rotation) % 180 == 90
    }

    private static func fraction(_ text: String) -> Double? {
        let parts = text.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return parts.count == 1 ? parts[0] : nil }
        return parts[0] / parts[1]
    }

    /// "4:3" → 1.333. Unknown or zero ratios count as square pixels.
    private static func ratio(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }
}
