import CoreGraphics
import DropwheelCore
import Foundation
import ImageIO
import Testing
@testable import DropwheelEngines

/// End-to-end conversions on small generated files. Each test gets its own
/// scratch folder, removed afterwards.
final class ConversionServiceTests {
    private static let hasFFmpeg = ToolLocator.url(for: .ffmpeg) != nil
    private let folder: URL
    private let service = ConversionService()

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropwheel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Images

    @Test("PNG converts to every ImageIO format, beside the original",
          arguments: [(FileFormat.jpg, "public.jpeg"), (.heic, "public.heic"), (.tiff, "public.tiff"),
                      (.avif, "public.avif"), (.bmp, "com.microsoft.bmp")])
    func imageFormats(target: FileFormat, expectedType: String) async throws {
        let input = try makePNG(named: "photo.png")
        let output = try await service.convert(input, to: target)
        #expect(output.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(output.lastPathComponent == "photo.\(target.preferredExtension)")
        #expect(imageType(of: output) == expectedType)
    }

    @Test("PNG converts to a one-page PDF")
    func imageToPDF() async throws {
        let output = try await service.convert(try makePNG(named: "scan.png"), to: .pdf)
        let document = try #require(CGPDFDocument(output as CFURL))
        #expect(document.numberOfPages == 1)
    }

    @Test("Transparent areas become white, not black, in JPEG")
    func jpegFlattensOnWhite() async throws {
        let output = try await service.convert(try makePNG(named: "logo.png", transparent: true), to: .jpg)
        let pixel = try #require(firstPixel(of: output))
        #expect(pixel.red > 240 && pixel.green > 240 && pixel.blue > 240)
    }

    @Test("SVG renders to a PNG at least 1024 pixels on its long edge")
    func svgToPNG() async throws {
        let svg = folder.appendingPathComponent("icon.svg")
        try "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='32'><rect width='64' height='32' fill='teal'/></svg>"
            .write(to: svg, atomically: true, encoding: .utf8)
        let output = try await service.convert(svg, to: .png)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 512)
    }

    @Test("WebP needs cwebp, and says how to install it when missing")
    func webp() async throws {
        let input = try makePNG(named: "web.png")
        if ToolLocator.url(for: .cwebp) == nil {
            await #expect(throws: ConversionError.missingTool(.cwebp)) {
                try await self.service.convert(input, to: .webp)
            }
        } else {
            let output = try await service.convert(input, to: .webp)
            #expect(imageType(of: output) == "org.webmproject.webp")
        }
    }

    @Test("An existing file is never overwritten")
    func neverOverwrites() async throws {
        let input = try makePNG(named: "photo.png")
        let existing = folder.appendingPathComponent("photo.jpg")
        try Data("keep me".utf8).write(to: existing)
        let output = try await service.convert(input, to: .jpg)
        #expect(output.lastPathComponent == "photo 2.jpg")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
    }

    @Test("The placeholder rename moves files and folders, and never replaces an existing item")
    func placeholderRename() throws {
        let file = folder.appendingPathComponent("a.partial")
        try Data("new".utf8).write(to: file)
        let fileTarget = folder.appendingPathComponent("a.txt")
        #expect(ConversionService.placeholderRename(file, to: fileTarget) == 0)
        #expect(try String(contentsOf: fileTarget, encoding: .utf8) == "new")

        let pages = folder.appendingPathComponent("pages.partial", isDirectory: true)
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: pages.appendingPathComponent("p1.png"))
        let pagesTarget = folder.appendingPathComponent("Report (PNG)", isDirectory: true)
        #expect(ConversionService.placeholderRename(pages, to: pagesTarget) == 0)
        #expect(FileManager.default.fileExists(atPath: pagesTarget.appendingPathComponent("p1.png").path))

        let other = folder.appendingPathComponent("b.partial")
        try Data("other".utf8).write(to: other)
        #expect(ConversionService.placeholderRename(other, to: fileTarget) == EEXIST)
        #expect(try String(contentsOf: fileTarget, encoding: .utf8) == "new")
    }

    @Test("Conversions outside the matrix are refused")
    func unsupported() async throws {
        let input = try makePNG(named: "photo.png")
        await #expect(throws: ConversionError.unsupported(input: "photo.png", target: .mp3)) {
            try await self.service.convert(input, to: .mp3)
        }
    }

    // MARK: Audio and video

    @Test("WAV converts to every audio format", .enabled(if: hasFFmpeg),
          arguments: [FileFormat.mp3, .m4a, .flac, .ogg, .opus, .aiff, .wma])
    func audioFormats(target: FileFormat) async throws {
        let input = try generate("tone.wav", ["-f", "lavfi", "-i", "sine=frequency=440:duration=1"])
        let output = try await service.convert(input, to: target)
        #expect(try fileSize(output) > 0)
        #expect(try probe(output, "stream=codec_type") == "audio")
    }

    @Test("MP4 converts to every video format, GIF and MP3", .enabled(if: hasFFmpeg),
          arguments: [FileFormat.mov, .mkv, .webm, .avi, .wmv, .gif, .mp3])
    func videoFormats(target: FileFormat) async throws {
        let input = try makeVideo(named: "clip.mp4", seconds: 1)
        let output = try await service.convert(input, to: target)
        let firstStream = try probe(output, "stream=codec_type")
        #expect(firstStream == (target == .mp3 ? "audio" : "video"))
    }

    @Test("Progress rises to 1", .enabled(if: hasFFmpeg))
    func progressReported() async throws {
        let input = try makeVideo(named: "clip.mp4", seconds: 2)
        let recorder = ProgressRecorder()
        _ = try await service.convert(input, to: .mov) { recorder.record($0) }
        let values = recorder.values
        #expect(values.last == 1)
        #expect(values.count > 2)
    }

    @Test("Cancelling stops ffmpeg and leaves no partial file", .enabled(if: hasFFmpeg))
    func cancellation() async throws {
        let input = try makeVideo(named: "long.mp4", seconds: 30, size: "640x360")
        let service = self.service
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await service.convert(input, to: .webm) { fraction in
                if fraction > 0 && fraction < 1 { signalStarted.yield() }
            }
        }
        // Cancel once ffmpeg is demonstrably mid-encode, not after a guessed delay.
        for await _ in started { break }
        task.cancel()
        await #expect(throws: ConversionError.cancelled) { try await task.value }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(leftovers == ["long.mp4"])
    }

    // MARK: Subtitles and archives

    @Test("SRT converts to VTT")
    func subtitles() async throws {
        let input = folder.appendingPathComponent("captions.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nHi\n".write(to: input, atomically: true, encoding: .utf8)
        let output = try await service.convert(input, to: .vtt)
        #expect(try String(contentsOf: output, encoding: .utf8).hasPrefix("WEBVTT"))
    }

    @Test("Windows-1252 subtitles keep their accented letters")
    func legacyEncoding() async throws {
        let input = folder.appendingPathComponent("legacy.srt")
        let text = "1\n00:00:01,000 --> 00:00:02,000\nCaf\u{E9} cr\u{E8}me\n"
        try #require(text.data(using: .windowsCP1252)).write(to: input)
        let output = try await service.convert(input, to: .txt)
        #expect(try String(contentsOf: output, encoding: .utf8) == "Caf\u{E9} cr\u{E8}me\n")
    }

    @Test("Folders whose names look like tar options still pack",
          arguments: ["-X", "@foo"])
    func optionLikeFolderNames(name: String) async throws {
        let input = try makeFolder(named: name)
        let output = try await service.convert(input, to: .tar)
        #expect(try listArchive(output).contains("\(name)/a.txt"))
    }

    @Test("Repacking a ZIP leaves out macOS metadata folders")
    func repackSkipsMetadata() async throws {
        let root = try makeFolder(named: "Mixed")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
        try "junk".write(to: root.appendingPathComponent("__MACOSX/junk"), atomically: true, encoding: .utf8)
        // A ZIP with several top-level items and no wrapping folder, as many tools produce.
        let flat = folder.appendingPathComponent("flat.zip")
        try run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", root.path, flat.path])
        let repacked = try await service.convert(flat, to: .tar)
        let entries = try listArchive(repacked)
        #expect(entries.contains("a.txt"))
        #expect(entries.allSatisfy { !$0.contains("__MACOSX") })
    }

    @Test("A folder packs into each archive format, keeping its name inside",
          arguments: [FileFormat.zip, .tar, .gzip])
    func folderArchives(target: FileFormat) async throws {
        let input = try makeFolder(named: "Project")
        let output = try await service.convert(input, to: target)
        #expect(output.lastPathComponent == "Project.\(target.preferredExtension)")
        let entries = try listArchive(output)
        #expect(entries.contains("Project/a.txt"))
        #expect(entries.contains("Project/nested/b.txt"))
    }

    @Test("A ZIP repacks into TAR with the same contents")
    func repack() async throws {
        let zip = try await service.convert(try makeFolder(named: "Bundle"), to: .zip)
        let tar = try await service.convert(zip, to: .tar)
        #expect(tar.lastPathComponent == "Bundle.tar")
        #expect(try listArchive(tar).contains("Bundle/nested/b.txt"))
    }

    // MARK: Fixtures

    private func makePNG(named name: String, transparent: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let context = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if !transparent {
            context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeVideo(named name: String, seconds: Int, size: String = "160x120") throws -> URL {
        try generate(name, ["-f", "lavfi", "-i", "testsrc=size=\(size):rate=24:duration=\(seconds)",
                            "-f", "lavfi", "-i", "sine=frequency=330:duration=\(seconds)",
                            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"])
    }

    private func makeFolder(named name: String) throws -> URL {
        let root = folder.appendingPathComponent(name, isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: nested.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        return root
    }

    private func generate(_ name: String, _ arguments: [String]) throws -> URL {
        let output = folder.appendingPathComponent(name)
        let ffmpeg = try #require(ToolLocator.url(for: .ffmpeg))
        try run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + arguments + [output.path])
        return output
    }

    private func probe(_ url: URL, _ entries: String) throws -> String {
        let ffprobe = try #require(ToolLocator.url(for: .ffprobe))
        let output = try run(ffprobe, ["-v", "error", "-select_streams", "0", "-show_entries", entries,
                                       "-of", "default=nw=1:nk=1", url.path])
        return output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    private func listArchive(_ url: URL) throws -> [String] {
        try run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", url.path])
            .split(whereSeparator: \.isNewline)
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : String($0) }
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

    private func imageType(of url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(CGImageSourceGetType) as String?
    }

    private func fileSize(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    private func firstPixel(of url: URL) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] { lock.withLock { storage } }

    func record(_ value: Double) {
        lock.withLock { storage.append(value) }
    }
}
