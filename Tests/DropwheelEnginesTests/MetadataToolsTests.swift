import AVFoundation
import CoreGraphics
import DropwheelCore
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import DropwheelEngines

/// XMP packets of shapes ImageIO refuses, as Ghostscript and others write them.
enum PDFShapes: CaseIterable, Sendable {
    case singleQuoted
    case utf16
    case bareRDF

    var packet: Data {
        let body = "<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description rdf:about='' "
            + "xmlns:dc='http://purl.org/dc/elements/1.1/' dc:format='application/pdf'><dc:creator><rdf:Seq><rdf:li>XMPAUTHOR</rdf:li>"
            + "</rdf:Seq></dc:creator></rdf:Description></rdf:RDF>"
        let wrapped = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'>\(body)</x:xmpmeta><?xpacket end='w'?>"
        return switch self {
        case .singleQuoted: Data(wrapped.utf8)
        case .utf16: wrapped.data(using: .utf16BigEndian) ?? Data()
        case .bareRDF: Data(body.utf8)
        }
    }
}

/// Edit Metadata on small generated files of every family.
final class MetadataToolsTests {
    private static let hasFFmpeg = ToolLocator.url(for: .ffmpeg) != nil
    private static let hasWebPTools = ToolLocator.url(for: .cwebp) != nil && ToolLocator.url(for: .webpmux) != nil
    private let folder: URL
    private let tools = ToolService()

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropwheel-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func draft(of url: URL) async throws -> MetadataDraft {
        MetadataDraft(report: try await MediaPreview.metadata(of: url))
    }

    private func save(_ draft: MetadataDraft, of url: URL) async throws -> URL {
        try await tools.run(.editMetadata, on: [url], options: .metadata(draft.recipe))
    }

    private func field(_ draft: MetadataDraft, _ key: String, in scope: MetadataScope = .file) throws -> MetadataField {
        try #require(draft.report.fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame && $0.scope == scope })
    }

    private func value(_ report: MetadataReport, _ key: String, in scope: MetadataScope = .file) -> String? {
        report.fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame && $0.scope == scope }?.value
    }

    // MARK: Images

    @Test("A field is changed, one removed and one added, in each image format", arguments: ["jpg", "heic", "png", "tiff", "avif"])
    func imageEdits(fileExtension: String) async throws {
        let input = try makeImage("photo.\(fileExtension)")
        let draft = try await draft(of: input)
        let edited = draft
            .setting("New Title", for: try field(draft, "dc:title"))
            .removing(try field(draft, "dc:rights"))
            .adding(key: "dc:description", to: .file)
        let description = try #require(edited.groups(matching: "")[0].fields.first { $0.key == "dc:description" })
        let output = try await save(edited.setting("A description", for: description), of: input)
        #expect(output.lastPathComponent == "photo edited.\(fileExtension)")

        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "dc:title") == "New Title")
        #expect(value(saved, "dc:rights") == nil)
        #expect(value(saved, "dc:description") == "A description")
        #expect(value(saved, "tiff:Model") == "EOS R5")
    }

    @Test("Text fields reach the older blocks too, so no app sees the old value")
    func imageBlocks() async throws {
        let input = try makeImage("photo.jpg")
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("New Title", for: try field(draft, "dc:title")).removing(try field(draft, "dc:creator")), of: input)
        let properties = try imageProperties(output)
        #expect((properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCObjectName] as? String == "New Title")
        #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist] == nil)
        #expect((properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCByline] == nil)
    }

    @Test("A list field is typed with commas and stored as a list")
    func imageList() async throws {
        let input = try makeImage("photo.png")
        let draft = try await draft(of: input)
        #expect(try field(draft, "dc:subject").value == "one, two")
        let output = try await save(draft.setting("alpha, beta,gamma", for: try field(draft, "dc:subject")), of: input)
        #expect(value(try await MediaPreview.metadata(of: output), "dc:subject") == "alpha, beta, gamma")
    }

    @Test("Fields are written the way the XMP standard defines them")
    func imageXMPForm() async throws {
        let input = try makeImage("photo.png")
        let draft = try await draft(of: input)
        let added = draft.setting("New Title", for: try field(draft, "dc:title"))
            .setting("alpha, beta", for: try field(draft, "dc:subject"))
            .adding(key: "dc:description", to: .file)
        let description = try #require(added.groups(matching: "")[0].fields.first { $0.key == "dc:description" })
        let output = try await save(added.setting("Words", for: description), of: input)
        // As stored: reading it back through ImageIO would tidy the form up.
        let packet = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        let title = try #require(packet.range(of: "<dc:title>"))
        #expect(packet[title.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<rdf:Alt>"))
        let subject = try #require(packet.range(of: "<dc:subject>"))
        #expect(packet[subject.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<rdf:Bag>"))
        let about = try #require(packet.range(of: "<dc:description>"))
        #expect(packet[about.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<rdf:Alt>"))
    }

    @Test("An author's name with a comma stays one author; a semicolon separates two")
    func imageAuthors() async throws {
        let input = try makeImage("photo.jpg")
        let draft = try await draft(of: input)
        let one = try await save(draft.setting("Smith, John", for: try field(draft, "dc:creator")), of: input)
        #expect(try authors(of: one) == ["Smith, John"])
        let two = try await save(draft.setting("Smith, John; Doe, Jo", for: try field(draft, "dc:creator")), of: input)
        #expect(try authors(of: two) == ["Smith, John", "Doe, Jo"])
        #expect(value(try await MediaPreview.metadata(of: two), "dc:creator") == "Smith, John; Doe, Jo")
    }

    private func authors(of url: URL) throws -> [String] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let tag = try #require(CGImageMetadataCopyTagWithPath(metadata, nil, "dc:creator" as CFString))
        let items = try #require(CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag])
        return items.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    @Test("A field made of structures can be removed but not retyped")
    func imageStructures() async throws {
        let packet = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" \
        xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/" xmlns:stEvt="http://ns.adobe.com/xap/1.0/sType/ResourceEvent#"><xmpMM:History><rdf:Seq>\
        <rdf:li rdf:parseType="Resource"><stEvt:action>saved</stEvt:action></rdf:li></rdf:Seq></xmpMM:History></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let metadata = try #require(CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData))
        let history = try #require(ImageMetadata.fields(of: metadata).first { $0.key == "xmpMM:History" })
        #expect(history.access == .removable)
    }

    @Test("A JPEG's embedded preview goes on any edit, and the picture doesn't change")
    func imageEmbeddedPreview() async throws {
        let input = try makeImage("photo.jpg", embedThumbnail: true)
        #expect(try jpegStartMarkers(input) == 2)
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("New", for: try field(draft, "dc:title")), of: input)
        #expect(try jpegStartMarkers(output) == 1)
        #expect(try pixels(output) == pixels(input))
    }

    @Test("Taking out the preview leaves the other blocks as they were")
    func imagePreviewIPTC() async throws {
        let input = try makeImage("photo.jpg", embedThumbnail: true)
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("New", for: try field(draft, "dc:title")), of: input)
        let resource = Data("8BIM".utf8) + Data([0x04, 0x04])
        #expect(try occurrences(of: resource, in: output) == 1)
    }

    @Test("A JPEG with no preview, or none that makes sense, comes through unchanged")
    func imagePreviewOddities() throws {
        let plain = try makeImage("plain.jpg")
        let before = try Data(contentsOf: plain)
        try JPEGPreview.remove(from: plain)
        #expect(try Data(contentsOf: plain) == before)

        let cut = folder.appendingPathComponent("cut.jpg")
        for length in stride(from: 0, to: min(before.count, 400), by: 7) {
            try before.prefix(length).write(to: cut)
            try JPEGPreview.remove(from: cut)
        }
    }

    @Test("A compressed PNG text that expands enormously is cut short")
    func pngBomb() async throws {
        let raw = try (Data(count: 40_000_000) as NSData).compressed(using: .zlib) as Data
        let input = try makePNG(chunks: [("zTXt", Data("Big\0\0".utf8) + Data([0x78, 0x9C]) + raw + Data(count: 4))])
        let draft = try await draft(of: input)
        #expect(try field(draft, "png:Big").value.utf8.count <= 100_000)
    }

    @Test("PNG text chunks ImageIO doesn't read are listed and kept")
    func pngChunksKept() async throws {
        let input = try makePNG(chunks: [
            ("tEXt", Data("parameters\0steps: 30".utf8)),
            ("tEXt", Data("Source\0Scanner".utf8)),
            ("tIME", Data([0x07, 0xE4, 1, 2, 3, 4, 5])),
        ])
        let draft = try await draft(of: input)
        #expect(try field(draft, "png:parameters").value == "steps: 30")
        #expect(try field(draft, "png:tIME").value == "2020-01-02 03:04:05")
        #expect(try field(draft, "png:parameters").access == .removable)

        let output = try await save(draft.adding(key: "dc:title", to: .file).removing(try field(draft, "png:Source")).setting("T", for: MetadataField(scope: .file, key: "dc:title", value: "")), of: input)
        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "png:parameters") == "steps: 30")
        #expect(value(saved, "png:tIME") == "2020-01-02 03:04:05")
        #expect(value(saved, "png:Source") == nil)
        #expect(value(saved, "dc:title") == "T")
        #expect(try pixels(output) == pixels(input))
    }

    @Test("Compressed and international PNG text is read too")
    func pngChunkKinds() async throws {
        let deflated = Data([0x78, 0x9C]) + (try (Data("hello".utf8) as NSData).compressed(using: .zlib) as Data) + Data([0, 0, 0, 0])
        let input = try makePNG(chunks: [
            ("zTXt", Data("Packed\0\0".utf8) + deflated),
            ("iTXt", Data("Unicode\0\0\0\0\0".utf8) + Data("Grüße".utf8)),
        ])
        let draft = try await draft(of: input)
        #expect(try field(draft, "png:Packed").value == "hello")
        #expect(try field(draft, "png:Unicode").value == "Grüße")
    }

    @Test("Text ImageIO maps to its own fields isn't listed twice, or kept after removal")
    func pngMappedChunks() async throws {
        let input = try makePNG(chunks: [("tEXt", Data("Title\0Old".utf8))])
        let draft = try await draft(of: input)
        #expect(!draft.report.fields.contains { $0.key == "png:Title" })
        let output = try await save(draft.removing(try field(draft, "dc:title")), of: input)
        #expect(value(try await MediaPreview.metadata(of: output), "dc:title") == nil)
        #expect(try !Data(contentsOf: output).contains(Data("Old".utf8)))
    }

    @Test("Removing camera data takes every PNG text chunk it didn't map")
    func pngCameraData() async throws {
        let input = try makePNG(chunks: [("tEXt", Data("parameters\0steps: 30".utf8))])
        let output = try await save(try await draft(of: input).removingCameraData(), of: input)
        #expect(value(try await MediaPreview.metadata(of: output), "png:parameters") == nil)
        #expect(try !Data(contentsOf: output).contains(Data("steps".utf8)))
    }

    @Test("A damaged PNG has no extra chunks rather than a crash", arguments: [Data(), Data(repeating: 0xFF, count: 40)])
    func pngDamaged(bytes: Data) throws {
        let url = folder.appendingPathComponent("bad.png")
        try bytes.write(to: url)
        #expect(PNGChunks.extras(of: url).isEmpty)
    }

    @Test("Camera and processing data leaves nothing behind, in each image format", arguments: ["jpg", "heic", "png", "tiff", "avif"])
    func imageCameraData(fileExtension: String) async throws {
        let input = try makeImage("photo.\(fileExtension)")
        let draft = try await draft(of: input)
        #expect(draft.hasCameraData)
        let output = try await save(draft.removingCameraData(), of: input)

        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "dc:title") == "Headline")
        #expect(!saved.fields.contains { $0.isCameraOrProcessing && $0.access != .locked })
        let properties = try imageProperties(output)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel] == nil)
    }

    @Test("JPEG and HEIC keep their compressed picture exactly", arguments: ["jpg", "heic"])
    func imageLossless(fileExtension: String) async throws {
        let input = try makeImage("photo.\(fileExtension)")
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("New", for: try field(draft, "dc:title")), of: input)
        #expect(try pixels(output) == pixels(input))
    }

    @Test("PNG and TIFF are rewritten without changing a pixel", arguments: ["png", "tiff"])
    func imagePixels(fileExtension: String) async throws {
        let input = try makeImage("photo.\(fileExtension)")
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("New", for: try field(draft, "dc:title")), of: input)
        #expect(try pixels(output) == pixels(input))
    }

    @Test("The stored orientation and resolution survive a rewrite", arguments: ["jpg", "png", "tiff"])
    func imageGeometry(fileExtension: String) async throws {
        let input = try makeImage("photo.\(fileExtension)", orientation: 6, dpi: 144)
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("New", for: try field(draft, "dc:title")), of: input)
        let properties = try imageProperties(output)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        #expect(properties[kCGImagePropertyDPIWidth] as? Double == 144)
    }

    @Test("A TIFF's compression stays")
    func imageTIFFCompression() async throws {
        let input = try makeImage("photo.tiff", tiffCompression: 5)
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("New", for: try field(draft, "dc:title")), of: input)
        let tiff = try imageProperties(output)[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFCompression] as? Int == 5)
    }

    @Test("WebP keeps its compressed picture and takes the edits", .enabled(if: hasWebPTools))
    func webp() async throws {
        let input = try makeWebP()
        let original = try webpBitstream(input)
        let draft = try await draft(of: input)
        let edited = draft.setting("New Title", for: try field(draft, "dc:title")).removingCameraData()
        let output = try await save(edited, of: input)
        #expect(try webpBitstream(output) == original)
        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "dc:title") == "New Title")
        #expect(try imageProperties(output)[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test("A WebP left with no fields has no metadata chunks", .enabled(if: hasWebPTools))
    func webpEmptied() async throws {
        let input = try makeWebP()
        let start = try await draft(of: input)
        let emptied = start.report.fields.filter { $0.access != .locked }.reduce(start) { $0.removing($1) }
        let output = try await save(emptied, of: input)
        #expect(!(try await MediaPreview.metadata(of: output)).fields.contains { $0.access != .locked })
    }

    @Test("An animated picture is refused")
    func imageFrames() async throws {
        let url = folder.appendingPathComponent("anim.tiff")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 2, nil))
        CGImageDestinationAddImage(destination, try picture(), nil)
        CGImageDestinationAddImage(destination, try picture(), nil)
        #expect(CGImageDestinationFinalize(destination))
        await #expect(throws: ConversionError.multiFrame("anim.tiff")) {
            try await MediaPreview.metadata(of: url)
        }
    }

    // MARK: PDF

    @Test("Title, author and keywords are read, and dates can only be removed")
    func pdfReport() async throws {
        let input = try makePDF(title: "Report", author: "Jo", keywords: ["one", "two"])
        let draft = try await draft(of: input)
        #expect(try field(draft, "Title").value == "Report")
        #expect(try field(draft, "Keywords").value == "one, two")
        #expect(try field(draft, "CreationDate").access == .removable)
    }

    @Test("PDF fields are changed, removed and added")
    func pdfEdits() async throws {
        let input = try makePDF(title: "Report", author: "Jo", keywords: ["one"])
        let draft = try await draft(of: input)
        let edited = draft
            .setting("Résumé 2026", for: try field(draft, "Title"))
            .removing(try field(draft, "Author"))
            .setting("alpha, beta", for: try field(draft, "Keywords"))
            .adding(key: "Subject", to: .file)
        let subject = try #require(edited.groups(matching: "")[0].fields.first { $0.key == "Subject" })
        let output = try await save(edited.setting("Finance", for: subject), of: input)
        #expect(output.lastPathComponent == "doc edited.pdf")

        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "Title") == "Résumé 2026")
        #expect(value(saved, "Author") == nil)
        #expect(value(saved, "Keywords") == "alpha, beta")
        #expect(value(saved, "Subject") == "Finance")
        #expect(PDFDocument(url: output)?.pageCount == 2)
    }

    @Test("An XMP packet follows the fields it repeats")
    func pdfXMPFollows() async throws {
        let input = try makeXMPPDF()
        let draft = try await draft(of: input)
        // Repeated fields show once.
        #expect(!draft.report.fields.contains { $0.key == "dc:title" })
        let output = try await save(draft.setting("New Title", for: try field(draft, "Title")).removing(try field(draft, "Author")), of: input)

        let packet = try #require(PDFXMP.packet(of: output))
        let text = String(decoding: packet, as: UTF8.self)
        #expect(text.contains("New Title"))
        #expect(!text.contains("XMPTITLE"))
        #expect(!text.contains("XMPAUTHOR"))
        #expect(text.contains("kept-identifier"))
        #expect(try !fileContains(output, "XMPTITLE"))
        #expect(PDFDocument(url: output)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "New Title")
    }

    @Test("Fields only in the XMP packet can be removed like any other")
    func pdfXMPOnlyField() async throws {
        let input = try makeXMPPDF()
        let draft = try await draft(of: input)
        let output = try await save(draft.removing(try field(draft, "dc:identifier")), of: input)
        let text = String(decoding: try #require(PDFXMP.packet(of: output)), as: UTF8.self)
        #expect(!text.contains("kept-identifier"))
        #expect(text.contains("XMPTITLE"))
    }

    @Test("A packet emptied of fields goes from the file")
    func pdfXMPEmptied() async throws {
        let input = try makeXMPPDF()
        let start = try await draft(of: input)
        let emptied = start.report.fields.filter { $0.access != .locked && $0.isKept }.reduce(start) { $0.removing($1) }
        let output = try await save(emptied, of: input)
        #expect(PDFXMP.packet(of: output)?.isEmpty != false)
        #expect(try !fileContains(output, "kept-identifier"))
    }

    @Test("XMP is left alone when nothing in it changes")
    func pdfXMPUntouched() async throws {
        let input = try makeXMPPDF(extraInfo: "/Keywords (old)")
        let draft = try await draft(of: input)
        // Nothing in the packet repeats Keywords.
        let output = try await save(draft.setting("new", for: try field(draft, "Keywords")), of: input)
        let text = String(decoding: try #require(PDFXMP.packet(of: output)), as: UTF8.self)
        #expect(text.contains("XMPTITLE") && text.contains("XMPAUTHOR") && text.contains("kept-identifier"))
    }

    @Test("Remove Metadata takes the XMP packet out too")
    func removeMetadataXMP() async throws {
        let input = try makeXMPPDF()
        let output = try await tools.run(.removeMetadata, on: [input])
        #expect(PDFXMP.packet(of: output)?.isEmpty != false)
        // What PDFKit compressed is left as a valid, empty stream.
        let data = try Data(contentsOf: output)
        let stream = try #require(data.range(of: Data("/Type /Metadata".utf8)).flatMap { data.range(of: Data("stream\n".utf8), in: $0.upperBound..<data.endIndex) })
        #expect(data[stream.upperBound...].starts(with: [0x78, 0x9C, 0x03, 0x00]))
        #expect(try !fileContains(output, "XMPTITLE"))
        #expect(PDFDocument(url: output)?.pageCount == 1)
    }

    @Test("Any Info field can be kept, changed or removed")
    func pdfCustomInfo() async throws {
        let input = try makeXMPPDF(extraInfo: "/Company (Acme) /Department (Sales) /Trapped /False")
        let draft = try await draft(of: input)
        let company = try field(draft, "Company")
        #expect(company.value == "Acme")
        #expect(company.isKept)
        let edited = draft.setting("X", for: try field(draft, "Title"))
            .setting("Globex", for: company)
            .removing(try field(draft, "Department"))
        let output = try await save(edited, of: input)
        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "Title") == "X")
        #expect(value(saved, "Company") == "Globex")
        #expect(value(saved, "Department") == nil)
        #expect(value(saved, "Trapped") == "False")
    }

    private static let datedInfo = "/Producer (Acrobat) /CreationDate (D:20200102030405Z) /ModDate (D:20200102030405Z)"

    @Test("What wasn't touched stays exactly as it was")
    func pdfUntouched() async throws {
        let input = try makeXMPPDF(extraInfo: Self.datedInfo)
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("New", for: try field(draft, "Title")), of: input)
        let info = PDFInfo.entries(of: output)
        #expect(info["Producer"] == .text("Acrobat"))
        #expect(info["CreationDate"] == .text("D:20200102030405Z"))
        #expect(info["ModDate"] == .text("D:20200102030405Z"))
    }

    @Test("The producer can be changed")
    func pdfProducer() async throws {
        let input = try makeXMPPDF(extraInfo: Self.datedInfo)
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("My Tool", for: try field(draft, "Producer")), of: input)
        #expect(value(try await MediaPreview.metadata(of: output), "Producer") == "My Tool")
    }

    @Test("Processing data really goes, leaving no trace of the Mac that saved the copy")
    func pdfProcessingData() async throws {
        let input = try makeXMPPDF(extraInfo: Self.datedInfo)
        let output = try await save(try await draft(of: input).removingCameraData(), of: input)
        let info = PDFInfo.entries(of: output)
        #expect(info["Producer"] == nil && info["CreationDate"] == nil && info["ModDate"] == nil)
        #expect(info["Title"] == .text("XMPTITLE"))
        #expect(try !fileContains(output, "Quartz"))
    }

    @Test("A PDF protected against changes can be read, but offers nothing to change")
    func pdfProtected() async throws {
        let input = try makePDF(title: "Report", ownerPassword: "owner")
        let draft = try await draft(of: input)
        #expect(try field(draft, "Title").value == "Report")
        #expect(try field(draft, "Title").access == .locked)
        #expect(draft.addableKeys(to: .file, format: .pdf).isEmpty)
        #expect(!draft.hasCameraData)
        #expect(await MediaPreview.copyWarning(for: input)?.contains("protected") == true)
        let recipe = MetadataRecipe(changes: [MetadataChange(scope: .file, key: "Title", value: "New", original: "Report")])
        await #expect(throws: ConversionError.passwordProtected("doc.pdf")) {
            try await self.tools.run(.editMetadata, on: [input], options: .metadata(recipe))
        }
    }

    @Test("A name that isn't UTF-8 is refused, as PDFKit would stop the app", arguments: ["/Gr#FC#DFe (x)", "/#C0#AF (x)", "/#ED#A0#80 (x)"])
    func pdfInvalidNames(info: String) async throws {
        let input = try makeXMPPDF(extraInfo: info)
        await #expect(throws: ConversionError.unreadableInput("doc.pdf")) {
            try await MediaPreview.metadata(of: input)
        }
        await #expect(throws: ConversionError.unreadableInput("doc.pdf")) {
            try await self.tools.run(.removeMetadata, on: [input])
        }
        await #expect(throws: ConversionError.unreadableInput("doc.pdf")) {
            try await self.tools.run(.compress, on: [input], options: .compress(.level(.balanced)))
        }
    }

    @Test("A name with a colon is an Info field like any other")
    func pdfColonName() async throws {
        let input = try makeXMPPDF(extraInfo: "/My#3AKey (Old) /Other#3AKey (Gone)")
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("New", for: try field(draft, "My:Key")).removing(try field(draft, "Other:Key")), of: input)
        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "My:Key") == "New")
        #expect(value(saved, "Other:Key") == nil)
    }

    @Test("Numbers and flags are shown and kept; a list is shown as not kept")
    func pdfOtherValues() async throws {
        let input = try makeXMPPDF(extraInfo: "/Rating 5 /Flag false /Tags [(a) (b)]")
        let draft = try await draft(of: input)
        #expect(try field(draft, "Rating").value == "5")
        #expect(try field(draft, "Rating").access == .locked)
        #expect(try !field(draft, "Tags").isKept)
        let output = try await save(draft.setting("New", for: try field(draft, "Title")), of: input)
        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "Rating") == "5")
        #expect(value(saved, "Flag") == "false")
        #expect(value(saved, "Tags") == nil)
    }

    @Test("Text outside plain ASCII survives the Info dictionary")
    func pdfInfoText() async throws {
        let input = try makeXMPPDF()
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("Grüße (日本語) \\ <test>", for: try field(draft, "Title")), of: input)
        #expect(value(try await MediaPreview.metadata(of: output), "Title") == "Grüße (日本語) \\ <test>")
        #expect(PDFDocument(url: output)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Grüße (日本語) \\ <test>")
    }

    @Test("A file changed twice over is still one readable PDF, and every update is linked to the last")
    func pdfUpdates() async throws {
        let input = try makeXMPPDF()
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("New", for: try field(draft, "Title")), of: input)
        let data = try Data(contentsOf: output)
        let text = String(decoding: data, as: Unicode.ASCII.self)
        let trailers = text.components(separatedBy: "trailer").dropFirst()
        #expect(trailers.count == 3)
        #expect(trailers.allSatisfy { $0.components(separatedBy: "/Prev").count <= 2 })
        let previous = try NSRegularExpression(pattern: #"/Prev (\d+)"#).matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).flatMap { Int(text[$0]) } }
        #expect(previous.count == 2)
        #expect(previous.allSatisfy { data[$0...].starts(with: Data("xref".utf8)) })
        #expect(PDFDocument(url: output)?.pageCount == 1)
        #expect(PDFXMP.packet(of: output).map { String(decoding: $0, as: UTF8.self).contains("New") } == true)
    }

    @Test("An XMP packet ImageIO can't read is shown, and doesn't reach the copy", arguments: PDFShapes.allCases)
    func pdfUnreadableXMP(shape: PDFShapes) async throws {
        let input = try makeXMPPDF(packetData: shape.packet)
        let draft = try await draft(of: input)
        let row = try field(draft, "XMP Packet")
        #expect(!row.isKept)
        let output = try await save(draft.removing(try field(draft, "Author")), of: input)
        #expect(PDFXMP.packet(of: output) == nil)
        #expect(try !fileContains(output, "XMPAUTHOR"))
    }

    @Test("A PDF/A claim is shown as not kept, and goes")
    func pdfConformance() async throws {
        let input = try makeXMPPDF(fields: #"<pdfaid:part xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">2</pdfaid:part>"#)
        let draft = try await draft(of: input)
        #expect(try !field(draft, "pdfaid:part").isKept)
        let output = try await save(draft.setting("New", for: try field(draft, "Title")), of: input)
        let packet = String(decoding: try #require(PDFXMP.packet(of: output)), as: UTF8.self)
        #expect(!packet.contains("pdfaid"))
    }

    @Test("The people who annotated a PDF are listed, and can be removed")
    func pdfAnnotationAuthors() async throws {
        let input = try makePDF(title: "Report", annotationAuthor: "Secret Reviewer")
        let draft = try await draft(of: input)
        #expect(try field(draft, "AnnotationAuthors").value == "Secret Reviewer")
        let output = try await save(draft.removing(try field(draft, "AnnotationAuthors")), of: input)
        #expect(value(try await MediaPreview.metadata(of: output), "AnnotationAuthors") == nil)
        #expect(try !fileContains(output, "Secret Reviewer"))
        #expect(PDFDocument(url: output)?.page(at: 0)?.annotations.contains { $0.contents == "A note" } == true)
    }

    @Test("Remove Metadata leaves an empty Info dictionary and no annotation authors")
    func removeMetadataEverything() async throws {
        let input = try makePDF(title: "Report", author: "Jo", annotationAuthor: "Secret Reviewer")
        let output = try await tools.run(.removeMetadata, on: [input])
        #expect(PDFInfo.entries(of: output).isEmpty)
        #expect(try !fileContains(output, "Quartz"))
        #expect(try !fileContains(output, "Secret Reviewer"))
    }

    @Test("An author's comma survives the trip into XMP")
    func pdfAuthorComma() async throws {
        let input = try makeXMPPDF()
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("Smith, John", for: try field(draft, "Author")), of: input)
        let packet = String(decoding: try #require(PDFXMP.packet(of: output)), as: UTF8.self)
        #expect(packet.contains("<rdf:li>Smith, John</rdf:li>"))
    }

    @Test("Editors are told what a copy can't carry")
    func copyWarnings() async throws {
        #expect(await MediaPreview.copyWarning(for: try makeMedia("song.mp3", tags: [:]))?.contains("ID3") == true)
        #expect(await MediaPreview.copyWarning(for: try makeMedia("song.flac", tags: [:])) == nil)
        #expect(await MediaPreview.copyWarning(for: try makePDF(title: "Report")) == nil)
    }

    @Test("A locked PDF is refused")
    func pdfLocked() async throws {
        let input = try makePDF(title: "Report", password: "secret")
        await #expect(throws: ConversionError.passwordProtected("doc.pdf")) {
            try await MediaPreview.metadata(of: input)
        }
    }

    // MARK: Media

    @Test("Tags are changed, removed and added, and the streams are untouched",
          .enabled(if: hasFFmpeg), arguments: ["mp4", "mov", "mkv", "webm", "m4a", "mp3", "flac", "wav", "aiff", "avi"])
    func mediaEdits(fileExtension: String) async throws {
        let input = try makeMedia("clip.\(fileExtension)", tags: ["title": "Old", "comment": "Remove me"])
        let draft = try await draft(of: input)
        let edited = draft
            .setting("New", for: try field(draft, "title"))
            .removing(try field(draft, "comment"))
            .adding(key: "artist", to: .file)
        let artist = try #require(edited.groups(matching: "")[0].fields.first { $0.key == "artist" })
        let output = try await save(edited.setting("Jo", for: artist), of: input)
        #expect(output.lastPathComponent == "clip edited.\(fileExtension)")

        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "title") == "New")
        #expect(value(saved, "comment") == nil)
        #expect(value(saved, "artist") == "Jo")
        #expect(try streamHash(output) == streamHash(input))
    }

    @Test("Every field the editor offers is stored", .enabled(if: hasFFmpeg), arguments: FileFormat.allCases.filter {
        ($0.family == .audio || $0.family == .video) && $0 != .gif && $0 != .ogg && $0 != .opus
    })
    func addableKeys(format: FileFormat) async throws {
        let input = try makeMedia("clip.\(format.preferredExtension)", tags: [:])
        let start = try await draft(of: input)
        let keys = MetadataRules.addableKeys(for: format, scope: .file)
        #expect(!keys.isEmpty)
        let added = keys.reduce(start) { $0.adding(key: $1, to: .file) }
        let filled = added.groups(matching: "")[0].fields.filter { keys.contains($0.key) }.reduce(added) { draft, field in
            draft.setting(Self.sampleValue(for: field.key), for: field)
        }
        // A format that can't store one of them makes the save fail.
        _ = try await save(filled, of: input)
    }

    @Test("Every track field the editor offers is stored", .enabled(if: hasFFmpeg), arguments: FileFormat.allCases.filter {
        ($0.family == .audio || $0.family == .video) && $0 != .gif && $0 != .ogg && $0 != .opus
    })
    func addableTrackKeys(format: FileFormat) async throws {
        let input = try makeMedia("clip.\(format.preferredExtension)", tags: [:])
        let start = try await draft(of: input)
        let keys = start.addableKeys(to: .track(0), format: format)
        let added = keys.reduce(start) { $0.adding(key: $1, to: .track(0)) }
        let fields = added.groups(matching: "").flatMap(\.fields).filter { $0.scope == .track(0) && keys.contains($0.key) }
        guard !fields.isEmpty else { return }
        _ = try await save(fields.reduce(added) { $0.setting($1.key == "language" ? "fra" : "Main", for: $1) }, of: input)
    }

    @Test("Ogg keeps its tags on the audio track", .enabled(if: hasFFmpeg), arguments: ["ogg", "opus"])
    func oggTags(fileExtension: String) async throws {
        let input = try makeMedia("clip.\(fileExtension)", tags: ["title": "Old", "comment": "Remove me"])
        let draft = try await draft(of: input)
        let edited = draft
            .setting("New", for: try field(draft, "title", in: .track(0)))
            .removing(try field(draft, "comment", in: .track(0)))
            .adding(key: "artist", to: .track(0))
        let artist = try #require(edited.groups(matching: "").flatMap(\.fields).first { $0.key == "artist" })
        let output = try await save(edited.setting("Jo", for: artist), of: input)
        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "title", in: .track(0)) == "New")
        #expect(value(saved, "comment", in: .track(0)) == nil)
        #expect(value(saved, "artist", in: .track(0)) == "Jo")
    }

    @Test("A track's language and name change, on the right track", .enabled(if: hasFFmpeg))
    func trackFields() async throws {
        let input = try makeMedia("clip.mkv", tags: [:])
        let draft = try await draft(of: input)
        let edited = draft.adding(key: "language", to: .track(1)).adding(key: "title", to: .track(1))
        let added = edited.groups(matching: "").flatMap(\.fields).filter { $0.scope == .track(1) && ["language", "title"].contains($0.key) }
        let output = try await save(added.reduce(edited) { $0.setting($1.key == "language" ? "fra" : "Commentary", for: $1) }, of: input)
        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "language", in: .track(1)) == "fra")
        #expect(value(saved, "title", in: .track(1)) == "Commentary")
        #expect(value(saved, "language", in: .track(0)) == nil)
    }

    @Test("A track's language changes in QuickTime files too", .enabled(if: hasFFmpeg), arguments: ["mp4", "mov"])
    func quickTimeTrackLanguage(fileExtension: String) async throws {
        let input = try makeMedia("clip.\(fileExtension)", tags: [:], streamLanguage: "eng")
        let draft = try await draft(of: input)
        #expect(try field(draft, "language", in: .track(1)).isKept)
        let output = try await save(draft.setting("fra", for: try field(draft, "language", in: .track(1))), of: input)
        #expect(value(try await MediaPreview.metadata(of: output), "language", in: .track(1)) == "fra")
    }

    @Test("The recording time goes with the camera data, from the file and its tracks", .enabled(if: hasFFmpeg), arguments: ["mp4", "mov"])
    func creationTime(fileExtension: String) async throws {
        let input = try makeMedia("clip.\(fileExtension)", tags: ["creation_time": "2024-01-02T03:04:05Z", "title": "Keep"])
        let draft = try await draft(of: input)
        #expect(try field(draft, "creation_time").isKept)
        let output = try await save(draft.removingCameraData(), of: input)
        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "creation_time") == nil)
        #expect(value(saved, "creation_time", in: .track(0)) == nil)
        #expect(value(saved, "title") == "Keep")
    }

    @Test("Chapters and a timecode outlive a copy, though their tracks aren't listed", .enabled(if: hasFFmpeg))
    func rebuiltTracks() async throws {
        let input = try makeMedia("clip.mov", tags: ["title": "Old"], chapters: ["Intro", "Outro"], timecode: "01:00:00:00")
        let draft = try await draft(of: input)
        #expect(!draft.report.groups.contains { $0.title.contains("Data") })
        let output = try await save(draft.setting("New", for: try field(draft, "title")), of: input)
        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "title", in: .chapter(1)) == "Outro")
        #expect(value(saved, "timecode", in: .track(0)) == value(draft.report, "timecode", in: .track(0)))
        #expect(value(saved, "timecode", in: .track(0)) != nil)
    }

    @Test("Chapter titles change, and chapters stay put", .enabled(if: hasFFmpeg), arguments: ["mp4", "mkv", "mp3"])
    func chapters(fileExtension: String) async throws {
        let input = try makeMedia("clip.\(fileExtension)", tags: [:], chapters: ["Intro", "Outro"])
        let draft = try await draft(of: input)
        #expect(draft.report.groups.contains { $0.title.hasPrefix("Chapter 2 · 0:01.000") })
        let output = try await save(draft.setting("Start", for: try field(draft, "title", in: .chapter(0))), of: input)
        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "title", in: .chapter(0)) == "Start")
        #expect(value(saved, "title", in: .chapter(1)) == "Outro")
    }

    @Test("Track names survive an edit of something else", .enabled(if: hasFFmpeg), arguments: ["mp4", "mov"])
    func trackNames(fileExtension: String) async throws {
        let input = try makeMedia("clip.\(fileExtension)", tags: ["title": "Old"], streamTitle: "Commentary")
        let draft = try await draft(of: input)
        let named = try field(draft, "name", in: .track(1))
        #expect(named.isKept)
        let output = try await save(draft.setting("New", for: try field(draft, "title")), of: input)
        #expect(value(try await MediaPreview.metadata(of: output), "name", in: .track(1)) == "Commentary")
    }

    @Test("A muxer's signature can be removed from a Matroska file", .enabled(if: hasFFmpeg))
    func muxerSignature() async throws {
        let input = try makeMedia("clip.mkv", tags: ["title": "Keep"], streamTags: ["_STATISTICS_WRITING_APP": "mkvmerge v81"])
        let output = try await save(try await draft(of: input).removingCameraData(), of: input)
        #expect(value(try await MediaPreview.metadata(of: output), "_STATISTICS_WRITING_APP", in: .track(0)) == nil)
    }

    @Test("Cover art survives an edit", .enabled(if: hasFFmpeg), arguments: ["mp3", "m4a", "flac"])
    func coverArt(fileExtension: String) async throws {
        let input = try makeMedia("song.\(fileExtension)", tags: ["title": "Old"], coverArt: true)
        let draft = try await draft(of: input)
        #expect(draft.report.groups.contains { $0.title.contains("Cover Art") })
        let output = try await save(draft.setting("New", for: try field(draft, "title")), of: input)
        #expect(try await MediaPreview.metadata(of: output).groups.contains { $0.title.contains("Cover Art") })
    }

    @Test("No tag of ffmpeg's own appears in the copy", .enabled(if: hasFFmpeg), arguments: ["mp4", "mp3", "flac"])
    func noEncoderAdded(fileExtension: String) async throws {
        let input = try makeMedia("clip.\(fileExtension)", tags: ["title": "Old"], stripEncoder: true)
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("New", for: try field(draft, "title")), of: input)
        #expect(value(try await MediaPreview.metadata(of: output), "encoder") == nil)
    }

    @Test("A stream's encoder tag can be removed", .enabled(if: hasFFmpeg), arguments: ["mp4", "mkv"])
    func streamEncoder(fileExtension: String) async throws {
        let input = try makeMedia("clip.\(fileExtension)", tags: [:])
        let draft = try await draft(of: input)
        let output = try await save(draft.removing(try field(draft, "encoder", in: .track(0))), of: input)
        #expect(value(try await MediaPreview.metadata(of: output), "encoder", in: .track(0)) == nil)
    }

    @Test("A field a format can't keep is flagged before saving", .enabled(if: hasFFmpeg))
    func flagsLostFields() async throws {
        // MKV keeps any name; an MP4 made from it would not, so test the MP4 muxer's own limit.
        let input = try makeMedia("clip.mov", tags: ["title": "Keep", "purchase_date": "2024"], useMetadataTags: true)
        let draft = try await draft(of: input)
        #expect(try field(draft, "purchase_date").isKept == false)
        #expect(try field(draft, "title").isKept)
        #expect(try !field(draft, "major_brand").isKept == false)
    }

    @Test("A removal that doesn't take stops the save, and says so", .enabled(if: hasFFmpeg))
    func refusesLingeringValue() async throws {
        let input = try makeMedia("clip.mov", tags: [:])
        // The muxer writes this one whatever it is told; the editor locks it.
        let recipe = MetadataRecipe(changes: [MetadataChange(scope: .track(0), key: "vendor_id", value: nil, original: "FFMP")])
        await #expect(throws: ConversionError.metadataNotRemoved(field: "Vendor Id", input: "clip.mov")) {
            try await self.tools.run(.editMetadata, on: [input], options: .metadata(recipe))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["clip.mov"])
        #expect(ConversionError.metadataNotRemoved(field: "Title", input: "a.mp4").errorDescription?.contains("removed") == true)
    }

    @Test("A value the format won't store stops the save, with no copy left", .enabled(if: hasFFmpeg))
    func refusesUnstoredValue() async throws {
        let input = try makeMedia("clip.mp4", tags: ["title": "Old"])
        let recipe = MetadataRecipe(changes: [MetadataChange(scope: .file, key: "not_an_mp4_tag", value: "x", original: nil)])
        await #expect(throws: ConversionError.metadataNotSaved(field: "Not An Mp4 Tag", input: "clip.mp4")) {
            try await self.tools.run(.editMetadata, on: [input], options: .metadata(recipe))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["clip.mp4"])
    }

    // MARK: QuickTime keys

    private static let cameraKeys = ["com.apple.quicktime.make": "Apple", "com.apple.quicktime.model": "iPhone",
                                     "com.apple.quicktime.location.ISO6709": "+53.3498-006.2603+010.000/"]

    @Test("QuickTime keys written back are read by ffprobe and by Apple's frameworks", .enabled(if: hasFFmpeg), arguments: ["mov", "mp4"])
    func quickTimeAppend(fileExtension: String) async throws {
        let input = try makeMedia("clip.\(fileExtension)", tags: [:])
        try QuickTimeFile.append(Self.cameraKeys.map { QuickTimeItem(key: $0.key, value: $0.value) }, to: input)
        let report = try await MediaPreview.metadata(of: input)
        #expect(value(report, "com.apple.quicktime.make") == "Apple")
        #expect(try await appleMetadata(input)["com.apple.quicktime.model"] == "iPhone")
        #expect(try streamHash(input).isEmpty == false)
    }

    @Test("Numbers keep their stored form through an edit of something else", .enabled(if: hasFFmpeg))
    func quickTimeTypes() async throws {
        let input = try makeMedia("clip.mov", tags: ["title": "Old"])
        let score = QuickTimeItem(key: "com.apple.quicktime.score", data: Data([0x3F, 0x60, 0, 0]), type: 23)
        let make = QuickTimeItem(key: "com.apple.quicktime.make", value: "Apple")
        try QuickTimeFile.append([score, make], to: input)
        #expect(QuickTimeFile.items(of: input) == [score, make])

        let draft = try await draft(of: input)
        let output = try await save(draft.setting("New", for: try field(draft, "title")), of: input)
        #expect(QuickTimeFile.items(of: output) == [score, make])
    }

    @Test("Keys ffmpeg stored under udta are read too", .enabled(if: hasFFmpeg))
    func quickTimeUserData() throws {
        let input = try makeMedia("clip.mov", tags: ["com.apple.quicktime.make": "Apple"], useMetadataTags: true)
        #expect(QuickTimeFile.items(of: input).contains(QuickTimeItem(key: "com.apple.quicktime.make", value: "Apple")))
    }

    @Test("Another maker's keys are flagged as not kept, and don't reach the copy", .enabled(if: hasFFmpeg))
    func foreignAtomKeys() async throws {
        let input = try makeMedia("clip.mp4", tags: ["title": "Old"])
        try QuickTimeFile.append([QuickTimeItem(key: "com.android.manufacturer", value: "SECRET-DEVICE"),
                                  QuickTimeItem(key: "com.apple.quicktime.make", value: "Apple")], to: input)
        let draft = try await draft(of: input)
        #expect(try !field(draft, "com.android.manufacturer").isKept)
        let output = try await save(draft.setting("New", for: try field(draft, "title")), of: input)
        #expect(try !fileContains(output, "SECRET-DEVICE"))
        #expect(value(try await MediaPreview.metadata(of: output), "com.apple.quicktime.make") == "Apple")
    }

    @Test("A movie with a 64-bit mdat can take QuickTime keys", .enabled(if: hasFFmpeg))
    func quickTimeLargeMedia() throws {
        let input = folder.appendingPathComponent("large.mov")
        let moov = Data([0, 0, 0, 16]) + Data("moov".utf8) + Data([0, 0, 0, 8]) + Data("free".utf8)
        let media = Data(repeating: 0xAB, count: 32)
        let header = Data([0, 0, 0, 1]) + Data("mdat".utf8) + withUnsafeBytes(of: UInt64(16 + media.count).bigEndian) { Data($0) }
        try (Data([0, 0, 0, 8]) + Data("ftyp".utf8) + header + media + moov).write(to: input)
        try QuickTimeFile.append([QuickTimeItem(key: "com.apple.quicktime.make", value: "Apple")], to: input)
        #expect(QuickTimeFile.items(of: input) == [QuickTimeItem(key: "com.apple.quicktime.make", value: "Apple")])
    }

    @Test("A truncated movie has no keys rather than a crash", arguments: [Data(), Data([0, 0, 0, 1]), Data([0, 0, 0, 1, 1, 1, 1, 1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])])
    func quickTimeDamaged(bytes: Data) throws {
        let url = folder.appendingPathComponent("bad.mov")
        try bytes.write(to: url)
        #expect(QuickTimeFile.items(of: url).isEmpty)
    }

    @Test("Camera keys in a Matroska file are ordinary tags", .enabled(if: hasFFmpeg))
    func quickTimeKeysInMatroska() async throws {
        let input = try makeMedia("clip.mkv", tags: ["com.apple.quicktime.make": "Apple"])
        let draft = try await draft(of: input)
        let output = try await save(draft.setting("Canon", for: try field(draft, "com.apple.quicktime.make")), of: input)
        #expect(value(try await MediaPreview.metadata(of: output), "com.apple.quicktime.make") == "Canon")
    }

    @Test("One QuickTime key can go while the others stay", .enabled(if: hasFFmpeg))
    func quickTimeEdits() async throws {
        let input = try makeMedia("clip.mov", tags: ["title": "Old"])
        try QuickTimeFile.append(Self.cameraKeys.map { QuickTimeItem(key: $0.key, value: $0.value) }, to: input)
        let draft = try await draft(of: input)
        #expect(try field(draft, "com.apple.quicktime.make").isKept)
        let edited = draft
            .removing(try field(draft, "com.apple.quicktime.location.ISO6709"))
            .setting("iPhone 17", for: try field(draft, "com.apple.quicktime.model"))
            .setting("New", for: try field(draft, "title"))
        let output = try await save(edited, of: input)

        let apple = try await appleMetadata(output)
        #expect(apple["com.apple.quicktime.make"] == "Apple")
        #expect(apple["com.apple.quicktime.model"] == "iPhone 17")
        #expect(apple["com.apple.quicktime.location.ISO6709"] == nil)
        #expect(value(try await MediaPreview.metadata(of: output), "title") == "New")
        #expect(try await AVURLAsset(url: output).load(.duration).seconds > 0.5)
    }

    @Test("Removing the camera data leaves no QuickTime keys", .enabled(if: hasFFmpeg))
    func quickTimeCameraData() async throws {
        let input = try makeMedia("clip.mov", tags: ["title": "Keep"])
        try QuickTimeFile.append(Self.cameraKeys.map { QuickTimeItem(key: $0.key, value: $0.value) }, to: input)
        let output = try await save(try await draft(of: input).removingCameraData(), of: input)
        let saved = try await MediaPreview.metadata(of: output)
        #expect(value(saved, "title") == "Keep")
        #expect(!saved.fields.contains { MetadataRules.isQuickTimeKey($0.key) })
        #expect(try !fileContains(output, "ISO6709"))
    }

    @Test("A file that doesn't end in moov is refused rather than damaged", .enabled(if: hasFFmpeg))
    func quickTimeFaststart() throws {
        let input = try makeMedia("clip.mov", tags: [:], faststart: true)
        let before = try Data(contentsOf: input)
        #expect(throws: ConversionError.writeFailed("The movie’s structure is unusual, so its camera fields couldn’t be kept.")) {
            try QuickTimeFile.append([QuickTimeItem(key: "com.apple.quicktime.make", value: "Apple")], to: input)
        }
        #expect(try Data(contentsOf: input) == before)
    }

    // MARK: Fixtures

    private static func sampleValue(for key: String) -> String {
        switch key {
        case "track", "disc": "3/12"
        case "date": "2024"
        default: "Sample \(key)"
        }
    }

    private func picture() throws -> CGImage {
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 48))
        return try #require(context.makeImage())
    }

    private func makeImage(_ name: String, orientation: Int? = nil, dpi: Double? = nil, tiffCompression: Int? = nil,
                           embedThumbnail: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let type = try #require(["jpg": "public.jpeg", "heic": "public.heic", "png": "public.png", "tiff": "public.tiff",
                                 "avif": "public.avif"][url.pathExtension])
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        var tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS R5",
            kCGImagePropertyTIFFArtist: "Jo Doe", kCGImagePropertyTIFFSoftware: "Lightroom",
            kCGImagePropertyTIFFCopyright: "(c) Jo",
        ]
        if let tiffCompression { tiff[kCGImagePropertyTIFFCompression] = tiffCompression }
        var properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:01:02 03:04:05",
                kCGImagePropertyExifLensModel: "RF 50mm", kCGImagePropertyExifBodySerialNumber: "12345",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 53.3, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 6.2, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCObjectName: "Headline", kCGImagePropertyIPTCKeywords: ["one", "two"],
            ],
        ]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if embedThumbnail { properties[kCGImageDestinationEmbedThumbnail] = true }
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        CGImageDestinationAddImage(destination, try picture(), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// A WebP with an XMP packet, made from the JPEG fixture's fields.
    private func makeWebP() throws -> URL {
        let png = folder.appendingPathComponent("source.png")
        let destination = try #require(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try picture(), nil)
        #expect(CGImageDestinationFinalize(destination))
        let plain = folder.appendingPathComponent("plain.webp")
        try run(try #require(ToolLocator.url(for: .cwebp)), ["-quiet", "-q", "80", png.path, "-o", plain.path])

        let source = try #require(CGImageSourceCreateWithURL(try makeImage("fields.jpg") as CFURL, nil))
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let packet = folder.appendingPathComponent("packet.xmp")
        try (try #require(CGImageMetadataCreateXMPData(metadata, nil)) as Data).write(to: packet)
        let url = folder.appendingPathComponent("photo.webp")
        try run(try #require(ToolLocator.url(for: .webpmux)), ["-set", "xmp", packet.path, plain.path, "-o", url.path])
        return url
    }

    /// The VP8 data, without the container around it.
    private func webpBitstream(_ url: URL) throws -> Data {
        let frame = folder.appendingPathComponent("\(UUID().uuidString).bin")
        try run(try #require(ToolLocator.url(for: .webpmux)), ["-strip", "xmp", url.path, "-o", frame.path])
        return try Data(contentsOf: frame)
    }

    /// A PNG with extra chunks after its header.
    private func makePNG(chunks: [(type: String, body: Data)]) throws -> URL {
        let plain = folder.appendingPathComponent("plain.png")
        let destination = try #require(CGImageDestinationCreateWithURL(plain as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try picture(), nil)
        #expect(CGImageDestinationFinalize(destination))
        let source = try Data(contentsOf: plain)
        let headerEnd = 8 + 25
        let extra = chunks.reduce(Data()) { $0 + Self.pngChunk($1.type, $1.body) }
        let url = folder.appendingPathComponent("photo.png")
        try (source.prefix(headerEnd) + extra + source.dropFirst(headerEnd)).write(to: url)
        return url
    }

    private static func pngChunk(_ type: String, _ body: Data) -> Data {
        let typed = Data(type.utf8) + body
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in typed {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        let big: (UInt32) -> Data = { value in withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        return big(UInt32(body.count)) + typed + big(crc ^ 0xFFFF_FFFF)
    }

    /// How many JPEG streams a file holds: an embedded preview is a second one.
    private func jpegStartMarkers(_ url: URL) throws -> Int {
        try occurrences(of: Data([0xFF, 0xD8, 0xFF]), in: url)
    }

    private func occurrences(of bytes: Data, in url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        var count = 0
        var position = data.startIndex
        while let found = data.range(of: bytes, in: position..<data.endIndex) {
            count += 1
            position = found.upperBound
        }
        return count
    }

    private func imageProperties(_ url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func pixels(_ url: URL) throws -> Data {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(image.dataProvider?.data as Data?)
    }

    private func makePDF(title: String, author: String? = nil, keywords: [String] = [], password: String? = nil,
                         ownerPassword: String? = nil, annotationAuthor: String? = nil) throws -> URL {
        let url = folder.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        var info: [CFString: Any] = [kCGPDFContextTitle: title]
        if let author { info[kCGPDFContextAuthor] = author }
        if !keywords.isEmpty { info[kCGPDFContextKeywords] = keywords as CFArray }
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        if let ownerPassword {
            info[kCGPDFContextOwnerPassword] = ownerPassword
            info[kCGPDFContextAllowsCopying] = false
        }
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        if let annotationAuthor {
            let document = try #require(PDFDocument(url: url))
            let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 100, height: 40), forType: .freeText, withProperties: nil)
            note.contents = "A note"
            note.userName = annotationAuthor
            try #require(document.page(at: 0)).addAnnotation(note)
            let annotated = folder.appendingPathComponent("annotated.pdf")
            #expect(document.write(to: annotated))
            _ = try FileManager.default.replaceItemAt(url, withItemAt: annotated)
        }
        return url
    }

    /// A one-page PDF with an XMP packet. Quartz can't make one that PDFKit
    /// would carry, so it is written by hand.
    private func makeXMPPDF(extraInfo: String = "", fields: String = "", packetData: Data? = nil) throws -> URL {
        let packet = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF \
        xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" \
        xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title><rdf:Alt><rdf:li xml:lang="x-default">XMPTITLE</rdf:li></rdf:Alt></dc:title>\
        <dc:creator><rdf:Seq><rdf:li>XMPAUTHOR</rdf:li></rdf:Seq></dc:creator><dc:identifier>kept-identifier</dc:identifier>\(fields)\
        </rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>
        """
        let stored = packetData ?? Data(packet.utf8)
        var body = Data("%PDF-1.5\n".utf8)
        var offsets: [Int] = []
        func object(_ number: Int, _ text: Data) {
            offsets.append(body.count)
            body += Data("\(number) 0 obj\n".utf8) + text + Data("\nendobj\n".utf8)
        }
        func object(_ number: Int, _ text: String) {
            object(number, Data(text.utf8))
        }
        object(1, "<< /Type /Catalog /Pages 2 0 R /Metadata 5 0 R >>")
        object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> >>")
        object(4, "<< /Title (XMPTITLE) /Author (XMPAUTHOR) \(extraInfo) >>")
        object(5, Data("<< /Type /Metadata /Subtype /XML /Length \(stored.count) >>\nstream\n".utf8) + stored + Data("\nendstream".utf8))
        let table = body.count
        let entries = offsets.map { String(format: "%010ld 00000 n \n", $0) }.joined()
        body += Data("xref\n0 6\n0000000000 65535 f \n\(entries)trailer\n<< /Size 6 /Root 1 0 R /Info 4 0 R >>\nstartxref\n\(table)\n%%EOF\n".utf8)
        let url = folder.appendingPathComponent("doc.pdf")
        try body.write(to: url)
        return url
    }

    /// Whether a word appears in a file, inside its compressed streams too.
    private func fileContains(_ url: URL, _ word: String) throws -> Bool {
        let data = try Data(contentsOf: url)
        if data.range(of: Data(word.utf8)) != nil { return true }
        if url.pathExtension != "pdf" { return false }
        return try PDFXMP.packet(of: url).map { String(decoding: $0, as: UTF8.self).contains(word) } ?? false
    }

    @discardableResult
    private func run(_ tool: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return data
    }

    private func ffmpeg(_ arguments: [String]) throws {
        try run(try #require(ToolLocator.url(for: .ffmpeg)), ["-hide_banner", "-nostdin", "-v", "error", "-y"] + arguments)
    }

    private func makeMedia(_ name: String, tags: [String: String], chapters: [String] = [], coverArt: Bool = false,
                           stripEncoder: Bool = false, useMetadataTags: Bool = false, faststart: Bool = false,
                           streamLanguage: String? = nil, timecode: String? = nil, streamTitle: String? = nil,
                           streamTags: [String: String] = [:]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let isAudio = FileFormat(fileName: name)?.family == .audio
        var arguments: [String] = isAudio ? [] : ["-f", "lavfi", "-i", "testsrc=d=2:s=64x64:r=10"]
        arguments += ["-f", "lavfi", "-i", "anoisesrc=d=2:a=0.2"]
        var inputs = isAudio ? 1 : 2
        var maps = (0..<inputs).flatMap { ["-map", "\($0)"] }
        if coverArt {
            let art = folder.appendingPathComponent("cover.jpg")
            try ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=32x32", "-frames:v", "1", art.path])
            arguments += ["-i", art.path]
            maps += ["-map", "\(inputs)", "-disposition:v", "attached_pic"]
            inputs += 1
        }
        if !chapters.isEmpty {
            let lines = chapters.enumerated().map { index, title in
                "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(index * 1000)\nEND=\((index + 1) * 1000)\ntitle=\(title)\n"
            }
            let file = folder.appendingPathComponent("chapters.txt")
            try (";FFMETADATA1\n" + lines.joined()).write(to: file, atomically: true, encoding: .utf8)
            arguments += ["-i", file.path]
            maps += ["-map_chapters", "\(inputs)"]
        }
        arguments += maps + Self.codecs(for: url.pathExtension, coverArt: coverArt)
        arguments += tags.flatMap { ["-metadata", "\($0.key)=\($0.value)"] }
        if stripEncoder { arguments += ["-fflags", "+bitexact", "-flags:a", "+bitexact", "-flags:v", "+bitexact"] }
        if useMetadataTags { arguments += ["-movflags", "use_metadata_tags"] }
        if faststart { arguments += ["-movflags", "+faststart"] }
        if let streamLanguage { arguments += ["-metadata:s:a:0", "language=\(streamLanguage)"] }
        if let streamTitle { arguments += ["-metadata:s:a:0", "title=\(streamTitle)"] }
        arguments += streamTags.flatMap { ["-metadata:s:v:0", "\($0.key)=\($0.value)"] }
        if let timecode { arguments += ["-timecode", timecode] }
        if url.pathExtension == "aiff" { arguments += ["-write_id3v2", "1"] }
        try ffmpeg(arguments + [url.path])
        return url
    }

    private static func codecs(for fileExtension: String, coverArt: Bool) -> [String] {
        let art = coverArt ? ["-c:v", "copy"] : []
        return switch fileExtension {
        case "mp4", "mov", "mkv": ["-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac"]
        case "webm": ["-c:v", "libvpx", "-c:a", "libopus"]
        case "avi": ["-c:v", "mpeg4", "-c:a", "libmp3lame"]
        case "wmv": ["-c:v", "wmv2", "-c:a", "wmav2"]
        case "m4a": ["-c:a", "aac"] + art
        case "mp3": ["-c:a", "libmp3lame"] + art
        case "flac": ["-c:a", "flac"] + art
        case "ogg", "opus": ["-c:a", "libopus"]
        case "wav": ["-c:a", "pcm_s16le"]
        case "aiff": ["-c:a", "pcm_s16be"]
        case "wma": ["-c:a", "wmav2"]
        default: []
        }
    }

    /// A hash of the compressed streams themselves, tags aside.
    private func streamHash(_ url: URL) throws -> String {
        let tool = try #require(ToolLocator.url(for: .ffmpeg))
        let output = try run(tool, ["-hide_banner", "-nostdin", "-v", "error", "-i", url.path, "-map", "0:a?", "-map", "0:V?",
                                    "-c", "copy", "-f", "streamhash", "-hash", "md5", "-"])
        return String(decoding: output, as: UTF8.self)
    }

    private func appleMetadata(_ url: URL) async throws -> [String: String] {
        var result: [String: String] = [:]
        for item in try await AVURLAsset(url: url).load(.metadata) {
            guard let key = item.key as? String, let value = try await item.load(.stringValue) else { continue }
            result[key] = value
        }
        return result
    }
}
