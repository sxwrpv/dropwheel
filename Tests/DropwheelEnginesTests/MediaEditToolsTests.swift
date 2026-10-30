import CoreGraphics
import DropwheelCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DropwheelEngines

/// End-to-end tests for Collage, Save Frames and Redact Video.
final class MediaEditToolsTests {
    private static let hasFFmpeg = ToolLocator.url(for: .ffmpeg) != nil
    private let folder: URL
    private let tools = ToolService()

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropwheel-media-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Collage

    @Test("Photos fill their cells in selection order")
    func collage() async throws {
        let inputs = [
            try writeSolid(red: 1, green: 0, blue: 0, width: 300, height: 200, as: "a.png"),
            try writeSolid(red: 0, green: 1, blue: 0, width: 100, height: 400, as: "b.jpg"),
            try writeSolid(red: 0, green: 0, blue: 1, width: 500, height: 500, as: "c.png"),
        ]
        let recipe = CollageRecipe(columns: nil, aspect: .free, longEdge: 600, spacing: 0.05, cornerRadius: 0, background: .white)
        let output = try await tools.run(.collage, on: inputs, options: .collage(recipe))
        #expect(output.lastPathComponent == "a collage.png")
        let image = try load(output)
        let layout = recipe.layout(count: 3)
        #expect(image.width == layout.canvasWidth && image.height == layout.canvasHeight)
        #expect(image.colorSpace?.name == CGColorSpace.sRGB, "\(String(describing: image.colorSpace))")
        let expected: [(Int, Int, Int)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255)]
        for (cell, colour) in zip(layout.cells, expected) {
            // Corners of each cell too: the photo covers the whole cell, cropped to fit.
            for point in [(cell.x + cell.width / 2, cell.y + cell.height / 2), (cell.x + 2, cell.y + 2),
                          (cell.x + cell.width - 3, cell.y + cell.height - 3)] {
                let found = pixel(image, x: point.0, y: point.1)
                #expect(abs(found.red - colour.0) < 30 && abs(found.green - colour.1) < 30 && abs(found.blue - colour.2) < 30,
                        "\(found) at \(point) in \(cell)")
            }
        }
        // The gap shows the background.
        #expect(pixel(image, x: 2, y: 2).green > 240)
    }

    @Test("A collage keeps its photos the right way up")
    func collageOrientation() throws {
        // Top half black, bottom half white.
        let photo = draw(width: 100, height: 100) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
        }
        let recipe = CollageRecipe(columns: 1, aspect: .free, longEdge: 200, spacing: 0, cornerRadius: 0, background: .white)
        let image = try PhotoRendering.collage([photo], recipe: recipe)
        #expect(pixel(image, x: 100, y: 20).red < 30)
        #expect(pixel(image, x: 100, y: 180).red > 220)
    }

    // MARK: Save Frames

    @Test("One frame is saved as a picture the size of the video", .enabled(if: hasFFmpeg))
    func singleFrame() async throws {
        let input = try makeVideo(named: "clip.mp4", seconds: 2, size: "320x240")
        let output = try await tools.run(.saveFrames, on: [input],
                                         options: .frames(FrameExport(plan: .single(seconds: 0.5), format: .png)))
        #expect(output.lastPathComponent == "clip frame at 0.5s.png")
        let image = try load(output)
        #expect(image.width == 320 && image.height == 240)
    }

    @Test("Frames every half second go into a numbered folder", .enabled(if: hasFFmpeg))
    func everyFrames() async throws {
        let input = try makeVideo(named: "clip.mov", seconds: 2)
        let output = try await tools.run(.saveFrames, on: [input],
                                         options: .frames(FrameExport(plan: .every(seconds: 0.5), format: .jpg)))
        #expect(output.lastPathComponent == "clip frames")
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(names.first == "clip 0001.jpg")
        #expect((3...5).contains(names.count))
    }

    @Test("Asking for fewer than two frames, or for too many, is refused", .enabled(if: hasFFmpeg),
          arguments: [FramePlan.every(seconds: 5), .every(seconds: 0.001), .single(seconds: 9)])
    func invalidFrames(plan: FramePlan) async throws {
        let input = try makeVideo(named: "clip.mp4", seconds: 2)
        await #expect(throws: ConversionError.self) {
            try await self.tools.run(.saveFrames, on: [input], options: .frames(FrameExport(plan: plan, format: .png)))
        }
    }

    @Test("Frames save into folders whose names contain a percent sign", .enabled(if: hasFFmpeg))
    func percentFolder() async throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Holiday 50% off"), withIntermediateDirectories: true)
        let input = try generate("Holiday 50% off/clip.mp4", ["-f", "lavfi", "-i", "testsrc=size=160x120:rate=24:duration=2",
                                                              "-c:v", "libx264", "-pix_fmt", "yuv420p"])
        let output = try await tools.run(.saveFrames, on: [input],
                                         options: .frames(FrameExport(plan: .every(seconds: 0.5), format: .png)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).count >= 3)
    }

    @Test("Frames of video with non-square pixels are saved at the shape it plays at", .enabled(if: hasFFmpeg))
    func anamorphicFrames() async throws {
        let input = try generate("dv.mp4", ["-f", "lavfi", "-i", "testsrc=size=720x480:rate=24:duration=2", "-vf", "setsar=8/9",
                                            "-c:v", "libx264", "-pix_fmt", "yuv420p"])
        let single = try await tools.run(.saveFrames, on: [input],
                                         options: .frames(FrameExport(plan: .single(seconds: 0.5), format: .png)))
        #expect(try load(single).width == 640)
        let frames = try await tools.run(.saveFrames, on: [input],
                                         options: .frames(FrameExport(plan: .every(seconds: 1), format: .jpg)))
        let first = try #require(try FileManager.default.contentsOfDirectory(atPath: frames.path).sorted().first)
        #expect(try load(frames.appendingPathComponent(first)).width == 640)
    }

    // MARK: Redact Video

    @Test("A solid box covers its area for the whole video; sound stays and tags go", .enabled(if: hasFFmpeg))
    func redactSolid() async throws {
        let input = try generate("talk.mp4", ["-f", "lavfi", "-i", "color=c=white:size=320x240:rate=24:duration=2",
                                              "-f", "lavfi", "-i", "sine=frequency=330:duration=2",
                                              "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
                                              "-metadata", "title=Secret meeting"])
        let region = RedactionRegion(rect: CropRecipe(x: 0, y: 0, width: 0.5, height: 0.5), style: .solid)
        let output = try await tools.run(.redactVideo, on: [input], options: .videoRedactions([region]))
        #expect(output.lastPathComponent == "talk redacted.mp4")
        for time in [0.1, 1.8] {
            let frame = try await MediaPreview.frame(of: output, at: time)
            #expect(pixel(frame, x: 40, y: 40).red < 30)
            #expect(pixel(frame, x: 240, y: 180).red > 220)
        }
        #expect(try audioCodec(output) == "aac")
        #expect(try probe(output, "format_tags=title").isEmpty)
    }

    @Test("Pixelate and blur flatten the detail inside the box", .enabled(if: hasFFmpeg),
          arguments: [RedactionStyle.pixelate, .blur])
    func redactSoft(style: RedactionStyle) async throws {
        let input = try generate("detail.mp4", ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24:duration=1",
                                                "-c:v", "libx264", "-pix_fmt", "yuv420p"])
        let rect = CropRecipe(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let output = try await tools.run(.redactVideo, on: [input], options: .videoRedactions([RedactionRegion(rect: rect, style: style)]))
        let before = try await MediaPreview.frame(of: input, at: 0.5)
        let after = try await MediaPreview.frame(of: output, at: 0.5)
        let inside = CGRect(x: 90, y: 70, width: 140, height: 100)
        #expect(edges(after, in: inside) < edges(before, in: inside) / 3)
    }

    @Test("Stream tags such as a camera's title don't survive", .enabled(if: hasFFmpeg))
    func streamTags() async throws {
        let input = try generate("tags.mkv", ["-f", "lavfi", "-i", "color=c=white:size=320x240:rate=24:duration=1",
                                              "-f", "lavfi", "-i", "sine=frequency=330:duration=1",
                                              "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
                                              "-metadata:s:v", "title=Camera 3 Dublin", "-metadata:s:a", "title=Office mic"])
        #expect(try probe(input, "stream_tags=title").contains("Dublin"))
        let box = RedactionRegion(rect: CropRecipe(x: 0, y: 0, width: 0.5, height: 0.5), style: .solid)
        let output = try await tools.run(.redactVideo, on: [input], options: .videoRedactions([box]))
        #expect(try probe(output, "stream_tags=title").isEmpty)
    }

    @Test("Thirty pixelated boxes finish quickly", .enabled(if: hasFFmpeg), .timeLimit(.minutes(1)))
    func manyBoxes() async throws {
        let input = try generate("crowd.mp4", ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=2",
                                               "-c:v", "libx264", "-pix_fmt", "yuv420p"])
        let boxes = (0..<30).map { index in
            RedactionRegion(rect: CropRecipe(x: Double(index % 6) / 6, y: Double(index / 6) / 5, width: 0.1, height: 0.1),
                            style: .pixelate)
        }
        let started = ContinuousClock.now
        _ = try await tools.run(.redactVideo, on: [input], options: .videoRedactions(boxes))
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    @Test("Many stacked, overlapping soft boxes still finish quickly", .enabled(if: hasFFmpeg), .timeLimit(.minutes(1)))
    func stackedBoxes() async throws {
        let input = try generate("stack.mp4", ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24:duration=1",
                                               "-c:v", "libx264", "-pix_fmt", "yuv420p"])
        let boxes = (0..<8).flatMap { layer in
            (0..<5).map { column in
                RedactionRegion(rect: CropRecipe(x: Double(column) * 0.2 + Double(layer) * 0.005, y: 0.1 + Double(layer) * 0.005,
                                                 width: 0.15, height: 0.3), style: .pixelate)
            }
        }
        let started = ContinuousClock.now
        _ = try await tools.run(.redactVideo, on: [input], options: .videoRedactions(boxes))
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    @Test("A box one pixel wide still redacts", .enabled(if: hasFFmpeg))
    func thinBox() async throws {
        let input = try makeVideo(named: "line.mp4", seconds: 1)
        let thin = RedactionRegion(rect: CropRecipe(x: 0.5, y: 0, width: 0.001, height: 1), style: .pixelate)
        _ = try await tools.run(.redactVideo, on: [input], options: .videoRedactions([thin]))
    }

    @Test("The editor's preview of a redacted frame matches the saved video", .enabled(if: hasFFmpeg))
    func previewMatchesOutput() async throws {
        let input = try generate("scene.mp4", ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24:duration=1",
                                               "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "10"])
        let boxes = [RedactionRegion(rect: CropRecipe(x: 0.1, y: 0.1, width: 0.5, height: 0.3), style: .pixelate),
                     RedactionRegion(rect: CropRecipe(x: 0.4, y: 0.3, width: 0.4, height: 0.5), style: .blur)]
        let preview = try await MediaPreview.displayFrame(of: input, at: 0.5,
                                                          filter: VideoRedaction.filter(boxes, width: 320, height: 240))
        let output = try await tools.run(.redactVideo, on: [input], options: .videoRedactions(boxes))
        let saved = try await MediaPreview.displayFrame(of: output, at: 0.5)
        #expect(meanDifference(preview, saved) < 6)
    }

    @Test("Boxes with no area are refused rather than saving an unredacted copy", .enabled(if: hasFFmpeg))
    func degenerateBoxes() async throws {
        let input = try makeVideo(named: "clip.mp4", seconds: 1)
        let flat = RedactionRegion(rect: CropRecipe(x: 0.2, y: 1, width: 0.5, height: 0), style: .solid)
        await #expect(throws: ConversionError.self) {
            try await self.tools.run(.redactVideo, on: [input], options: .videoRedactions([flat]))
        }
        let photo = try writeSolid(red: 1, green: 1, blue: 1, width: 100, height: 100, as: "id.png")
        for regions in [[flat], []] {
            await #expect(throws: ConversionError.self) {
                try await self.tools.run(.redactPhoto, on: [photo], options: .redactions(regions))
            }
        }
    }

    @Test("Redacting with no boxes is refused", .enabled(if: hasFFmpeg))
    func redactNothing() async throws {
        let input = try makeVideo(named: "clip.mp4", seconds: 1)
        await #expect(throws: ConversionError.self) {
            try await self.tools.run(.redactVideo, on: [input], options: .videoRedactions([]))
        }
    }

    // MARK: Fixtures

    private struct RGB {
        let red: Int
        let green: Int
        let blue: Int
    }

    private func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        body(context)
        return context.makeImage()!
    }

    private func writeSolid(red: Double, green: Double, blue: Double, width: Int, height: Int, as name: String) throws -> URL {
        let image = draw(width: width, height: height) { context in
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let url = folder.appendingPathComponent(name)
        let type = name.hasSuffix(".jpg") ? UTType.jpeg : UTType.png
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func load(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
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

    /// Average difference of the red channel, from 0 to 255, for pictures the same size.
    private func meanDifference(_ first: CGImage, _ second: CGImage) -> Double {
        let a = bytes(first)
        let b = bytes(second)
        guard a.count == b.count else { return 255 }
        let total = stride(from: 0, to: a.count, by: 4).reduce(0) { $0 + abs(Int(a[$1]) - Int(b[$1])) }
        return Double(total) / Double(a.count / 4)
    }

    /// Sum of brightness steps between neighbouring pixels: high for detail, low for flat areas.
    private func edges(_ image: CGImage, in rect: CGRect) -> Int {
        let data = bytes(image)
        var total = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) - 1 {
                let index = (y * image.width + x) * 4
                total += abs(Int(data[index]) - Int(data[index + 4]))
            }
        }
        return total
    }

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

    private func probe(_ url: URL, _ entries: String) throws -> String {
        let ffprobe = try #require(ToolLocator.url(for: .ffprobe))
        let output = try run(ffprobe, ["-v", "error", "-show_entries", entries, "-of", "default=nw=1:nk=1", url.path])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
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
