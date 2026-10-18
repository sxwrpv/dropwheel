import Testing
@testable import DropwheelCore

@Suite("FFmpegArguments")
struct FFmpegArgumentsTests {
    private func args(_ target: FileFormat) -> [String] {
        FFmpegArguments.encode(input: "/in/clip.mov", output: "/out/clip.x", target: target)
    }

    @Test("Never overwrites, reports progress on stdout, and ends with the output path")
    func commonShape() {
        let arguments = args(.mp4)
        #expect(arguments.starts(with: ["-hide_banner", "-nostdin", "-n", "-i", "/in/clip.mov"]))
        #expect(arguments.contains("-progress"))
        #expect(arguments.last == "/out/clip.x")
    }

    @Test("Audio targets drop video and pick the right encoder",
          arguments: [(FileFormat.mp3, "libmp3lame"), (.m4a, "aac"), (.wav, "pcm_s16le"), (.flac, "flac"),
                      (.ogg, "vorbis"), (.opus, "libopus"), (.aiff, "pcm_s16be"), (.wma, "wmav2")])
    func audioEncoders(target: FileFormat, encoder: String) {
        let arguments = args(target)
        #expect(arguments.contains("-vn"))
        #expect(value(after: "-c:a", in: arguments) == encoder)
    }

    @Test("The built-in Vorbis encoder is enabled explicitly")
    func vorbisNeedsStrict() {
        #expect(value(after: "-strict", in: args(.ogg)) == "experimental")
    }

    @Test("Video targets pick a matching video and audio codec",
          arguments: [(FileFormat.mp4, "libx264", "aac"), (.mov, "libx264", "aac"), (.mkv, "libx264", "aac"),
                      (.webm, "libsvtav1", "libopus"), (.avi, "mpeg4", "libmp3lame"), (.wmv, "wmv2", "wmav2")])
    func videoEncoders(target: FileFormat, video: String, audio: String) {
        let arguments = args(target)
        #expect(value(after: "-c:v", in: arguments) == video)
        #expect(value(after: "-c:a", in: arguments) == audio)
    }

    @Test("H.264 output uses even dimensions and a widely playable pixel format")
    func h264Compatibility() {
        let arguments = args(.mp4)
        #expect(value(after: "-pix_fmt", in: arguments) == "yuv420p")
        #expect(value(after: "-vf", in: arguments)?.contains("trunc(iw/2)*2") == true)
    }

    @Test("GIF uses a generated palette, no audio, and loops")
    func gif() {
        let arguments = args(.gif)
        #expect(value(after: "-vf", in: arguments)?.contains("palettegen") == true)
        #expect(arguments.contains("-an"))
        #expect(value(after: "-loop", in: arguments) == "0")
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

@Suite("FFmpegProgress")
struct FFmpegProgressTests {
    @Test("Reports the fraction of the duration encoded so far")
    func fraction() {
        var progress = FFmpegProgress(durationSeconds: 10)
        #expect(progress.consume("frame=12") == nil)
        #expect(progress.consume("out_time_us=2500000") == 0.25)
    }

    @Test("Clamps to 1 and finishes on progress=end")
    func clampAndEnd() {
        var progress = FFmpegProgress(durationSeconds: 1)
        #expect(progress.consume("out_time_us=5000000") == 1)
        #expect(progress.consume("progress=end") == 1)
    }

    @Test("Without a known duration only the end is reported")
    func unknownDuration() {
        var progress = FFmpegProgress(durationSeconds: nil)
        #expect(progress.consume("out_time_us=2500000") == nil)
        #expect(progress.consume("progress=end") == 1)
    }

    @Test("Ignores N/A and malformed values")
    func malformed() {
        var progress = FFmpegProgress(durationSeconds: 10)
        #expect(progress.consume("out_time_us=N/A") == nil)
        #expect(progress.consume("garbage") == nil)
    }
}
