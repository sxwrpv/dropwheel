import CoreGraphics
import DropwheelCore
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import DropwheelEngines

/// End-to-end tests for the file tools on small generated files.
final class ToolServiceTests {
    private static let hasFFmpeg = ToolLocator.url(for: .ffmpeg) != nil
    private let folder: URL
    private let tools = ToolService()

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropwheel-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Images

    @Test("Compressing a photo makes a smaller copy beside it", .enabled(if: hasFFmpeg))
    func compressPhoto() async throws {
        let input = try generate("photo.jpg", ["-f", "lavfi", "-i", "testsrc2=size=1600x1200", "-frames:v", "1", "-q:v", "1"])
        let output = try await tools.run(.compress, on: [input], options: .compress(.level(.balanced)))
        #expect(output.lastPathComponent == "photo compressed.jpg")
        #expect(try size(output) < size(input))
    }

    @Test("A target size is met", .enabled(if: hasFFmpeg))
    func compressToTarget() async throws {
        let input = try generate("photo.jpg", ["-f", "lavfi", "-i", "testsrc2=size=1600x1200", "-frames:v", "1", "-q:v", "1"])
        let target = try size(input) / 4
        let output = try await tools.run(.compress, on: [input], options: .compress(.targetBytes(target)))
        #expect(try size(output) <= target)
    }

    @Test("PNG compresses by resizing", .enabled(if: hasFFmpeg))
    func compressPNG() async throws {
        let input = try generate("diagram.png", ["-f", "lavfi", "-i", "testsrc2=size=1200x900", "-frames:v", "1"])
        let output = try await tools.run(.compress, on: [input], options: .compress(.level(.strong)))
        #expect(try pixelWidth(output) == 600)
    }

    @Test("An impossible target says so and leaves nothing behind", .enabled(if: hasFFmpeg))
    func impossibleTarget() async throws {
        let input = try generate("photo.jpg", ["-f", "lavfi", "-i", "testsrc2=size=800x600", "-frames:v", "1"])
        await #expect(throws: ConversionError.targetTooSmall("photo.jpg")) {
            try await self.tools.run(.compress, on: [input], options: .compress(.targetBytes(10)))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["photo.jpg"])
    }

    @Test("Removing metadata drops camera and location data but keeps orientation")
    func stripPhotoMetadata() async throws {
        let input = try makeTaggedJPEG(named: "trip.jpg")
        let output = try await tools.run(.removeMetadata, on: [input])
        let properties = try imageProperties(output)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifUserComment] == nil)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
    }

    @Test("Removing metadata from PNG and HEIC drops camera, location and XMP data",
          arguments: [("shot.png", "public.png"), ("shot.heic", "public.heic")])
    func stripOtherFormats(name: String, type: String) async throws {
        let input = try makeTaggedImage(named: name, type: type)
        let output = try await tools.run(.removeMetadata, on: [input])
        let properties = try imageProperties(output)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifUserComment] == nil)
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        #expect(tiff[kCGImagePropertyTIFFArtist] == nil)
    }

    @Test("A multi-page image is refused rather than cut to its first page")
    func multiFrame() async throws {
        let input = folder.appendingPathComponent("pages.tiff")
        let destination = try #require(CGImageDestinationCreateWithURL(input as CFURL, "public.tiff" as CFString, 2, nil))
        let image = try #require(makeImage())
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        await #expect(throws: ConversionError.multiFrame("pages.tiff")) {
            try await self.tools.run(.compress, on: [input], options: .compress(.level(.strong)))
        }
    }

    @Test("A target no smaller than the file is refused before any work")
    func targetNotSmaller() async throws {
        let input = try makeTaggedJPEG(named: "small.jpg")
        await #expect(throws: ConversionError.notSmaller("small.jpg")) {
            try await self.tools.run(.compress, on: [input], options: .compress(.targetBytes(10_000_000)))
        }
    }

    @Test("Several images become one PDF, a page each, in order", .enabled(if: hasFFmpeg))
    func createPDF() async throws {
        let first = try generate("a.png", ["-f", "lavfi", "-i", "testsrc2=size=300x200", "-frames:v", "1"])
        let second = try generate("b.jpg", ["-f", "lavfi", "-i", "testsrc2=size=200x300", "-frames:v", "1"])
        let output = try await tools.run(.createPDF, on: [first, second])
        #expect(output.lastPathComponent == "a combined.pdf")
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).width == 300)
    }

    // MARK: PDFs

    @Test("PDFs merge in selection order")
    func mergePDFs() async throws {
        let one = try makePDF(named: "one.pdf", pages: 1)
        let two = try makePDF(named: "two.pdf", pages: 2)
        let output = try await tools.run(.mergePDFs, on: [one, two])
        #expect(output.lastPathComponent == "one merged.pdf")
        #expect(PDFDocument(url: output)?.pageCount == 3)
    }

    @Test("Removing PDF metadata clears the author and title")
    func stripPDFMetadata() async throws {
        let input = try makePDF(named: "report.pdf", pages: 1, author: "Jane Doe", title: "Secret plan")
        let output = try await tools.run(.removeMetadata, on: [input])
        let attributes = PDFDocument(url: output)?.documentAttributes ?? [:]
        #expect(attributes[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(attributes[PDFDocumentAttribute.titleAttribute] == nil)
    }

    // MARK: Audio and video

    @Test("Lossless audio compresses to M4A", .enabled(if: hasFFmpeg))
    func compressAudio() async throws {
        let input = try generate("tone.wav", ["-f", "lavfi", "-i", "sine=frequency=440:duration=3"])
        let output = try await tools.run(.compress, on: [input], options: .compress(.level(.balanced)))
        #expect(output.lastPathComponent == "tone compressed.m4a")
        #expect(try size(output) < size(input))
    }

    @Test("Normalizing brings a quiet recording to the target loudness", .enabled(if: hasFFmpeg))
    func normalize() async throws {
        let input = try generate("quiet.wav", ["-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-af", "volume=0.05"])
        let output = try await tools.run(.normalizeVolume, on: [input], options: .loudness(.podcast))
        let loudness = try measuredLoudness(of: output)
        #expect(abs(loudness - -16) < 2)
    }

    @Test("Stereo audio becomes mono", .enabled(if: hasFFmpeg))
    func mono() async throws {
        let input = try generate("stereo.wav", ["-f", "lavfi", "-i", "sine=duration=2", "-ac", "2"])
        let output = try await tools.run(.audioChannels, on: [input], options: .channels(.mono))
        #expect(output.lastPathComponent == "stereo mono.wav")
        #expect(try probe(output, "stream=channels") == "1")
    }

    @Test("Doubling the speed halves the length", .enabled(if: hasFFmpeg))
    func speed() async throws {
        let input = try makeVideo(named: "clip.mp4", seconds: 4)
        let output = try await tools.run(.changeSpeed, on: [input], options: .speed(2))
        #expect(output.lastPathComponent == "clip 2x.mp4")
        #expect(abs(try duration(of: output) - 2) < 0.3)
    }

    @Test("Splitting into equal parts writes a folder of clips", .enabled(if: hasFFmpeg))
    func split() async throws {
        let input = try makeVideo(named: "talk.mp4", seconds: 4)
        let output = try await tools.run(.splitVideo, on: [input], options: .split(.equalParts(2)))
        #expect(output.lastPathComponent == "talk parts")
        let parts = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(parts == ["talk 01.mp4", "talk 02.mp4"])
        #expect(abs(try duration(of: output.appendingPathComponent("talk 02.mp4")) - 2) < 0.3)
    }

    @Test("Joining clips keeps the first clip's size and adds silence where audio is missing", .enabled(if: hasFFmpeg))
    func join() async throws {
        let first = try makeVideo(named: "first.mov", seconds: 2, size: "320x240")
        let silent = try generate("silent.mp4", ["-f", "lavfi", "-i", "testsrc=size=160x160:rate=24:duration=1",
                                                 "-c:v", "libx264", "-pix_fmt", "yuv420p"])
        let output = try await tools.run(.joinVideos, on: [first, silent])
        #expect(output.lastPathComponent == "first joined.mp4")
        #expect(try probe(output, "stream=width") == "320")
        #expect(abs(try duration(of: output) - 3) < 0.3)
        #expect(try probeAudioCodec(output) == "aac")
    }

    @Test("A portrait clip first makes a portrait join", .enabled(if: hasFFmpeg))
    func joinRotated() async throws {
        let plain = try makeVideo(named: "plain.mp4", seconds: 1, size: "320x240")
        let rotated = folder.appendingPathComponent("portrait.mp4")
        let ffmpeg = try #require(ToolLocator.url(for: .ffmpeg))
        try run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-display_rotation", "90", "-i", plain.path,
                         "-c", "copy", rotated.path])
        let output = try await tools.run(.joinVideos, on: [rotated, plain])
        #expect(try probe(output, "stream=width") == "240")
        #expect(try probe(output, "stream=height") == "320")
    }

    @Test("Removing metadata keeps MKV attachments such as fonts", .enabled(if: hasFFmpeg))
    func stripKeepsAttachments() async throws {
        let font = folder.appendingPathComponent("font.ttf")
        try Data(repeating: 7, count: 512).write(to: font)
        let input = try generate("subbed.mkv", ["-f", "lavfi", "-i", "testsrc=size=160x120:duration=1",
                                                "-attach", font.path, "-metadata:s:t", "mimetype=application/x-truetype-font",
                                                "-metadata", "title=Private title"])
        let output = try await tools.run(.removeMetadata, on: [input])
        #expect(try probe(output, "format_tags=title").isEmpty)
        let streams = try run(try #require(ToolLocator.url(for: .ffprobe)),
                              ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", output.path])
        #expect(streams.contains("attachment"))
    }

    @Test("Removing media metadata drops the title", .enabled(if: hasFFmpeg))
    func stripMediaMetadata() async throws {
        let input = try generate("song.m4a", ["-f", "lavfi", "-i", "sine=duration=1", "-metadata", "title=Private title"])
        let output = try await tools.run(.removeMetadata, on: [input])
        #expect(try probe(output, "format_tags=title").isEmpty)
    }

    // MARK: Refusals

    @Test("Tools that don't fit the selection are refused")
    func unavailable() async throws {
        let document = folder.appendingPathComponent("notes.docx")
        try Data("x".utf8).write(to: document)
        await #expect(throws: ConversionError.toolUnavailable(tool: "Compress", input: "notes.docx")) {
            try await self.tools.run(.compress, on: [document])
        }
        let one = try makePDF(named: "solo.pdf", pages: 1)
        await #expect(throws: ConversionError.toolUnavailable(tool: "Merge PDFs", input: "solo.pdf")) {
            try await self.tools.run(.mergePDFs, on: [one])
        }
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

    private func makeImage() -> CGImage? {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return context?.makeImage()
    }

    private func makeTaggedJPEG(named name: String) throws -> URL {
        try makeTaggedImage(named: name, type: "public.jpeg")
    }

    private func makeTaggedImage(named name: String, type: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let image = try #require(makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 53.35, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "taken at home"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane Doe"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        // The fixture really carries the data the tool should remove.
        #expect(try imageProperties(url)[kCGImagePropertyGPSDictionary] != nil)
        return url
    }

    private func makePDF(named name: String, pages: Int, author: String? = nil, title: String? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        var info: [CFString: Any] = [:]
        if let author { info[kCGPDFContextAuthor] = author }
        if let title { info[kCGPDFContextTitle] = title }
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.fill(CGRect(x: 20, y: 20, width: 50, height: 50))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func size(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    private func imageProperties(_ url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func pixelWidth(_ url: URL) throws -> Int {
        try imageProperties(url)[kCGImagePropertyPixelWidth] as? Int ?? 0
    }

    private func duration(of url: URL) throws -> Double {
        try #require(Double(probe(url, "format=duration")))
    }

    private func probe(_ url: URL, _ entries: String) throws -> String {
        let ffprobe = try #require(ToolLocator.url(for: .ffprobe))
        let output = try run(ffprobe, ["-v", "error", "-select_streams", "0", "-show_entries", entries,
                                       "-of", "default=nw=1:nk=1", url.path])
        return output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    private func probeAudioCodec(_ url: URL) throws -> String {
        let ffprobe = try #require(ToolLocator.url(for: .ffprobe))
        let output = try run(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name",
                                       "-of", "default=nw=1:nk=1", url.path])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Integrated loudness in LUFS, measured with the same loudnorm filter.
    private func measuredLoudness(of url: URL) throws -> Double {
        let ffmpeg = try #require(ToolLocator.url(for: .ffmpeg))
        let report = try run(ffmpeg, ["-hide_banner", "-nostdin", "-i", url.path,
                                      "-af", MediaToolPlans.loudnessMeasurementFilter(target: .podcast),
                                      "-f", "null", "-"], captureStderr: true)
        return try #require(LoudnessMeasurement.parse(report).flatMap { Double($0.integrated) })
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String], captureStderr: Bool = false) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        if captureStderr {
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
        } else {
            process.standardOutput = pipe
        }
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }
}
