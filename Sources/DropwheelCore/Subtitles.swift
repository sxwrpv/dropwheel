import Foundation

/// One timed caption. Times are milliseconds from the start of the media.
public struct SubtitleCue: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let text: String

    public init(start: Int, end: Int, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum SubtitleError: Error, Equatable, Sendable {
    case noCues
    case unsupportedTarget(FileFormat)
}

/// Reads SRT and WebVTT, and writes SRT, WebVTT or plain text.
public enum Subtitles {
    private static let arrow = "-->"
    /// Longest plausible timestamp; anything beyond is treated as malformed.
    private static let maximumHours = 999
    private static let unitsPerSexagesimalPlace = 60

    public static func convert(_ source: String, to target: FileFormat) throws(SubtitleError) -> String {
        guard [.srt, .vtt, .txt].contains(target) else { throw .unsupportedTarget(target) }
        let cues = try parse(source)
        switch target {
        case .srt: return srt(cues)
        case .vtt: return vtt(cues)
        default: return plainText(cues)
        }
    }

    /// Parses either format. Blocks without a timing line (the WEBVTT
    /// header, NOTE and STYLE blocks) are skipped.
    public static func parse(_ source: String) throws(SubtitleError) -> [SubtitleCue] {
        let normalized = source
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // A line holding only spaces still separates two cues.
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.allSatisfy(\.isWhitespace) ? "" : String($0) }
            .joined(separator: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        let cues = blocks.compactMap(parseBlock)
        guard !cues.isEmpty else { throw .noCues }
        return cues
    }

    private static func parseBlock(_ block: String) -> SubtitleCue? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let timingIndex = lines.firstIndex(where: { $0.contains(arrow) }) else { return nil }
        let sides = lines[timingIndex].components(separatedBy: arrow)
        guard sides.count == 2,
              let start = milliseconds(sides[0]),
              // VTT may follow the end time with cue settings such as "align:start".
              let endToken = sides[1].split(separator: " ").first,
              let end = milliseconds(String(endToken)) else { return nil }
        let text = lines[(timingIndex + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SubtitleCue(start: start, end: end, text: text)
    }

    /// Accepts "HH:MM:SS,mmm", "HH:MM:SS.mmm" and VTT's short "MM:SS.mmm".
    /// Out-of-range or malformed fields return nil rather than trapping.
    static func milliseconds(_ raw: String) -> Int? {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsParts = parts[parts.count - 1].split(separator: ".", omittingEmptySubsequences: false)
        let sexagesimal = 0..<unitsPerSexagesimalPlace
        guard secondsParts.count <= 2,
              let secondsText = secondsParts.first,
              let seconds = Int(secondsText), sexagesimal.contains(seconds),
              let minutes = Int(parts[parts.count - 2]), sexagesimal.contains(minutes) else { return nil }

        var hours = 0
        if parts.count == 3 {
            guard let parsed = Int(parts[0]), (0...maximumHours).contains(parsed) else { return nil }
            hours = parsed
        }
        let fraction = secondsParts.count == 2 ? String(secondsParts[1].prefix(3)) : ""
        guard let millis = Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)), millis >= 0 else { return nil }
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [SubtitleCue]) -> String {
        let body = cues.map { cue in
            "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(cue.text)\n"
        }.joined(separator: "\n")
        return "WEBVTT\n\n" + body
    }

    /// Caption text only, one line per caption line, with markup removed.
    static func plainText(_ cues: [SubtitleCue]) -> String {
        let lines = cues.flatMap { cue in
            stripMarkup(cue.text).split(separator: "\n").map(String.init)
        }
        return lines.map { $0 + "\n" }.joined()
    }

    private static func stripMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
    }

    private static func timestamp(_ milliseconds: Int, separator: String) -> String {
        let millis = milliseconds % 1000
        let totalSeconds = milliseconds / 1000
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return "\(padded(hours, 2)):\(padded(minutes, 2)):\(padded(seconds, 2))\(separator)\(padded(millis, 3))"
    }

    private static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
