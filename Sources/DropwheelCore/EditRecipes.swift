import Foundation

/// A rectangle in whole pixels, origin at the top left.
public struct PixelRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Aspect ratios offered by the crop editors.
public enum AspectRatio: String, CaseIterable, Sendable {
    case free
    case original
    case square
    case fourByThree
    case threeByTwo
    case widescreen
    case portrait9x16
    case portrait4x5

    public var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .fourByThree: "4:3"
        case .threeByTwo: "3:2"
        case .widescreen: "16:9"
        case .portrait9x16: "9:16"
        case .portrait4x5: "4:5"
        }
    }

    /// Width divided by height; nil for free-form and the picture's own shape.
    public var ratio: Double? {
        switch self {
        case .free, .original: nil
        case .square: 1
        case .fourByThree: 4.0 / 3.0
        case .threeByTwo: 3.0 / 2.0
        case .widescreen: 16.0 / 9.0
        case .portrait9x16: 9.0 / 16.0
        case .portrait4x5: 4.0 / 5.0
        }
    }
}

/// The part of a picture to keep, as fractions of its width and height
/// (origin at the top left), so it is independent of preview size.
public struct CropRecipe: Equatable, Sendable {
    public static let whole = CropRecipe(x: 0, y: 0, width: 1, height: 1)

    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The crop in pixels, kept inside the picture and at least one pixel
    /// in each direction. Video encoders need even values, so `even` rounds down to them.
    public func pixelRect(imageWidth: Int, imageHeight: Int, even: Bool = false) -> PixelRect {
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)
        let clampedWidth = min(max(width, 0), 1 - clampedX)
        let clampedHeight = min(max(height, 0), 1 - clampedY)

        var left = min(Int((clampedX * Double(imageWidth)).rounded()), max(imageWidth - 1, 0))
        var top = min(Int((clampedY * Double(imageHeight)).rounded()), max(imageHeight - 1, 0))
        var pixelWidth = min(max(Int((clampedWidth * Double(imageWidth)).rounded()), 1), imageWidth - left)
        var pixelHeight = min(max(Int((clampedHeight * Double(imageHeight)).rounded()), 1), imageHeight - top)

        if even {
            left -= left % 2
            top -= top % 2
            pixelWidth = max(2, pixelWidth - pixelWidth % 2)
            pixelHeight = max(2, pixelHeight - pixelHeight % 2)
        }
        return PixelRect(x: left, y: top, width: pixelWidth, height: pixelHeight)
    }

    /// The largest centred crop with `ratio`, or the whole picture when the
    /// ratio is free or the picture's own.
    public static func largest(_ ratio: AspectRatio, imageWidth: Int, imageHeight: Int) -> CropRecipe {
        guard let wanted = ratio.ratio, imageWidth > 0, imageHeight > 0 else { return .whole }
        let pictureRatio = Double(imageWidth) / Double(imageHeight)
        let widthShare = wanted > pictureRatio ? 1 : wanted / pictureRatio
        let heightShare = wanted > pictureRatio ? pictureRatio / wanted : 1
        return CropRecipe(x: (1 - widthShare) / 2, y: (1 - heightShare) / 2, width: widthShare, height: heightShare)
    }
}

/// The part of a recording to keep, in seconds.
public struct TrimRange: Equatable, Sendable {
    /// Shortest range worth keeping; anything shorter is treated as a mistake.
    public static let minimumLength = 0.05
    /// Allowance for rounding when comparing with the media's duration.
    static let tolerance = 0.001

    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var length: Double { end - start }

    public func isValid(durationSeconds: Double) -> Bool {
        start >= 0 && end <= durationSeconds + Self.tolerance && length >= Self.minimumLength
    }

    /// True when the range keeps the whole recording, so trimming would change nothing.
    public func coversWhole(durationSeconds: Double) -> Bool {
        start <= Self.tolerance && end >= durationSeconds - Self.tolerance
    }
}

/// Times shown and typed in the editors: "1:02:03.400" or "0:05.250".
public enum Timecode {
    /// About 115 days: longer than any real recording, small enough to never overflow.
    static let maximumSeconds = 10_000_000.0

    public static func string(from seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.000" }
        let totalMilliseconds = Int((min(max(seconds, 0), maximumSeconds) * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds / 60) % 60
        let wholeSeconds = totalSeconds % 60
        let fraction = String(format: "%02d.%03d", wholeSeconds, milliseconds)
        return hours > 0 ? "\(hours):" + String(format: "%02d:", minutes) + fraction : "\(minutes):" + fraction
    }

    /// Accepts "s", "m:s" or "h:m:s" written with digits, with an optional
    /// fraction on the seconds. Once a larger unit is given, minutes and
    /// seconds must be below 60. Anything else (signs, exponents, "inf",
    /// hex, absurdly large values) is refused rather than guessed at.
    public static func seconds(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let allowed = trimmed.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ":" || $0 == ".") }
        guard !trimmed.isEmpty, allowed else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), let seconds = Double(parts[parts.count - 1]), seconds.isFinite else { return nil }
        let units = parts.dropLast().map { Int($0) }
        guard units.allSatisfy({ $0 != nil && $0! <= Int(maximumSeconds) }) else { return nil }
        let whole = units.compactMap { $0 }
        if !whole.isEmpty, seconds >= 60 { return nil }
        if whole.count == 2, whole[1] >= 60 { return nil }
        let wholeSeconds = zip(whole, [3600, 60].suffix(whole.count)).map(*).reduce(0, +)
        let total = Double(wholeSeconds) + seconds
        return total <= maximumSeconds ? total : nil
    }
}

/// ffmpeg command plans for the crop and trim editors.
public enum EditPlans {
    /// Removes silence from the start, then from the end by reversing the audio.
    public static let trimSilenceFilter =
        "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1,areverse,"
        + "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1,areverse"

    /// Encoder settings for a crop: the picture is re-encoded, the sound copied as it is.
    public static func cropVideoOptions(_ rect: PixelRect, format: FileFormat) -> [String] {
        // The crop replaces the format's even-size rule: its rect is already even.
        videoOptions(filter: "crop=\(rect.width):\(rect.height):\(rect.x):\(rect.y)", keepingFormatFilter: false, format: format)
    }

    /// The format's video settings with `filter` as the picture filter
    /// (followed by the format's own when `keepingFormatFilter`). Keeps the
    /// first real picture track (not cover art) and every audio track, the
    /// sound copied untouched.
    static func videoOptions(filter: String?, keepingFormatFilter: Bool, format: FileFormat, extra: [String] = []) -> [String] {
        let audioSettings: Set<String> = ["-c:a", "-b:a", "-q:a"]
        let codec = FFmpegArguments.codecArguments(for: format)
        var options: [String] = []
        var placedFilter = false
        var index = 0
        while index < codec.count {
            let flag = codec[index]
            if flag == "-vf", index + 1 < codec.count {
                let combined = [filter, keepingFormatFilter ? codec[index + 1] : nil].compactMap { $0 }
                if !combined.isEmpty { options += ["-vf", combined.joined(separator: ",")] }
                placedFilter = true
                index += 2
            } else if audioSettings.contains(flag) {
                index += 2
            } else {
                options.append(flag)
                index += 1
            }
        }
        if !placedFilter, let filter { options += ["-vf", filter] }
        return ["-map", "0:V:0", "-map", "0:a?"] + options + extra + ["-c:a", "copy"]
    }

    /// Seeking before the input with a re-encode cuts on the exact frame.
    public static func trimArguments(input: String, output: String, range: TrimRange, format: FileFormat) -> [String] {
        FFmpegArguments.command(
            inputOptions: ["-ss", MediaToolPlans.number(range.start)],
            input: input,
            options: ["-t", MediaToolPlans.number(range.length)] + FFmpegArguments.codecArguments(for: format),
            output: output
        )
    }
}

/// Peaks for drawing a waveform.
public enum Waveform {
    /// The loudest absolute sample in each of `buckets` equal slices. Works
    /// on any float buffer, so a memory-mapped file needs no copy.
    public static func peaks<Samples: RandomAccessCollection>(of samples: Samples, buckets: Int) -> [Float]
        where Samples.Element == Float, Samples.Index == Int {
        guard !samples.isEmpty, buckets > 0 else { return [] }
        guard samples.count > buckets else { return samples.map(abs) }
        let size = Double(samples.count) / Double(buckets)
        return (0..<buckets).map { bucket in
            let lower = Int(Double(bucket) * size)
            let upper = min(samples.count, Int(Double(bucket + 1) * size))
            return samples[lower..<max(upper, lower + 1)].map(abs).max() ?? 0
        }
    }
}
