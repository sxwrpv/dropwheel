import Foundation

// MARK: Bleep

/// What covers a marked part.
public enum BleepSound: String, CaseIterable, Sendable {
    case tone
    case silence

    public var title: String { self == .tone ? "Bleep" : "Silence" }
}

/// The parts of a recording to cover, and what to cover them with.
public struct BleepRecipe: Equatable, Sendable {
    public var ranges: [TrimRange]
    public var sound: BleepSound

    public init(ranges: [TrimRange], sound: BleepSound) {
        self.ranges = ranges
        self.sound = sound
    }
}

public enum BleepPlans {
    /// Ranges closer than this are joined, so no sliver of a word shows between them.
    static let smallestGap = 0.002
    static let toneFrequency = 1000
    static let toneLevel = 0.25

    /// In order, starting no earlier than the recording, with overlapping and
    /// touching ranges joined and ranges with no length dropped.
    public static func merged(_ ranges: [TrimRange]) -> [TrimRange] {
        let usable = ranges
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end > max($0.start, 0) }
            .map { TrimRange(start: max($0.start, 0), end: $0.end) }
            .sorted { $0.start < $1.start }
        return usable.reduce(into: []) { result, range in
            if let last = result.last, range.start <= last.end + smallestGap {
                result[result.count - 1] = TrimRange(start: last.start, end: max(last.end, range.end))
            } else {
                result.append(range)
            }
        }
    }

    /// Cuts the first audio track at each range's edges, replaces the pieces
    /// inside ranges, and joins everything back up as `[bleeped]`. Nil when
    /// there is nothing to bleep.
    ///
    /// The cuts are exact to the sample. Switching a filter on and off with
    /// `enable=` only acts on whole audio frames, which would let the first
    /// 20 milliseconds or so of a bleeped word through. A cut past the end
    /// of the sound leaves an empty piece, which is harmless, so a range can
    /// run off the end when the file's real length isn't known exactly.
    ///
    /// `asegment` cuts by timestamp, so timestamps are first rebuilt from the
    /// sample count. Times in the editor count samples, and a file's own
    /// timestamps can drift from that: WMA's are rounded to milliseconds, and
    /// a damaged frame leaves a gap. Either would move the cuts and let
    /// part of a marked word through.
    public static func filter(_ recipe: BleepRecipe) -> String? {
        let ranges = merged(recipe.ranges)
        guard let first = ranges.first else { return nil }
        let points = ranges.flatMap { $0.start > 0 ? [$0.start, $0.end] : [$0.end] }
        let pieces = points.count + 1
        let cover = recipe.sound == .tone
            ? "aeval=\(MediaToolPlans.number(toneLevel))*sin(2*PI*\(toneFrequency)*t):c=same"
            : "volume=0"
        let startsCovered = first.start == 0
        let cut = "[0:a:0]asetpts=round(N/SR/TB),asegment=timestamps=\(points.map(MediaToolPlans.number).joined(separator: "|"))"
            + (0..<pieces).map { "[s\($0)]" }.joined()
        let parts = (0..<pieces).map { piece in
            // Each piece starts at zero, as concat expects; kept and covered pieces alternate.
            let isCovered = piece.isMultiple(of: 2) == startsCovered
            return "[s\(piece)]asetpts=PTS-STARTPTS\(isCovered ? ",\(cover)" : "")[k\(piece)]"
        }
        let join = (0..<pieces).map { "[k\($0)]" }.joined() + "concat=n=\(pieces):v=0:a=1[bleeped]"
        return ([cut] + parts + [join]).joined(separator: ";")
    }

    /// Writes the bleeped sound in the file's own format, leaving out the
    /// track's tags. With the file's tags and chapters, which `keepMetadata:
    /// false` drops, they can hold a transcript of what was bleeped.
    public static func options(_ recipe: BleepRecipe, format: FileFormat) -> [String]? {
        filter(recipe).map {
            ["-filter_complex", $0, "-map", "[bleeped]", "-map_metadata:s:a", "-1"] + FFmpegArguments.codecArguments(for: format)
        }
    }

    /// A WAV to listen to in the editor: bleeped with `recipe`, or the
    /// original sound when it is nil. Both come from ffmpeg, so they stay in
    /// step with each other and with the saved file, whatever the format.
    public static func listeningOptions(_ recipe: BleepRecipe?) -> [String] {
        let source = recipe.flatMap(filter).map { ["-filter_complex", $0, "-map", "[bleeped]"] } ?? ["-map", "0:a:0"]
        // RF64 takes over from plain WAV at its 4 GiB limit, about 7 hours of stereo.
        return source + ["-vn", "-c:a", "pcm_s16le", "-rf64", "auto"]
    }
}

/// One marked part of a recording in the bleep editor.
public struct BleepMark: Identifiable, Equatable, Sendable {
    /// Marks shorter than this are too short to hear.
    public static let shortest = TrimRange.minimumLength

    public let id: UUID
    public let start: Double
    public let end: Double

    public init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = start
        self.end = end
    }

    public var length: Double { end - start }

    /// The mark with new times, kept inside the recording and no shorter than `shortest`.
    public func with(start newStart: Double, end newEnd: Double, duration: Double) -> BleepMark {
        let keptEnd = min(max(newEnd, Self.shortest), duration)
        return BleepMark(id: id, start: max(min(newStart, keptEnd - Self.shortest), 0), end: keptEnd)
    }
}

public enum BleepEdge: Hashable, Sendable {
    case start
    case end
}

/// What a press and drag on the waveform is doing to the marks. Nothing
/// happens to a mark until the pointer moves, so a click only selects it.
public enum BleepDrag: Equatable, Sendable {
    /// On bare waveform: a click, unless the pointer moves.
    case pressing(at: Double)
    /// A new mark stretching out from where the press began.
    case drawing(id: UUID, from: Double)
    /// One edge of a mark, following the pointer from where it was grabbed.
    case resizing(BleepMark, edge: BleepEdge, grabbedAt: Double)
    case moving(BleepMark, grabbedAt: Double)

    /// What a press at `time` takes hold of. `edgeReach` is how far from an
    /// edge counts as on it, in seconds at the current zoom; a mark too
    /// narrow for that to leave a middle moves as a whole until zoomed in.
    /// Where marks overlap, the selected one comes first, then the newest.
    public static func starting(at time: Double, marks: [BleepMark], selection: UUID?, edgeReach: Double) -> BleepDrag {
        let candidates = marks.filter { $0.id == selection } + marks.reversed().filter { $0.id != selection }
        for mark in candidates where mark.length > 3 * edgeReach {
            let toStart = abs(time - mark.start)
            let toEnd = abs(time - mark.end)
            if min(toStart, toEnd) <= edgeReach {
                return .resizing(mark, edge: toStart <= toEnd ? .start : .end, grabbedAt: time)
            }
        }
        let grabbed = candidates.first { $0.start - edgeReach <= time && time <= $0.end + edgeReach }
        return grabbed.map { .moving($0, grabbedAt: time) } ?? .pressing(at: time)
    }

    /// The marks with the pointer now at `time`.
    public func applied(to marks: [BleepMark], at time: Double, duration: Double) -> [BleepMark] {
        switch self {
        case .pressing:
            return marks
        case .drawing(let id, let from):
            let drawn = BleepMark(id: id, start: min(from, time), end: max(from, time))
            return marks.contains { $0.id == id } ? marks.map { $0.id == id ? drawn : $0 } : marks + [drawn]
        case .resizing(let mark, let edge, let grabbedAt):
            let shift = time - grabbedAt
            let resized = switch edge {
            case .start: BleepMark(id: mark.id, start: max(min(mark.start + shift, mark.end - BleepMark.shortest), 0), end: mark.end)
            case .end: BleepMark(id: mark.id, start: mark.start, end: max(min(mark.end + shift, duration), mark.start + BleepMark.shortest))
            }
            return marks.map { $0.id == mark.id ? resized : $0 }
        case .moving(let mark, let grabbedAt):
            let shift = min(max(time - grabbedAt, -mark.start), duration - mark.end)
            let moved = BleepMark(id: mark.id, start: mark.start + shift, end: mark.end + shift)
            return marks.map { $0.id == mark.id ? moved : $0 }
        }
    }

    /// The marks when the drag ends: a newly drawn mark too short to hear
    /// was a slip of the hand. Marks that were already there always stay.
    public func finished(with marks: [BleepMark]) -> [BleepMark] {
        guard case .drawing(let id, _) = self else { return marks }
        return marks.filter { $0.id != id || $0.length >= BleepMark.shortest }
    }
}

/// The stretch of a recording in view in a waveform editor.
public struct WaveformWindow: Equatable, Sendable {
    public let start: Double
    public let length: Double

    public init(start: Double, length: Double) {
        self.start = start
        self.length = length
    }

    public var end: Double { start + length }

    /// `length` long around `centre`, kept inside the recording.
    public static func around(_ centre: Double, length: Double, duration: Double) -> WaveformWindow {
        WaveformWindow(start: min(max(centre - length / 2, 0), max(duration - length, 0)), length: length)
    }

    /// How long a view is at `zoom`, from 0 (the whole recording) to 1
    /// (`closest` seconds). Equal steps of zoom magnify by equal factors.
    public static func length(zoom: Double, duration: Double, closest: Double) -> Double {
        guard duration > closest, closest > 0 else { return duration }
        return duration * pow(closest / duration, zoom)
    }
}

// MARK: Audio visualizer

/// What a visualizer video shows.
public enum VisualizerContent: String, CaseIterable, Sendable {
    case waveform
    case stillImage

    public var title: String { self == .waveform ? "Waveform" : "Still Image" }
}

/// A visualizer video's canvas, in full HD.
public enum VisualizerShape: String, CaseIterable, Sendable {
    case landscape
    case portrait
    case square

    public var title: String { rawValue.capitalized }
    public var width: Int { self == .landscape ? 1920 : 1080 }
    public var height: Int { self == .portrait ? 1920 : 1080 }
}

/// A video made from a recording: an animated waveform or a still picture.
public struct VisualizerRecipe: Equatable, Sendable {
    public var content: VisualizerContent
    public var shape: VisualizerShape
    public var waveColor: RGBA
    public var background: RGBA
    /// Fitted inside the canvas, behind the waveform or alone as the still image.
    public var picture: URL?

    public init(content: VisualizerContent, shape: VisualizerShape, waveColor: RGBA, background: RGBA, picture: URL?) {
        self.content = content
        self.shape = shape
        self.waveColor = waveColor
        self.background = background
        self.picture = picture
    }

    public static let standard = VisualizerRecipe(content: .waveform, shape: .landscape,
                                                  waveColor: RGBA(red: 1, green: 0.54, blue: 0.24),
                                                  background: RGBA(red: 0.063, green: 0.094, blue: 0.157), picture: nil)

    /// A still image needs a picture to show.
    public var isComplete: Bool { content == .waveform || picture != nil }
}

public enum VisualizerPlans {
    public static let framesPerSecond = 30
    /// A video needs at least a few frames: shorter sound leaves it with no picture at all.
    public static let shortestSeconds = 0.1
    static let bandHeight = 400
    /// The length of a preview run, in seconds; a few frames' worth, because
    /// the first frames of a graph appear before the waveform has data.
    static let previewSeconds = 0.2
    /// Extra sound for a preview: the waveform draws an incomplete frame
    /// where the sound stops, so the picture has to end first.
    static let previewLeadIn = 0.25

    /// The canvas (input 0) is a picture of the background, looped for as
    /// long as the audio (input 1) lasts: `seconds`, its real length.
    public static func arguments(canvas: String, audio: String, output: String, recipe: VisualizerRecipe,
                                 seconds: Double) -> [String] {
        let picture = recipe.content == .waveform
            ? ["-filter_complex", waveGraph(recipe), "-map", "[video]"]
            : ["-map", "0:v", "-tune", "stillimage", "-pix_fmt", "yuv420p"]
        // The recording's own stream title, say, has no business in a video made from it.
        let encoder = ["-map", "1:a:0", "-map_metadata:s:a", "-1", "-c:v", "libx264", "-preset", "medium", "-crf", "20",
                       "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000", "-shortest", "-movflags", "+faststart"]
        return FFmpegArguments.command(inputOptions: loopedCanvas(canvas, seconds: seconds + 1), input: audio,
                                       options: picture + encoder, output: output, keepMetadata: false)
    }

    /// One frame of the waveform at `seconds`, made with the same filter as
    /// the video. Each new frame overwrites the last, so the output ends up
    /// holding the final one, and the run starts early enough for that one
    /// to show `seconds`.
    public static func previewArguments(canvas: String, audio: String, output: String, recipe: VisualizerRecipe,
                                        seconds: Double) -> [String] {
        let start = seconds - previewSeconds + 1 / Double(framesPerSecond)
        let slice = ["-ss", MediaToolPlans.number(max(start, 0)), "-t", MediaToolPlans.number(previewSeconds + previewLeadIn)]
        return FFmpegArguments.command(inputOptions: loopedCanvas(canvas, seconds: previewSeconds) + slice, input: audio,
                                       options: ["-filter_complex", waveGraph(recipe), "-map", "[video]", "-update", "1"],
                                       output: output, keepMetadata: false)
    }

    /// Always with an end. `-shortest` alone isn't enough: audio with no
    /// samples in it never ends the video, and ffmpeg would run forever.
    private static func loopedCanvas(_ canvas: String, seconds: Double) -> [String] {
        ["-loop", "1", "-framerate", String(framesPerSecond), "-t", MediaToolPlans.number(seconds), "-i", canvas]
    }

    /// `cline` with square-root scaling gives a solid, centred shape that
    /// stays lively for quiet speech as well as loud music. One sample is
    /// one column of the waveform, so the sound is first resampled to exactly
    /// a frame's width per frame; otherwise the frame rate would follow the
    /// recording's sample rate.
    private static func waveGraph(_ recipe: VisualizerRecipe) -> String {
        let width = recipe.shape.width
        let height = recipe.shape.height
        // Across the middle, or near the bottom so a picture stays visible.
        let top = recipe.picture == nil ? (height - bandHeight) / 2 : height - bandHeight - height / 20
        return "[1:a:0]aformat=channel_layouts=mono,aresample=\(width * framesPerSecond)"
            + ",showwaves=s=\(width)x\(bandHeight):mode=cline:scale=sqrt"
            + ":rate=\(framesPerSecond):colors=\(hex(recipe.waveColor)):draw=full[wave]"
            + ";[0:v][wave]overlay=x=0:y=\(top):shortest=1,format=yuv420p[video]"
    }

    static func hex(_ color: RGBA) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value.isNaN ? 0 : value, 0), 1) * 255).rounded()) }
        return String(format: "0x%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }
}
