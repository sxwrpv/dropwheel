import CoreGraphics
import DropwheelCore
import Foundation
import ImageIO
import Testing
@testable import DropwheelEngines

/// End-to-end tests for Crop, Trim and the editor previews.
final class EditToolsTests {
    private static let hasFFmpeg = ToolLocator.url(for: .ffmpeg) != nil
    private let folder: URL
    private let tools = ToolService()

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropwheel-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test("Cropping a photo keeps the chosen part", .enabled(if: hasFFmpeg))
    func cropImage() async throws {
        let input = try generate("photo.png", ["-f", "lavfi", "-i", "testsrc2=size=800x600", "-frames:v", "1"])
        let recipe = CropRecipe(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let output = try await tools.run(.crop, on: [input], options: .crop(recipe, outputWidth: nil, outputHeight: nil))
        #expect(output.lastPathComponent == "photo cropped.png")
        #expect(try pixelSize(output) == [400, 300])
    }

    @Test("A crop can be resized to exact dimensions", .enabled(if: hasFFmpeg))
    func cropToSize() async throws {
        let input = try generate("photo.jpg", ["-f", "lavfi", "-i", "testsrc2=size=800x600", "-frames:v", "1"])
        let output = try await tools.run(.crop, on: [input],
                                         options: .crop(.largest(.square, imageWidth: 800, imageHeight: 600), outputWidth: 256, outputHeight: 256))
        #expect(try pixelSize(output) == [256, 256])
    }

    @Test("Cropping a video gives even dimensions and keeps the sound", .enabled(if: hasFFmpeg))
    func cropVideo() async throws {
        let input = try makeVideo(named: "clip.mp4", seconds: 1, size: "640x360")
        let output = try await tools.run(.crop, on: [input],
                                         options: .crop(CropRecipe(x: 0, y: 0, width: 0.5, height: 0.5), outputWidth: nil, outputHeight: nil))
        #expect(try probe(output, "stream=width") == "320")
        #expect(try probe(output, "stream=height") == "180")
        #expect(try audioCodec(output) == "aac")
    }

    @Test("Trimming keeps exactly the chosen part", .enabled(if: hasFFmpeg))
    func trim() async throws {
        let input = try makeVideo(named: "talk.mov", seconds: 4)
        let output = try await tools.run(.trim, on: [input], options: .trim(TrimRange(start: 1, end: 2.5)))
        #expect(output.lastPathComponent == "talk trimmed.mov")
        #expect(abs(try duration(output) - 1.5) < 0.15)
    }

    @Test("Trims outside the recording, or of all of it, are refused", .enabled(if: hasFFmpeg),
          arguments: [TrimRange(start: 1, end: 9), TrimRange(start: 0, end: 4)])
    func badTrim(range: TrimRange) async throws {
        let input = try makeVideo(named: "short.mp4", seconds: 4)
        await #expect(throws: ConversionError.invalidTrim("short.mp4")) {
            try await self.tools.run(.trim, on: [input], options: .trim(range))
        }
    }

    @Test("Silence at both ends is removed", .enabled(if: hasFFmpeg))
    func trimSilence() async throws {
        // One second of tone with a second of silence before and after it.
        let input = try generate("padded.wav", ["-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                                                "-af", "adelay=1000:all=1,apad=pad_dur=1"])
        let output = try await tools.run(.trim, on: [input], options: .trimSilence)
        let length = try duration(output)
        #expect(length > 0.8 && length < 1.4)
    }

    @Test("Trimming silence from an all-silent file is refused instead of saving an empty copy", .enabled(if: hasFFmpeg))
    func allSilent() async throws {
        let input = try generate("hush.m4a", ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "3"])
        await #expect(throws: ConversionError.invalidTrim("hush.m4a")) {
            try await self.tools.run(.trim, on: [input], options: .trimSilence)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["hush.m4a"])
    }

    @Test("A frame asked for past the end of the picture falls back to the last one", .enabled(if: hasFFmpeg))
    func framePastEnd() async throws {
        // Two seconds of picture with four seconds of sound.
        let input = try generate("long-audio.mp4", ["-f", "lavfi", "-i", "testsrc=size=160x120:rate=24:duration=2",
                                                    "-f", "lavfi", "-i", "sine=duration=4",
                                                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"])
        let image = try await MediaPreview.frame(of: input, at: 3.5)
        #expect(image.width == 160)
    }

    @Test("The waveform has one peak per bucket, louder where the tone is", .enabled(if: hasFFmpeg))
    func waveform() async throws {
        let input = try generate("tone.wav", ["-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                                              "-af", "adelay=1000:all=1"])
        let peaks = try await MediaPreview.waveform(of: input, buckets: 30)
        #expect(peaks.count == 30)
        #expect((peaks.first ?? 1) < 0.01)
        #expect((peaks.last ?? 0) > 0.05)
    }

    @Test("A preview frame comes back at the video's size", .enabled(if: hasFFmpeg))
    func frame() async throws {
        let input = try makeVideo(named: "frame.mp4", seconds: 2, size: "320x240")
        let image = try await MediaPreview.frame(of: input, at: 1)
        #expect(image.width == 320 && image.height == 240)
    }

    @Test("A preview frame still has its pixels after the temporary file is gone", .enabled(if: hasFFmpeg))
    func framePixelsSurvive() async throws {
        // testsrc draws a white-ish background with coloured bars; an empty image would be all black.
        let input = try makeVideo(named: "bars.mp4", seconds: 1, size: "320x240")
        let image = try await MediaPreview.frame(of: input, at: 0.5)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -160, y: -120, width: 320, height: 240))
        #expect(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) > 0)
    }

    // MARK: Fixtures

    private func generate(_ name: String, _ arguments: [String]) throws -> URL {
        let output = folder.appendingPathComponent(name)
        let ffmpeg = try #require(ToolLocator.url(for: .ffmpeg))
        try run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + arguments + [output.path])
        return output
    }

    private func makeVideo(named name: String, seconds: Int, size: String = "320x240") throws -> URL {
        try generate(name, ["-f", "lavfi", "-i", "testsrc=size=\(size):rate=24:duration=\(seconds)",
                            "-f", "lavfi", "-i", "sine=frequency=330:duration=\(seconds)",
                            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"])
    }

    private func pixelSize(_ url: URL) throws -> [Int] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return [properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0]
    }

    private func duration(_ url: URL) throws -> Double {
        try #require(Double(probe(url, "format=duration")))
    }

    private func probe(_ url: URL, _ entries: String) throws -> String {
        let ffprobe = try #require(ToolLocator.url(for: .ffprobe))
        let output = try run(ffprobe, ["-v", "error", "-select_streams", "0", "-show_entries", entries,
                                       "-of", "default=nw=1:nk=1", url.path])
        return output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    private func audioCodec(_ url: URL) throws -> String {
        let ffprobe = try #require(ToolLocator.url(for: .ffprobe))
        return try run(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name",
                                 "-of", "default=nw=1:nk=1", url.path]).trimmingCharacters(in: .whitespacesAndNewlines)
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
