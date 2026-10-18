import Testing
@testable import DropwheelCore

@Suite("Subtitles")
struct SubtitlesTests {
    private let srt = """
    1
    00:00:01,000 --> 00:00:04,250
    Hello there.

    2
    00:01:02,005 --> 00:01:05,000
    <i>Two</i>
    lines.

    """

    private let vtt = """
    WEBVTT

    NOTE written by hand

    00:01.000 --> 00:04.250 align:start
    Hello there.

    cue-2
    01:02:03.400 --> 01:02:05.000
    Second.
    """

    @Test("Parses SRT cues with millisecond timings")
    func parseSRT() throws {
        let cues = try Subtitles.parse(srt)
        #expect(cues == [
            SubtitleCue(start: 1_000, end: 4_250, text: "Hello there."),
            SubtitleCue(start: 62_005, end: 65_000, text: "<i>Two</i>\nlines."),
        ])
    }

    @Test("Parses VTT, skipping the header, notes, cue ids and cue settings")
    func parseVTT() throws {
        let cues = try Subtitles.parse(vtt)
        #expect(cues == [
            SubtitleCue(start: 1_000, end: 4_250, text: "Hello there."),
            SubtitleCue(start: 3_723_400, end: 3_725_000, text: "Second."),
        ])
    }

    @Test("Handles Windows line endings and a byte-order mark")
    func crlfAndBOM() throws {
        let windows = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\nHi\r\n"
        #expect(try Subtitles.parse(windows) == [SubtitleCue(start: 1_000, end: 2_000, text: "Hi")])
    }

    @Test("SRT to VTT uses dots and a WEBVTT header")
    func toVTT() throws {
        let output = try Subtitles.convert(srt, to: .vtt)
        #expect(output.hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:04.250\nHello there.\n"))
    }

    @Test("VTT to SRT numbers cues and uses commas")
    func toSRT() throws {
        let output = try Subtitles.convert(vtt, to: .srt)
        #expect(output == "1\n00:00:01,000 --> 00:00:04,250\nHello there.\n\n2\n01:02:03,400 --> 01:02:05,000\nSecond.\n")
    }

    @Test("Plain text drops timings and formatting tags")
    func toText() throws {
        #expect(try Subtitles.convert(srt, to: .txt) == "Hello there.\nTwo\nlines.\n")
    }

    @Test("Malformed timings are skipped instead of crashing",
          arguments: ["00:00:.", "00:00:.5", "99999999999999999:00:00,000", "00:75:00,000", ":", "a:b:c"])
    func malformedTimings(timing: String) throws {
        let source = "1\n\(timing) --> 00:00:02,000\nBad\n\n2\n00:00:03,000 --> 00:00:04,000\nGood\n"
        #expect(try Subtitles.parse(source) == [SubtitleCue(start: 3_000, end: 4_000, text: "Good")])
    }

    @Test("A whitespace-only line still separates cues")
    func whitespaceSeparator() throws {
        let source = "1\n00:00:01,000 --> 00:00:02,000\nOne\n \n2\n00:00:03,000 --> 00:00:04,000\nTwo\n"
        #expect(try Subtitles.parse(source).map(\.text) == ["One", "Two"])
    }

    @Test("Long timestamps format correctly")
    func longTimestamp() throws {
        let cue = SubtitleCue(start: 100 * 3_600_000 + 1, end: 100 * 3_600_000 + 2, text: "Late")
        #expect(Subtitles.srt([cue]) == "1\n100:00:00,001 --> 100:00:00,002\nLate\n")
    }

    @Test("A file with no cues is rejected")
    func empty() {
        #expect(throws: SubtitleError.noCues) { try Subtitles.parse("WEBVTT\n\n") }
    }

    @Test("Converting to a non-subtitle format is rejected")
    func wrongTarget() {
        #expect(throws: SubtitleError.unsupportedTarget(.mp3)) { try Subtitles.convert(srt, to: .mp3) }
    }
}
