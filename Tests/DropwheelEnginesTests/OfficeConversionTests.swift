import AppKit
import CoreGraphics
import CoreText
import DropwheelCore
import Foundation
import Testing
@testable import DropwheelEngines

/// End-to-end tests for PDF, document, slide and spreadsheet conversions.
/// pandoc and LibreOffice tests run only when those tools are installed.
final class OfficeConversionTests {
    private static let hasPandoc = ToolLocator.url(for: .pandoc) != nil
    private static let hasLibreOffice = ToolLocator.url(for: .soffice) != nil
    private static let letterSize = CGSize(width: 612, height: 792)
    private let folder: URL
    private let service = ConversionService()

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropwheel-office-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: PDF

    @Test("A multi-page PDF renders to a folder of 300 DPI images")
    func pdfToImages() async throws {
        let input = try makePDF(named: "Report.pdf", pages: ["First page.", "Second page."])
        let output = try await service.convert(input, to: .png)
        #expect(output.lastPathComponent == "Report (PNG)")
        let pages = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(pages == ["Report 01.png", "Report 02.png"])
        let size = try pixelSize(of: output.appendingPathComponent("Report 01.png"))
        #expect(size.width == 2550 && size.height == 3300)
    }

    @Test("A one-page PDF renders to a single image file")
    func singlePagePDF() async throws {
        let output = try await service.convert(try makePDF(named: "Note.pdf", pages: ["Only page."]), to: .jpg)
        #expect(output.lastPathComponent == "Note.jpg")
    }

    @Test("A sideways page renders landscape")
    func rotatedPage() async throws {
        let input = try makePDF(named: "Wide.pdf", pages: ["Turned."], rotation: 90)
        let size = try pixelSize(of: try await service.convert(input, to: .png))
        #expect(size.width == 3300 && size.height == 2550)
    }

    @Test("PDF text is extracted page by page")
    func pdfToText() async throws {
        let input = try makePDF(named: "Letter.pdf", pages: ["Hello from page one.", "Goodbye from page two."])
        let text = try String(contentsOf: try await service.convert(input, to: .txt), encoding: .utf8)
        #expect(text.contains("Hello from page one."))
        #expect(text.contains("Goodbye from page two."))
    }

    @Test("A PDF without a text layer says so instead of writing an empty file")
    func scannedPDF() async throws {
        let input = try makePDF(named: "Scan.pdf", pages: [""], drawText: false)
        await #expect(throws: ConversionError.noText("Scan.pdf")) {
            try await self.service.convert(input, to: .txt)
        }
    }

    @Test("PDF converts to Markdown and DOCX through pandoc", .enabled(if: hasPandoc))
    func pdfToDocuments() async throws {
        let input = try makePDF(named: "Essay.pdf", pages: ["The opening paragraph of the essay."])
        let markdown = try String(contentsOf: try await service.convert(input, to: .md), encoding: .utf8)
        #expect(markdown.contains("The opening paragraph of the essay."))
        let word = try await service.convert(input, to: .docx)
        #expect(try zipEntries(word).contains("word/document.xml"))
    }

    @Test("PDF converts to PPTX and XLSX through LibreOffice", .enabled(if: hasLibreOffice))
    func pdfToOffice() async throws {
        let input = try makePDF(named: "Figures.pdf", pages: ["Item   Qty\nApples   3"])
        #expect(try zipEntries(try await service.convert(input, to: .pptx)).contains("ppt/presentation.xml"))
        #expect(try zipEntries(try await service.convert(input, to: .xlsx)).contains("xl/workbook.xml"))
    }

    // MARK: Documents

    @Test("Markdown converts to each pandoc format", .enabled(if: hasPandoc),
          arguments: [(FileFormat.docx, "word/document.xml"), (.epub, "META-INF/container.xml")])
    func markdownToPackages(target: FileFormat, entry: String) async throws {
        let input = try write("notes.md", "# Title\n\nSome *emphasis* here.\n")
        #expect(try zipEntries(try await service.convert(input, to: target)).contains(entry))
    }

    @Test("Markdown converts to HTML and plain text", .enabled(if: hasPandoc))
    func markdownToText() async throws {
        let input = try write("notes.md", "# Title\n\nSome *emphasis* here.\n")
        let html = try String(contentsOf: try await service.convert(input, to: .html), encoding: .utf8)
        #expect(html.contains("<em>emphasis</em>"))
        let text = try String(contentsOf: try await service.convert(input, to: .txt), encoding: .utf8)
        #expect(text.contains("Some emphasis here."))
    }

    @Test("Plain text keeps its asterisks when it becomes Markdown", .enabled(if: hasPandoc))
    func textToMarkdown() async throws {
        let input = try write("raw.txt", "2 * 3 * 4 = 24\nsecond line\n")
        let markdown = try String(contentsOf: try await service.convert(input, to: .md), encoding: .utf8)
        #expect(!markdown.contains("<em>"))
        #expect(markdown.contains("24"))
    }

    @Test("RTF, RTFD and text clippings convert to Markdown", .enabled(if: hasPandoc),
          arguments: ["rtf", "rtfd", "textClipping"])
    func richTextInputs(kind: String) async throws {
        let input = try makeRichText(kind: kind, text: "Rich text body")
        let markdown = try String(contentsOf: try await service.convert(input, to: .md), encoding: .utf8)
        #expect(markdown.contains("Rich text body"))
    }

    @Test("DOCX converts to PDF through LibreOffice", .enabled(if: hasPandoc && hasLibreOffice))
    func documentToPDF() async throws {
        let word = try await service.convert(try write("memo.md", "Memo text.\n"), to: .docx)
        let pdf = try await service.convert(word, to: .pdf)
        #expect(CGPDFDocument(pdf as CFURL)?.numberOfPages == 1)
    }

    // MARK: Spreadsheets and slides

    @Test("CSV becomes TSV without LibreOffice")
    func csvToTSV() async throws {
        let input = try write("data.csv", "name,note\n\"Smith, J\",ok\n")
        let tsv = try String(contentsOf: try await service.convert(input, to: .tsv), encoding: .utf8)
        #expect(tsv == "name\tnote\nSmith, J\tok\n")
    }

    @Test("CSV round-trips through XLSX", .enabled(if: hasLibreOffice))
    func csvThroughWorkbook() async throws {
        let input = try write("sheet.csv", "fruit,count\napple,3\npear,10\n")
        let workbook = try await service.convert(input, to: .xlsx)
        let back = try String(contentsOf: try await service.convert(workbook, to: .csv), encoding: .utf8)
        #expect(CSV.parse(back, separator: ",") == [["fruit", "count"], ["apple", "3"], ["pear", "10"]])
    }

    @Test("Slides convert to PDF and to one image per slide", .enabled(if: hasLibreOffice))
    func slides() async throws {
        let deck = try await service.convert(try makePDF(named: "Deck.pdf", pages: ["Slide one", "Slide two"]), to: .pptx)
        let pdf = try await service.convert(deck, to: .pdf)
        #expect(CGPDFDocument(pdf as CFURL)?.numberOfPages == 2)
        let images = try await service.convert(deck, to: .png)
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.path).count == 2)
    }

    // MARK: Safety

    @Test("A password-protected PDF says so for images and for text", arguments: [FileFormat.png, .txt])
    func lockedPDF(target: FileFormat) async throws {
        let input = try makePDF(named: "Locked.pdf", pages: ["Secret."], password: "pw")
        await #expect(throws: ConversionError.passwordProtected("Locked.pdf")) {
            try await self.service.convert(input, to: target)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Locked.pdf"])
    }

    @Test("Spreadsheet import keeps formulas and date-like text as plain text", .enabled(if: hasLibreOffice))
    func noFormulaInjection() async throws {
        let input = try write("cells.csv", "a,b\n=1+1,1/2\n")
        let workbook = try await service.convert(input, to: .xlsx)
        let back = try String(contentsOf: try await service.convert(workbook, to: .csv), encoding: .utf8)
        #expect(CSV.parse(back, separator: ",") == [["a", "b"], ["=1+1", "1/2"]])
    }

    @Test("A Latin-1 CSV keeps its accents through LibreOffice", .enabled(if: hasLibreOffice))
    func legacyCSV() async throws {
        let input = folder.appendingPathComponent("latin.csv")
        try #require("city\nZ\u{FC}rich\n".data(using: .isoLatin1)).write(to: input)
        let workbook = try await service.convert(input, to: .xlsx)
        let back = try String(contentsOf: try await service.convert(workbook, to: .csv), encoding: .utf8)
        #expect(back.contains("Z\u{FC}rich"))
    }

    @Test("LibreOffice never fetches images a document links to", .enabled(if: hasLibreOffice))
    func libreOfficeStaysOffline() async throws {
        let listener = try LoopbackListener()
        let input = try makeDocxLinking(to: "http://127.0.0.1:\(listener.port)/tracker.png")
        _ = try await service.convert(input, to: .pdf)
        #expect(listener.connectionCount == 0)
    }

    // MARK: Fixtures

    /// A minimal DOCX whose only picture is an external link.
    private func makeDocxLinking(to address: String) throws -> URL {
        let root = folder.appendingPathComponent("docx-src", isDirectory: true)
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """,
            "word/_rels/document.xml.rels": """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="\(address)" TargetMode="External"/></Relationships>
            """,
            "word/document.xml": """
            <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body><w:p><w:r><w:t>Linked picture:</w:t></w:r></w:p><w:p><w:r><w:drawing><wp:inline><wp:extent cx="952500" cy="952500"/><wp:docPr id="1" name="Picture"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="tracker.png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:link="rId9"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="952500" cy="952500"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p></w:body></w:document>
            """,
        ]
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let docx = folder.appendingPathComponent("linked.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-r", docx.path, "[Content_Types].xml", "_rels", "word"]
        try zip.run()
        zip.waitUntilExit()
        try #require(zip.terminationStatus == 0)
        return docx
    }

    private func makePDF(named name: String, pages: [String], drawText: Bool = true, rotation: Int = 0,
                         password: String? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(origin: .zero, size: Self.letterSize)
        let security: [CFString: Any]? = password.map {
            [kCGPDFContextUserPassword: $0, kCGPDFContextOwnerPassword: $0 + "-owner"]
        }
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, security as CFDictionary?))
        let pageInfo: [CFString: Any] = rotation == 0 ? [:] : ["Rotate" as CFString: rotation]
        for text in pages {
            context.beginPDFPage(pageInfo as CFDictionary)
            if drawText {
                let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
                let string = NSAttributedString(string: text, attributes: [.font: font])
                let framesetter = CTFramesetterCreateWithAttributedString(string)
                let path = CGPath(rect: box.insetBy(dx: 72, dy: 72), transform: nil)
                CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
            } else {
                context.setFillColor(CGColor(gray: 0.5, alpha: 1))
                context.fill(box.insetBy(dx: 100, dy: 100))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func makeRichText(kind: String, text: String) throws -> URL {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let range = NSRange(location: 0, length: attributed.length)
        switch kind {
        case "rtf":
            let url = folder.appendingPathComponent("doc.rtf")
            try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
            return url
        case "rtfd":
            let url = folder.appendingPathComponent("doc.rtfd")
            let wrapper = try attributed.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
            return url
        default:
            let url = folder.appendingPathComponent("snippet.textClipping")
            let plist: [String: Any] = ["UTI-Data": ["public.utf8-plain-text": text]]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
            return url
        }
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func pixelSize(of url: URL) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    private func zipEntries(_ url: URL) throws -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", url.path]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// Counts TCP connections to a port on 127.0.0.1, to prove nothing calls out.
private final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let socketDescriptor: Int32
    private let lock = NSLock()
    private var connections = 0

    var connectionCount: Int { lock.withLock { connections } }

    init() throws {
        // Set up with a local descriptor: closures can't capture self until
        // every stored property has a value.
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0 && listen(descriptor, 8) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        socketDescriptor = descriptor
        DispatchQueue.global().async { [weak self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                self?.lock.withLock { self?.connections += 1 }
                close(client)
            }
        }
    }

    deinit {
        close(socketDescriptor)
    }
}
