import CoreGraphics
import DropwheelCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DropwheelEngines

/// End-to-end tests for Bleep Audio and the audio visualizer.
final class AudioEditToolsTests {
    private static let hasFFmpeg = ToolLocator.url(for: .ffmpeg) != nil
    private static let sampleRate = 44_100
    /// Most of a 16-bit step: a bleeped copy is otherwise identical to the original.
    private static let sameSample: Float = 3.0 / 32_768
    private let folder: URL
    private let tools = ToolService()

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropwheel-audio-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Bleep

    @Test("Silence covers exactly the marked part, to the sample", .enabled(if: hasFFmpeg))
    func silenceIsExact() async throws {
        let input = try makeNoise(named: "talk.wav", seconds: 3)
        let output = try await tools.run(.bleep, on: [input], options: .bleep(recipe(1...2, sound: .silence)))
        #expect(output.lastPathComponent == "talk bleeped.wav")
        let before = try samples(input)
        let after = try samples(output)
        #expect(after.count == before.count)
        #expect(after[(1 * Self.sampleRate)..<(2 * Self.sampleRate)].allSatisfy { $0 == 0 })
        expectSame(before, after, in: 0..<(1 * Self.sampleRate))
        expectSame(before, after, in: (2 * Self.sampleRate)..<before.count)
    }

    @Test("A bleep is a 1 kHz tone in place of the marked part", .enabled(if: hasFFmpeg))
    func toneReplacesRange() async throws {
        let input = try makeNoise(named: "talk.wav", seconds: 3)
        let output = try await tools.run(.bleep, on: [input], options: .bleep(recipe(1...2, sound: .tone)))
        let before = try samples(input)
        let after = try samples(output)
        let bleep = after[(1 * Self.sampleRate)..<(2 * Self.sampleRate)]
        #expect(abs(zeroCrossings(bleep) - 2000) < 8)
        #expect(abs((bleep.max() ?? 0) - 0.25) < 0.01)
        expectSame(before, after, in: 0..<(1 * Self.sampleRate))
        expectSame(before, after, in: (2 * Self.sampleRate)..<before.count)
    }

    @Test("Ranges can start at the beginning and run past the end", .enabled(if: hasFFmpeg))
    func edges() async throws {
        let input = try makeNoise(named: "talk.wav", seconds: 3)
        let ranges = [TrimRange(start: 0, end: 0.5), TrimRange(start: 2.5, end: 9)]
        let output = try await tools.run(.bleep, on: [input], options: .bleep(BleepRecipe(ranges: ranges, sound: .silence)))
        let before = try samples(input)
        let after = try samples(output)
        #expect(after.count == before.count)
        #expect(after[0..<(Self.sampleRate / 2)].allSatisfy { $0 == 0 })
        #expect(after[(Self.sampleRate * 5 / 2)...].allSatisfy { $0 == 0 })
        expectSame(before, after, in: (Self.sampleRate / 2)..<(Self.sampleRate * 5 / 2))
    }

    @Test("Overlapping ranges cover everything between them", .enabled(if: hasFFmpeg))
    func overlaps() async throws {
        let input = try makeNoise(named: "talk.wav", seconds: 3)
        let ranges = [TrimRange(start: 1.4, end: 2), TrimRange(start: 1, end: 1.5)]
        let output = try await tools.run(.bleep, on: [input], options: .bleep(BleepRecipe(ranges: ranges, sound: .silence)))
        #expect(try samples(output)[(1 * Self.sampleRate)..<(2 * Self.sampleRate)].allSatisfy { $0 == 0 })
    }

    @Test("Bleeped copies stay in the file's format, with the tone in place", .enabled(if: hasFFmpeg),
          arguments: [FileFormat.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma])
    func everyFormat(format: FileFormat) async throws {
        let wav = try makeNoise(named: "source.wav", seconds: 2)
        let input = try generate("talk.\(format.preferredExtension)", ["-i", wav.path] + FFmpegArguments.codecArguments(for: format))
        let output = try await tools.run(.bleep, on: [input], options: .bleep(recipe(0.5...1, sound: .tone)))
        #expect(output.pathExtension == format.preferredExtension)
        #expect(abs(try duration(output) - duration(input)) < 0.1)
        // Well inside the range, so an encoder's small delay doesn't matter.
        let converted = try samples(output)
        #expect(toneShare(converted[(Self.sampleRate * 6 / 10)..<(Self.sampleRate * 9 / 10)]) > 0.8)
        #expect(toneShare(converted[(Self.sampleRate * 12 / 10)..<(Self.sampleRate * 15 / 10)]) < 0.1)
    }

    @Test("Nothing of a marked part survives, in any format", .enabled(if: hasFFmpeg),
          arguments: [FileFormat.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma])
    func noLeak(format: FileFormat) async throws {
        let burst = try makeBurst()
        let input = try generate("talk.\(format.preferredExtension)", ["-i", burst.path] + FFmpegArguments.codecArguments(for: format))
        try await expectBurstCovered(in: input)
    }

    @Test("A damaged recording is bleeped where its waveform shows the sound", .enabled(if: hasFFmpeg))
    func damagedRecording() async throws {
        let input = try generate("talk.mp3", ["-i", try makeBurst().path] + FFmpegArguments.codecArguments(for: .mp3))
        let whole = try samples(input).count
        // Scrambled frames keep their headers, so timestamps carry on counting
        // them, but the decoder drops their samples before the burst.
        try scrambleFrames(of: input, first: 40, count: 3)
        #expect(try samples(input).count < whole - 2 * 1152)
        try await expectBurstCovered(in: input)
    }

    /// Scrambles the side information of a few MP3 frames, leaving their headers.
    private func scrambleFrames(of url: URL, first: Int, count: Int) throws {
        var bytes = try Data(contentsOf: url)
        let frames = bytes.indices.dropLast(3).filter { index in
            bytes[index] == 0xFF && bytes[index + 1] & 0xE0 == 0xE0
                && ![0, 15].contains(bytes[index + 2] >> 4) && (bytes[index + 2] >> 2) & 3 != 3
        }
        for frame in frames[first..<(first + count)] {
            for index in (frame + 4)..<(frame + 36) { bytes[index] ^= 0xFF }
        }
        try bytes.write(to: url)
    }

    /// Marks the burst where it shows when the file is decoded, as the
    /// editor's waveform does, and requires that none of it is left.
    private func expectBurstCovered(in input: URL) async throws {
        let decoded = try samples(input)
        let isLoud: (Float) -> Bool = { abs($0) > 0.05 }
        let first = try #require(decoded.firstIndex(where: isLoud))
        let last = try #require(decoded.lastIndex(where: isLoud))
        let margin = 0.01
        let range = TrimRange(start: Double(first) / Double(Self.sampleRate) - margin,
                              end: Double(last) / Double(Self.sampleRate) + margin)
        let output = try await tools.run(.bleep, on: [input], options: .bleep(BleepRecipe(ranges: [range], sound: .silence)))
        let left = try samples(output).reduce(Float(0)) { max($0, abs($1)) }
        #expect(left < 0.05, "\(input.pathExtension): \(left) left after bleeping \(range)")
    }

    /// Two seconds of silence, a second of loud noise, then more silence.
    private func makeBurst() throws -> URL {
        try generate("burst.wav", ["-f", "lavfi", "-i", "aevalsrc='if(between(t,2,3),0.5*(2*random(0)-1),0)':s=\(Self.sampleRate):d=4"])
    }

    @Test("Bleeps are exact at any sample rate and channel layout", .enabled(if: hasFFmpeg),
          arguments: [(8_000, "mono"), (22_050, "stereo"), (48_000, "5.1"), (96_000, "stereo")])
    func anyRateAndLayout(rate: Int, layout: String) async throws {
        let input = try generate("talk.wav", ["-f", "lavfi", "-i", "anoisesrc=color=pink:sample_rate=\(rate):duration=3:amplitude=0.4",
                                              "-af", "aformat=channel_layouts=\(layout)", "-c:a", "pcm_s16le"])
        let output = try await tools.run(.bleep, on: [input], options: .bleep(recipe(1...2, sound: .silence)))
        #expect(try probe(output, "stream=channel_layout") == probe(input, "stream=channel_layout"))
        let before = try samples(input, rate: rate)
        let after = try samples(output, rate: rate)
        #expect(after.count == before.count)
        #expect(after[(1 * rate)..<(2 * rate)].allSatisfy { $0 == 0 })
        expectSame(before, after, in: 0..<(1 * rate))
        expectSame(before, after, in: (2 * rate)..<before.count)
    }

    @Test("Tags, lyrics and chapters are left out of a bleeped copy", .enabled(if: hasFFmpeg))
    func dropsTags() async throws {
        let metadata = folder.appendingPathComponent("tags.txt")
        try """
        ;FFMETADATA1
        title=Interview
        lyrics=My number is 123-45-6789
        comment=Transcript follows
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=1000
        title=The private bit
        """.write(to: metadata, atomically: true, encoding: .utf8)
        let wav = try makeNoise(named: "source.wav", seconds: 2)
        let input = try generate("talk.flac", ["-i", wav.path, "-i", metadata.path, "-map_metadata", "1", "-c:a", "flac"])
        #expect(try probe(input, "format_tags=lyrics").contains("123-45-6789"))
        let output = try await tools.run(.bleep, on: [input], options: .bleep(recipe(0.5...1, sound: .tone)))
        // ffmpeg adds its own encoder tag; nothing of the original's remains.
        let tags = try probe(output, "format_tags") + probe(output, "stream_tags")
        #expect(!tags.contains("123-45-6789") && !tags.contains("Interview") && !tags.contains("Transcript"))
        #expect(try probe(output, "chapter_tags").isEmpty)
    }

    @Test("Stereo stays stereo", .enabled(if: hasFFmpeg))
    func keepsChannels() async throws {
        let input = try generate("stereo.flac", ["-f", "lavfi", "-i", "anoisesrc=color=pink:sample_rate=44100:duration=2:amplitude=0.4",
                                                 "-ac", "2", "-c:a", "flac"])
        let output = try await tools.run(.bleep, on: [input], options: .bleep(recipe(0.5...1, sound: .tone)))
        #expect(try probe(output, "stream=channels") == "2")
    }

    @Test("Marking nothing is refused", .enabled(if: hasFFmpeg))
    func nothingMarked() async throws {
        let input = try makeNoise(named: "talk.wav", seconds: 1)
        await #expect(throws: ConversionError.nothingToBleep("talk.wav")) {
            try await self.tools.run(.bleep, on: [input], options: .bleep(BleepRecipe(ranges: [], sound: .tone)))
        }
        await #expect(throws: ConversionError.nothingToBleep("talk.wav")) {
            try await self.tools.run(.bleep, on: [input], options: .bleep(BleepRecipe(ranges: [TrimRange(start: 2, end: 1)], sound: .tone)))
        }
    }

    @Test("Two hundred bleeps finish quickly", .enabled(if: hasFFmpeg), .timeLimit(.minutes(1)))
    func manyBleeps() async throws {
        let input = try makeNoise(named: "talk.wav", seconds: 45)
        let ranges = (0..<200).map { TrimRange(start: Double($0) * 0.2, end: Double($0) * 0.2 + 0.05) }
        let started = ContinuousClock.now
        let output = try await tools.run(.bleep, on: [input], options: .bleep(BleepRecipe(ranges: ranges, sound: .tone)))
        #expect(ContinuousClock.now - started < .seconds(20))
        #expect(abs(try duration(output) - 45) < 0.05)
    }

    // MARK: Editor support

    @Test("A timeline gives the decoded length and where the loud parts are", .enabled(if: hasFFmpeg))
    func timeline() async throws {
        let input = try generate("half.wav", ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=1",
                                              "-f", "lavfi", "-i", "anoisesrc=sample_rate=44100:duration=1:amplitude=0.8",
                                              "-filter_complex", "[0:a][1:a]concat=n=2:v=0:a=1"])
        let timeline = try await MediaPreview.timeline(of: input, bucketsPerSecond: 100, maximumBuckets: 10_000)
        #expect(abs(timeline.seconds - 2) < 0.01)
        #expect(timeline.peaks.count == 200 || timeline.peaks.count == 199)
        #expect(timeline.peaks[0..<90].allSatisfy { $0 < 0.01 })
        #expect(timeline.peaks[110...].allSatisfy { $0 > 0.1 })
    }

    @Test("Timelines never exceed the bucket limit", .enabled(if: hasFFmpeg))
    func timelineLimit() async throws {
        let input = try makeNoise(named: "talk.wav", seconds: 2)
        let timeline = try await MediaPreview.timeline(of: input, bucketsPerSecond: 100, maximumBuckets: 50)
        #expect(timeline.peaks.count == 50)
    }

    @Test("Listening copies match the original and the saved bleep", .enabled(if: hasFFmpeg))
    func listeningCopies() async throws {
        let input = try makeNoise(named: "talk.wav", seconds: 2)
        let original = try await MediaPreview.listeningCopy(of: input, recipe: nil)
        let bleeped = try await MediaPreview.listeningCopy(of: input, recipe: recipe(0.5...1, sound: .silence))
        let before = try samples(input)
        #expect(original.pathExtension == "wav")
        expectSame(before, try samples(original), in: 0..<before.count)
        let after = try samples(bleeped)
        #expect(after[(Self.sampleRate / 2)..<(1 * Self.sampleRate)].allSatisfy { $0 == 0 })
        expectSame(before, after, in: 0..<(Self.sampleRate / 2))
        MediaPreview.discardListeningCopy(original)
        MediaPreview.discardListeningCopy(bleeped)
        #expect(!FileManager.default.fileExists(atPath: original.path) && !FileManager.default.fileExists(atPath: bleeped.path))
    }

    // MARK: Visualizer

    @Test("A waveform video has the shape, codecs and length asked for", .enabled(if: hasFFmpeg))
    func waveformVideo() async throws {
        let input = try makeNoise(named: "song.flac", seconds: 2, codec: ["-c:a", "flac"])
        let output = try await tools.run(.visualizer, on: [input], options: .visualizer(.standard))
        #expect(output.lastPathComponent == "song visualizer.mp4")
        #expect(try probe(output, "stream=codec_name").components(separatedBy: .newlines).sorted() == ["aac", "h264"])
        #expect(try probe(output, "stream=width") == "1920" && probe(output, "stream=height") == "1080")
        #expect(try probe(output, "stream=pix_fmt") == "yuv420p")
        #expect(abs(try duration(output) - 2) < 0.1)
        let frame = try await MediaPreview.displayFrame(of: output, at: 1)
        #expect(wavePixels(frame) > 500)
        // Away from the band, only the background.
        let corner = pixel(frame, x: 40, y: 40)
        #expect(corner.red < 40 && corner.blue < 70)
    }

    @Test("Portrait and square videos have their own canvas", .enabled(if: hasFFmpeg),
          arguments: [VisualizerShape.portrait, .square])
    func shapes(shape: VisualizerShape) async throws {
        let input = try makeNoise(named: "song.wav", seconds: 1)
        var recipe = VisualizerRecipe.standard
        recipe.shape = shape
        let output = try await tools.run(.visualizer, on: [input], options: .visualizer(recipe))
        #expect(try probe(output, "stream=width") == String(shape.width))
        #expect(try probe(output, "stream=height") == String(shape.height))
    }

    @Test("A still image is fitted inside the canvas for the length of the audio", .enabled(if: hasFFmpeg))
    func stillImage() async throws {
        let input = try makeNoise(named: "song.mp3", seconds: 2, codec: ["-c:a", "libmp3lame"])
        let picture = try writeSolid(red: 1, green: 0, blue: 0, width: 200, height: 100, as: "cover.png")
        let recipe = VisualizerRecipe(content: .stillImage, shape: .square, waveColor: .white, background: .white, picture: picture)
        let output = try await tools.run(.visualizer, on: [input], options: .visualizer(recipe))
        #expect(abs(try duration(output) - 2) < 0.2)
        let frame = try await MediaPreview.displayFrame(of: output, at: 1)
        #expect(frame.width == 1080 && frame.height == 1080)
        let centre = pixel(frame, x: 540, y: 540)
        #expect(centre.red > 200 && centre.green < 60)
        // The picture is twice as wide as tall, so the canvas shows above and below it.
        let above = pixel(frame, x: 540, y: 100)
        #expect(above.green > 200)
    }

    @Test("Still images can be any picture format, the right way up", .enabled(if: hasFFmpeg))
    func stillImageFormats() async throws {
        let input = try makeNoise(named: "song.wav", seconds: 1)
        // Red above, blue below, stored on its side with a tag saying to turn it.
        let context = try #require(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        let picture = folder.appendingPathComponent("cover.heic")
        let destination = try #require(CGImageDestinationCreateWithURL(picture as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        var recipe = VisualizerRecipe.standard
        recipe.content = .stillImage
        recipe.shape = .square
        recipe.picture = picture
        let frame = try await MediaPreview.visualizerFrame(of: input, recipe: recipe, at: 0)
        let top = pixel(frame, x: 540, y: 300)
        let bottom = pixel(frame, x: 540, y: 780)
        #expect(top.red > 200 && top.blue < 60)
        #expect(bottom.blue > 200 && bottom.red < 60)
    }

    @Test("A waveform can run over a picture", .enabled(if: hasFFmpeg))
    func waveformOverPicture() async throws {
        let input = try makeNoise(named: "song.wav", seconds: 1)
        let picture = try writeSolid(red: 0, green: 0, blue: 1, width: 400, height: 400, as: "cover.jpg")
        var recipe = VisualizerRecipe.standard
        recipe.picture = picture
        let frame = try await MediaPreview.visualizerFrame(of: input, recipe: recipe, at: 0.4)
        let centre = pixel(frame, x: 960, y: 300)
        #expect(centre.blue > 200 && centre.red < 60)
        #expect(wavePixels(frame) > 500)
    }

    @Test("A still image without a picture is refused, and so is a missing picture", .enabled(if: hasFFmpeg))
    func needsPicture() async throws {
        let input = try makeNoise(named: "song.wav", seconds: 1)
        var recipe = VisualizerRecipe.standard
        recipe.content = .stillImage
        await #expect(throws: ConversionError.needsPicture("song.wav")) {
            try await self.tools.run(.visualizer, on: [input], options: .visualizer(recipe))
        }
        recipe.picture = folder.appendingPathComponent("gone.png")
        await #expect(throws: ConversionError.unreadableInput("gone.png")) {
            try await self.tools.run(.visualizer, on: [input], options: .visualizer(recipe))
        }
    }

    @Test("Audio with no sound in it is refused, not looped forever", .enabled(if: hasFFmpeg), .timeLimit(.minutes(1)))
    func emptyAudio() async throws {
        // A valid WAV header with no samples after it.
        var header = Data("RIFF".utf8) + littleEndian(UInt32(36)) + Data("WAVEfmt ".utf8) + littleEndian(UInt32(16))
        header += littleEndian(UInt16(1)) + littleEndian(UInt16(1)) + littleEndian(UInt32(44_100))
        header += littleEndian(UInt32(88_200)) + littleEndian(UInt16(2)) + littleEndian(UInt16(16))
        header += Data("data".utf8) + littleEndian(UInt32(0))
        let input = folder.appendingPathComponent("empty.wav")
        try header.write(to: input)
        await #expect(throws: ConversionError.self) {
            try await self.tools.run(.visualizer, on: [input], options: .visualizer(.standard))
        }
    }

    @Test("Sound too brief for a video is refused", .enabled(if: hasFFmpeg))
    func tooShort() async throws {
        let input = try generate("blip.wav", ["-f", "lavfi", "-i", "anoisesrc=sample_rate=44100:duration=0.02"])
        await #expect(throws: ConversionError.tooShort("blip.wav")) {
            try await self.tools.run(.visualizer, on: [input], options: .visualizer(.standard))
        }
    }

    @Test("A preview shows the waveform at that moment, with the canvas size", .enabled(if: hasFFmpeg))
    func preview() async throws {
        let input = try makeNoise(named: "song.wav", seconds: 2)
        let frame = try await MediaPreview.visualizerFrame(of: input, recipe: .standard, at: 1)
        #expect(frame.width == 1920 && frame.height == 1080)
        #expect(wavePixels(frame) > 500)
        // The whole width is drawn; the frame where the sound stops would be cut short.
        #expect(wavePixels(frame, fromColumn: 1800) > 20)
    }

    @Test("Past the end of the audio a preview is just the canvas", .enabled(if: hasFFmpeg), .timeLimit(.minutes(1)))
    func previewPastEnd() async throws {
        let input = try makeNoise(named: "song.wav", seconds: 1)
        let frame = try await MediaPreview.visualizerFrame(of: input, recipe: .standard, at: 9)
        #expect(frame.width == 1920 && wavePixels(frame) == 0)
    }

    // MARK: Fixtures

    private struct RGB {
        let red: Int
        let green: Int
        let blue: Int
    }

    private func littleEndian<Value: FixedWidthInteger>(_ value: Value) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func recipe(_ seconds: ClosedRange<Double>, sound: BleepSound) -> BleepRecipe {
        BleepRecipe(ranges: [TrimRange(start: seconds.lowerBound, end: seconds.upperBound)], sound: sound)
    }

    private func generate(_ name: String, _ arguments: [String]) throws -> URL {
        let output = folder.appendingPathComponent(name)
        let ffmpeg = try #require(ToolLocator.url(for: .ffmpeg))
        try run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + arguments + [output.path])
        return output
    }

    /// Pink noise: never silent, and busier than any tone.
    private func makeNoise(named name: String, seconds: Int, codec: [String] = []) throws -> URL {
        try generate(name, ["-f", "lavfi", "-i", "anoisesrc=color=pink:sample_rate=\(Self.sampleRate):duration=\(seconds):amplitude=0.4"] + codec)
    }

    /// The first audio track as mono samples.
    private func samples(_ url: URL, rate: Int = sampleRate) throws -> [Float] {
        let raw = try generate(UUID().uuidString + ".f32", ["-i", url.path, "-map", "0:a:0", "-ac", "1", "-ar", String(rate), "-f", "f32le"])
        defer { try? FileManager.default.removeItem(at: raw) }
        return try Data(contentsOf: raw).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func expectSame(_ before: [Float], _ after: [Float], in range: Range<Int>) {
        let largestChange = range.reduce(Float(0)) { max($0, abs(before[$1] - after[$1])) }
        #expect(largestChange <= Self.sameSample)
    }

    private func zeroCrossings(_ samples: ArraySlice<Float>) -> Int {
        zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    }

    /// The share of the signal's energy at the bleep's pitch, by the Goertzel
    /// algorithm: near 1 for a clean tone, even with some codec noise around it.
    private func toneShare(_ samples: ArraySlice<Float>) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * 1000 / Double(Self.sampleRate))
        var previous = 0.0
        var beforeThat = 0.0
        var energy = 0.0
        for sample in samples {
            let value = Double(sample)
            (previous, beforeThat) = (value + coefficient * previous - beforeThat, previous)
            energy += value * value
        }
        let power = previous * previous + beforeThat * beforeThat - coefficient * previous * beforeThat
        return energy > 0 ? power / (energy * Double(samples.count) / 2) : 0
    }

    private func writeSolid(red: Double, green: Double, blue: Double, width: Int, height: Int, as name: String) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = folder.appendingPathComponent(name)
        let type = name.hasSuffix(".jpg") ? UTType.jpeg : UTType.png
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    /// Row 0 at the top.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> RGB {
        let data = bytes(image)
        let index = (y * image.width + x) * 4
        return RGB(red: Int(data[index]), green: Int(data[index + 1]), blue: Int(data[index + 2]))
    }

    /// How many pixels, from a column rightwards, are close to the standard waveform colour.
    private func wavePixels(_ image: CGImage, fromColumn column: Int = 0) -> Int {
        let data = bytes(image)
        return stride(from: 0, to: data.count, by: 4).filter { index in
            index / 4 % image.width >= column
                && data[index] > 200 && data[index + 1] > 90 && data[index + 1] < 180 && data[index + 2] < 110
        }.count
    }

    private func duration(_ url: URL) throws -> Double {
        try #require(Double(probe(url, "format=duration")))
    }

    private func probe(_ url: URL, _ entries: String) throws -> String {
        let ffprobe = try #require(ToolLocator.url(for: .ffprobe))
        let output = try run(ffprobe, ["-v", "error", "-show_entries", entries, "-of", "default=nw=1:nk=1", url.path])
            .replacingOccurrences(of: "N/A", with: "")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }
}
