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

    @Test("Office and document formats are found by name",
          arguments: [("notes.textClipping", FileFormat.textClipping), ("Letter.RTFD", .rtfd), ("old.XLS", .xls),
                      ("deck.pptx", .pptx), ("readme.md", .md), ("book.epub", .epub), ("data.tsv", .tsv)])
    func officeLookup(name: String, expected: FileFormat) {
        #expect(FileFormat(fileName: name) == expected)
    }

    @Test("PDF converts to documents, slides, sheets, images and text")
    func pdfTargets() {
        #expect(ConversionMatrix.targets(for: .pdf) == [.docx, .pages, .pptx, .xlsx, .jpg, .png, .epub, .txt, .md])
    }

    @Test("Documents convert among document formats, HTML and PDF")
    func documentTargets() {
        #expect(ConversionMatrix.targets(for: .docx) == [.pages, .md, .txt, .epub, .html, .pdf])
        #expect(ConversionMatrix.targets(for: .txt) == [.docx, .pages, .md, .epub, .html, .pdf])
    }

    @Test("RTF, RTFD and text clippings are input only",
          arguments: [FileFormat.rtf, .rtfd, .textClipping])
    func richTextInputs(format: FileFormat) {
        #expect(ConversionMatrix.targets(for: format) == [.docx, .pages, .md, .txt, .epub, .html, .pdf])
        #expect(!ConversionMatrix.targets(for: .docx).contains(format))
    }

    @Test("HTML is export only")
    func htmlExportOnly() {
        #expect(ConversionMatrix.targets(for: .html).isEmpty)
    }

    @Test("Slides become PDF or images; old PPT can also become PPTX")
    func slideTargets() {
        #expect(ConversionMatrix.targets(for: .pptx) == [.pdf, .jpg, .png])
        #expect(ConversionMatrix.targets(for: .ppt) == [.pdf, .jpg, .png, .pptx])
    }

    @Test("Spreadsheets convert among sheet formats and PDF; XLS is input only")
    func sheetTargets() {
        #expect(ConversionMatrix.targets(for: .xls) == [.xlsx, .ods, .csv, .tsv, .pdf])
        #expect(ConversionMatrix.targets(for: .csv) == [.xlsx, .ods, .tsv, .pdf])
        #expect(!ConversionMatrix.targets(for: .xlsx).contains(.xls))
    }

    @Test("Subtitles still export plain text")
    func subtitleText() {
        #expect(ConversionMatrix.targets(for: .srt).contains(.txt))
    }

    @Test("RTFD and Pages are packages; other formats are plain files")
    func packages() {
        #expect(FileFormat.rtfd.isPackage)
        #expect(FileFormat.pages.isPackage)
        #expect(!FileFormat.docx.isPackage)
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

    @Test("Multi-page image output goes in a folder named after the format")
    func folderOutput() {
        let input = folder.appendingPathComponent("Report.pdf")
        let output = OutputNaming.destination(for: input, as: .png, outputIsDirectory: true, exists: { _ in false })
        #expect(output.lastPathComponent == "Report (PNG)")
    }

    @Test("Folders gain the archive extension")
    func folderArchive() {
        let input = URL(fileURLWithPath: "/tmp/in/My.Photos", isDirectory: true)
        let output = OutputNaming.destination(for: input, as: .gzip, isDirectory: true, exists: { _ in false })
        #expect(output.lastPathComponent == "My.Photos.tar.gz")
    }
}
