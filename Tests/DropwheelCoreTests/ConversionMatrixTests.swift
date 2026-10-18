import Foundation
import Testing
@testable import DropwheelCore

@Suite("FileFormat and ConversionMatrix")
struct ConversionMatrixTests {
    @Test("Formats are found by extension, ignoring case",
          arguments: [("PNG", FileFormat.png), ("jpeg", .jpg), ("JPG", .jpg), ("tif", .tiff),
                      ("tgz", .gzip), ("m4a", .m4a), ("aif", .aiff), ("webvtt", .vtt)])
    func lookup(ext: String, expected: FileFormat) {
        #expect(FileFormat(fileExtension: ext) == expected)
    }

    @Test("Compound archive extensions are recognised from the file name")
    func compoundExtension() {
        #expect(FileFormat(fileName: "backup.tar.gz") == .gzip)
        #expect(FileFormat(fileName: "notes.txt") == .txt)
        #expect(FileFormat(fileName: "README") == nil)
    }

    @Test("Images convert to every other image format and PDF, never to themselves")
    func imageTargets() {
        let targets = ConversionMatrix.targets(for: .png)
        #expect(targets == [.jpg, .webp, .heic, .tiff, .avif, .bmp, .pdf])
    }

    @Test("SVG is input only")
    func svgInputOnly() {
        #expect(ConversionMatrix.targets(for: .svg).contains(.png))
        #expect(!ConversionMatrix.targets(for: .png).contains(.svg))
    }

    @Test("Video converts to other containers, GIF and MP3")
    func videoTargets() {
        #expect(ConversionMatrix.targets(for: .mov) == [.mp4, .mkv, .webm, .avi, .wmv, .gif, .mp3])
    }

    @Test("GIF has no audio, so it cannot become MP3")
    func gifHasNoAudio() {
        #expect(!ConversionMatrix.targets(for: .gif).contains(.mp3))
        #expect(ConversionMatrix.targets(for: .gif).contains(.mp4))
    }

    @Test("Audio converts among audio formats")
    func audioTargets() {
        #expect(ConversionMatrix.targets(for: .wav) == [.mp3, .m4a, .flac, .ogg, .opus, .aiff, .wma])
    }

    @Test("Subtitles convert to each other and plain text")
    func subtitleTargets() {
        #expect(ConversionMatrix.targets(for: .srt) == [.vtt, .txt])
        #expect(ConversionMatrix.targets(for: .vtt) == [.srt, .txt])
    }

    @Test("RAR is input only; archives repack into the others")
    func archiveTargets() {
        #expect(ConversionMatrix.targets(for: .rar) == [.zip, .tar, .gzip])
        #expect(ConversionMatrix.targets(for: .zip) == [.tar, .gzip])
    }

    @Test("Folders can be archived")
    func folderTargets() {
        #expect(ConversionMatrix.targets(for: [.folder]) == [.zip, .tar, .gzip])
    }

    @Test("A mixed selection offers only the targets every item shares, in order")
    func mixedSelection() {
        #expect(ConversionMatrix.targets(for: [.input(.png), .input(.heic)]) == [.jpg, .webp, .tiff, .avif, .bmp, .pdf])
        #expect(ConversionMatrix.targets(for: [.input(.png), .input(.mp3)]).isEmpty)
    }

    @Test("Unknown files and empty selections offer nothing")
    func unknown() {
        #expect(ConversionMatrix.targets(for: [.unknown]).isEmpty)
        #expect(ConversionMatrix.targets(for: []).isEmpty)
    }

    @Test("Targets this Mac can't write are left out")
    func unwritableTargets() {
        let noAVIF = FormatCapabilities(canRead: { _ in true }, canWrite: { $0 != .avif })
        #expect(!ConversionMatrix.targets(for: [.input(.png)], capabilities: noAVIF).contains(.avif))
    }

    @Test("Inputs this Mac can't read offer nothing")
    func unreadableInputs() {
        let noWebPInput = FormatCapabilities(canRead: { $0 != .webp }, canWrite: { _ in true })
        #expect(ConversionMatrix.targets(for: [.input(.webp)], capabilities: noWebPInput).isEmpty)
        #expect(!ConversionMatrix.targets(for: [.input(.png)], capabilities: noWebPInput).isEmpty)
    }

    @Test("The matrix counts its conversion options")
    func optionCount() {
        #expect(ConversionMatrix.optionCount > 100)
    }
}

@Suite("OutputNaming")
struct OutputNamingTests {
    private let folder = URL(fileURLWithPath: "/tmp/in", isDirectory: true)

    @Test("Output sits next to the input with the new extension")
    func sameFolder() {
        let input = folder.appendingPathComponent("photo.heic")
        let output = OutputNaming.destination(for: input, as: .jpg, exists: { _ in false })
        #expect(output.path == "/tmp/in/photo.jpg")
    }

    @Test("Existing outputs are never overwritten")
    func numbered() {
        let input = folder.appendingPathComponent("photo.heic")
        let output = OutputNaming.destination(for: input, as: .jpg, exists: { $0.lastPathComponent == "photo.jpg" })
        #expect(output.lastPathComponent == "photo 2.jpg")
    }

    @Test("Compound archive extensions are replaced whole")
    func compound() {
        let input = folder.appendingPathComponent("backup.tar.gz")
        #expect(OutputNaming.destination(for: input, as: .zip, exists: { _ in false }).lastPathComponent == "backup.zip")
    }

    @Test("Folders gain the archive extension")
    func folderArchive() {
        let input = URL(fileURLWithPath: "/tmp/in/My.Photos", isDirectory: true)
        let output = OutputNaming.destination(for: input, as: .gzip, isDirectory: true, exists: { _ in false })
        #expect(output.lastPathComponent == "My.Photos.tar.gz")
    }
}
