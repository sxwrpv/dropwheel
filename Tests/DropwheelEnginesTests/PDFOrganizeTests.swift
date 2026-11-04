import CoreGraphics
import CoreText
import DropwheelCore
import Foundation
import PDFKit
import Testing
@testable import DropwheelEngines

/// Organize Pages on small generated PDFs.
final class PDFOrganizeTests {
    private let folder: URL
    private let tools = ToolService()

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropwheel-organize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test("Pages come out in the new order, in a copy beside the original")
    func reorders() async throws {
        let input = try makePDF(pages: 4)
        let pages = [PDFPageSlot].allPages(count: 4)
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(pages.moving([pages[3].id], to: 0)))
        #expect(output.lastPathComponent == "doc organized.pdf")
        #expect(try texts(output) == ["PAGE4", "PAGE1", "PAGE2", "PAGE3"])
        #expect(try texts(input) == ["PAGE1", "PAGE2", "PAGE3", "PAGE4"])
    }

    @Test("A turn adds to the way a page is already turned")
    func rotates() async throws {
        let input = try makePDF(pages: 2)
        try update(input) { $0.page(at: 0)?.rotation = 90 }
        let pages = [PDFPageSlot].allPages(count: 2)
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(pages.rotating([pages[0].id], by: 1)))
        let document = try #require(PDFDocument(url: output))
        #expect(document.page(at: 0)?.rotation == 180)
        #expect(document.page(at: 1)?.rotation == 0)
    }

    @Test("A duplicate is a page of its own, turned separately")
    func duplicates() async throws {
        let input = try makePDF(pages: 2)
        let pages = [PDFPageSlot].allPages(count: 2)
        let doubled = pages.duplicating([pages[0].id])
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(doubled.rotating([doubled[1].id], by: 1)))
        #expect(try texts(output) == ["PAGE1", "PAGE1", "PAGE2"])
        let document = try #require(PDFDocument(url: output))
        #expect(document.page(at: 0)?.rotation == 0)
        #expect(document.page(at: 1)?.rotation == 90)
    }

    @Test("A page moved and duplicated at once ends up in both places")
    func duplicatedThenMoved() async throws {
        let input = try makePDF(pages: 3)
        let pages = [PDFPageSlot].allPages(count: 3)
        let doubled = pages.duplicating([pages[0].id])
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(doubled.moving([doubled[1].id], to: 4)))
        #expect(try texts(output) == ["PAGE1", "PAGE2", "PAGE3", "PAGE1"])
    }

    @Test("A removed page's contents leave the file")
    func removedContentGoes() async throws {
        let input = try makePDF(pages: 3, noiseOnPage: 2)
        let pages = [PDFPageSlot].allPages(count: 3)
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(pages.removing([pages[1].id])))
        #expect(try texts(output) == ["PAGE1", "PAGE3"])
        let before = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let after = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(before > 200_000)
        #expect(after < before / 4)
    }

    @Test("Bookmarks follow their pages, and those to removed pages go")
    func bookmarks() async throws {
        let input = try makePDF(pages: 4)
        try update(input) { document in
            let root = PDFOutline()
            for index in [0, 1, 2] {
                let item = PDFOutline()
                item.label = "Page \(index + 1)"
                item.destination = PDFDestination(page: try #require(document.page(at: index)), at: .zero)
                root.insertChild(item, at: index)
            }
            document.outlineRoot = root
        }
        let pages = [PDFPageSlot].allPages(count: 4)
        let output = try await tools.run(.organizePDF, on: [input],
                                         options: .pdfPages(pages.removing([pages[1].id]).moving([pages[2].id], to: 0)))
        #expect(try texts(output) == ["PAGE3", "PAGE1", "PAGE4"])
        #expect(try bookmarks(of: output) == ["Page 1 → 2", "Page 3 → 1"])
    }

    @Test("A heading over kept pages stays when its own page goes")
    func headingStays() async throws {
        let input = try makePDF(pages: 3)
        try update(input) { document in
            let root = PDFOutline()
            let heading = PDFOutline()
            heading.label = "Part"
            heading.destination = PDFDestination(page: try #require(document.page(at: 0)), at: .zero)
            let gone = PDFOutline()
            gone.label = "Gone"
            gone.action = PDFActionGoTo(destination: PDFDestination(page: try #require(document.page(at: 0)), at: .zero))
            let kept = PDFOutline()
            kept.label = "Kept"
            kept.destination = PDFDestination(page: try #require(document.page(at: 2)), at: .zero)
            heading.insertChild(gone, at: 0)
            heading.insertChild(kept, at: 1)
            root.insertChild(heading, at: 0)
            document.outlineRoot = root
        }
        let pages = [PDFPageSlot].allPages(count: 3)
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(pages.removing([pages[0].id])))
        #expect(try bookmarks(of: output) == ["Part → none", "Kept → 2"])
    }

    @Test("Links follow their pages, and those to removed pages go")
    func links() async throws {
        let input = try makePDF(pages: 3)
        try update(input) { document in
            let page = try #require(document.page(at: 0))
            for (index, target) in [1, 2].enumerated() {
                let link = PDFAnnotation(bounds: CGRect(x: 0, y: CGFloat(index) * 30, width: 50, height: 20), forType: .link, withProperties: nil)
                link.destination = PDFDestination(page: try #require(document.page(at: target)), at: .zero)
                page.addAnnotation(link)
            }
        }
        let pages = [PDFPageSlot].allPages(count: 3)
        let output = try await tools.run(.organizePDF, on: [input],
                                         options: .pdfPages(pages.removing([pages[1].id]).moving([pages[2].id], to: 0)))
        let document = try #require(PDFDocument(url: output))
        #expect(try texts(output) == ["PAGE3", "PAGE1"])
        let links = try #require(document.page(at: 1)).annotations.filter { $0.type == "Link" }
        #expect(links.count == 1)
        let target = try #require(links.first?.destination?.page)
        #expect(document.index(for: target) == 0)
    }

    @Test("The document's title stays")
    func keepsDocumentInfo() async throws {
        let input = try makePDF(pages: 2, title: "Annual report")
        let pages = [PDFPageSlot].allPages(count: 2)
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(pages.moving([pages[1].id], to: 0)))
        let attributes = try #require(PDFDocument(url: output)).documentAttributes
        #expect(attributes?[PDFDocumentAttribute.titleAttribute] as? String == "Annual report")
    }

    @Test("The document's dates, producer and any other details stay, and only the change date moves")
    func keepsWholeInfo() async throws {
        let input = try makeHandmadePDF(pages: 2, info: "/Producer (Acrobat) /CreationDate (D:20200102030405Z) /ModDate (D:20200102030405Z) /Company (Acme)")
        let pages = [PDFPageSlot].allPages(count: 2)
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(pages.moving([pages[1].id], to: 0)))
        let info = PDFInfo.entries(of: output)
        #expect(info["Producer"] == .text("Acrobat"))
        #expect(info["CreationDate"] == .text("D:20200102030405Z"))
        #expect(info["Company"] == .text("Acme"))
        #expect(info["ModDate"] != .text("D:20200102030405Z"))
    }

    @Test("A stored preview of the first page goes once that page has", arguments: [(0, false), (2, true)])
    func storedPreview(removedPage: Int, keepsPreview: Bool) async throws {
        let input = try makeHandmadePDF(pages: 3, packet: Self.packetWithThumbnail)
        let pages = [PDFPageSlot].allPages(count: 3)
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(pages.removing([pages[removedPage].id])))
        let packet = String(decoding: try #require(PDFXMP.packet(of: output)), as: UTF8.self)
        #expect(packet.contains("PREVIEWBYTES") == keepsPreview)
        #expect(packet.contains("kept-identifier"))
    }

    @Test("A new first page makes the stored preview wrong too")
    func storedPreviewOfMovedPage() async throws {
        let input = try makeHandmadePDF(pages: 3, packet: Self.packetWithThumbnail)
        let pages = [PDFPageSlot].allPages(count: 3)
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(pages.moving([pages[2].id], to: 0)))
        #expect(!String(decoding: try #require(PDFXMP.packet(of: output)), as: UTF8.self).contains("PREVIEWBYTES"))
    }

    @Test("A packet that can't be read stays while the first page does")
    func unreadablePacketKept() async throws {
        let packet = "<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'/></x:xmpmeta>"
        let input = try makeHandmadePDF(pages: 2, packet: packet)
        let pages = [PDFPageSlot].allPages(count: 2)
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(pages.removing([pages[1].id])))
        #expect(PDFXMP.packet(of: output) != nil)
    }

    @Test("A packet that can't be read goes with the first page, as it could hold a preview")
    func unreadablePacketOnRemoval() async throws {
        let packet = "<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'/></x:xmpmeta>"
        let input = try makeHandmadePDF(pages: 2, packet: packet)
        let pages = [PDFPageSlot].allPages(count: 2)
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(pages.removing([pages[0].id])))
        #expect(PDFXMP.packet(of: output) == nil)
    }

    @Test("A claim to meet PDF/A doesn't carry over to a rewritten file")
    func conformanceClaim() async throws {
        let packet = Self.packet(fields: #"<pdfaid:part xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">2</pdfaid:part>"#)
        let input = try makeHandmadePDF(pages: 2, packet: packet)
        let pages = [PDFPageSlot].allPages(count: 2)
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(pages.moving([pages[1].id], to: 0)))
        #expect(!String(decoding: try #require(PDFXMP.packet(of: output)), as: UTF8.self).contains("pdfaid"))
    }

    @Test("Numbers and flags in the document details stay")
    func keepsOtherInfoValues() async throws {
        let input = try makeHandmadePDF(pages: 2, info: "/Title (Doc) /Rating 5 /Weight 1.5 /Flag true /Trapped /False")
        let pages = [PDFPageSlot].allPages(count: 2)
        let output = try await tools.run(.organizePDF, on: [input], options: .pdfPages(pages.moving([pages[1].id], to: 0)))
        let info = PDFInfo.entries(of: output)
        #expect(info["Rating"] == .literal("5"))
        #expect(info["Weight"] == .literal("1.5"))
        #expect(info["Flag"] == .literal("true"))
        #expect(info["Trapped"] == .name("False"))
    }

    @Test("A PDF protected against changes is refused, even if it opens without a password")
    func protectedPDF() async throws {
        let input = try makePDF(pages: 2, ownerPassword: "owner")
        #expect(PDFDocument(url: input)?.isLocked == false)
        let pages = [PDFPageSlot].allPages(count: 2)
        await #expect(throws: ConversionError.passwordProtected(input.lastPathComponent)) {
            try await self.tools.run(.organizePDF, on: [input], options: .pdfPages(pages.moving([pages[1].id], to: 0)))
        }
        #expect(throws: ConversionError.passwordProtected(input.lastPathComponent)) {
            try PDFThumbnails(url: input)
        }
    }

    @Test("An object is found through the cross-reference table, not by what looks like it")
    func objectLookup() throws {
        var body = "%PDF-1.3\n"
        let real = body.utf8.count
        body += "1 0 obj\n<< /Title (REAL) >>\nendobj\n"
        let lookalike = body.utf8.count
        body += "2 0 obj\n<< /Length 40 >>\nstream\n\n1 0 obj\n<< /Title (FAKE) >>\nendobj\n\nendstream\nendobj\n"
        let table = body.utf8.count
        let entries = [real, lookalike].map { String(format: "%010ld 00000 n \n", $0) }.joined()
        body += "xref\n0 3\n0000000000 65535 f \n\(entries)trailer\n<< /Size 3 /Info 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        var data = Data(body.utf8)

        let found = try #require(PDFPatch.objectBody(1, in: data))
        #expect(String(decoding: data[found], as: UTF8.self).contains("REAL"))

        try PDFPatch.append(1, body: Data("<< /Title (NEW) >>".utf8), to: &data)
        let updated = try #require(PDFPatch.objectBody(1, in: data))
        #expect(String(decoding: data[updated], as: UTF8.self).contains("NEW"))
        let untouched = try #require(PDFPatch.objectBody(2, in: data))
        #expect(String(decoding: data[untouched], as: UTF8.self).contains("FAKE"))
        #expect(PDFPatch.objectBody(9, in: data) == nil)
    }

    @Test("A title that mentions endobj is wiped whole")
    func wipeThroughEndobj() async throws {
        let input = try makeHandmadePDF(pages: 1, info: "/Title (first endobj SECRET-REMAINDER)")
        let output = try await tools.run(.removeMetadata, on: [input])
        #expect(try Data(contentsOf: output).range(of: Data("SECRET-REMAINDER".utf8)) == nil)
    }

    @Test("A wrong key in a trailer isn't taken for the one asked for")
    func trailerKey() {
        let text = "xref\n0 1\n0000000000 65535 f \ntrailer\n<< /InfoX 9 0 R /Info 3 0 R >>\nstartxref\n9\n%%EOF\n"
        let data = Data(("%PDF-1.3\n" + text).utf8)
        #expect(PDFPatch.reference("/Info", in: data) == 3)
    }

    @Test("What a rewrite can't keep is named before saving", arguments: [
        ("/Names << /EmbeddedFiles << /Names [] >> >>", ["attachments"]),
        ("/Names << /JavaScript << /Names [] >> >>", ["scripts"]),
        ("/StructTreeRoot << /Type /StructTreeRoot >>", ["accessibility tags"]),
        ("/PageLabels << /Nums [0 << /S /r >>] >>", ["page labels"]),
        ("/PageLabels << /Nums [] >> /StructTreeRoot << >>", ["accessibility tags", "page labels"]),
        ("", []),
    ])
    func partsNotKept(catalog: String, parts: [String]) throws {
        let input = try makeHandmadePDF(pages: 1, catalog: catalog)
        #expect(PDFStructure.partsNotKept(in: input) == parts)
    }

    @Test("A page scale is named too")
    func pageScale() throws {
        let input = try makeHandmadePDF(pages: 1, page: "/UserUnit 2")
        #expect(PDFStructure.partsNotKept(in: input) == ["page scale"])
    }

    @Test("The warning reads as a sentence")
    func warningText() {
        #expect(PDFStructure.warning(for: []) == nil)
        #expect(PDFStructure.warning(for: ["attachments"]) == "A saved copy leaves out this PDF’s attachments.")
        #expect(PDFStructure.warning(for: ["attachments", "page labels", "scripts"])
            == "A saved copy leaves out this PDF’s attachments, page labels and scripts.")
    }

    @Test("A locked PDF is refused")
    func locked() async throws {
        let input = try makePDF(pages: 2, password: "secret")
        let pages = [PDFPageSlot].allPages(count: 2)
        await #expect(throws: ConversionError.passwordProtected(input.lastPathComponent)) {
            try await self.tools.run(.organizePDF, on: [input], options: .pdfPages(pages))
        }
    }

    @Test("A PDF needs at least one page left")
    func noPagesLeft() async throws {
        let input = try makePDF(pages: 2)
        await #expect(throws: ConversionError.noPagesLeft(input.lastPathComponent)) {
            try await self.tools.run(.organizePDF, on: [input], options: .pdfPages([]))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["doc.pdf"])
    }

    @Test("A page that isn't in the PDF is refused")
    func pageOutOfRange() async throws {
        let input = try makePDF(pages: 2)
        await #expect(throws: ConversionError.unreadableInput(input.lastPathComponent)) {
            try await self.tools.run(.organizePDF, on: [input], options: .pdfPages([PDFPageSlot(sourceIndex: 2)]))
        }
    }

    // MARK: Thumbnails

    @Test("A thumbnail fits the long edge, and a quarter turn swaps its sides")
    func thumbnails() async throws {
        let input = try makePDF(pages: 2)
        let thumbnails = try PDFThumbnails(url: input)
        #expect(thumbnails.pageCount == 2)
        let upright = try await thumbnails.image(ofPage: 0, quarterTurns: 0, longEdge: 200)
        #expect((upright.width, upright.height) == (150, 200))
        let turned = try await thumbnails.image(ofPage: 1, quarterTurns: 1, longEdge: 200)
        #expect((turned.width, turned.height) == (200, 150))
    }

    @Test("A page's own rotation counts in its thumbnail")
    func thumbnailOfTurnedPage() async throws {
        let input = try makePDF(pages: 1)
        try update(input) { $0.page(at: 0)?.rotation = 90 }
        let image = try await PDFThumbnails(url: input).image(ofPage: 0, quarterTurns: 0, longEdge: 200)
        #expect((image.width, image.height) == (200, 150))
    }

    @Test("Thumbnails are refused for a locked PDF")
    func thumbnailsOfLockedPDF() throws {
        let input = try makePDF(pages: 1, password: "secret")
        #expect(throws: ConversionError.passwordProtected(input.lastPathComponent)) {
            try PDFThumbnails(url: input)
        }
    }

    @Test("A page that doesn't exist has no thumbnail")
    func thumbnailOutOfRange() async throws {
        let thumbnails = try PDFThumbnails(url: try makePDF(pages: 1))
        await #expect(throws: ConversionError.unreadableInput("PDF page")) {
            try await thumbnails.image(ofPage: 3, quarterTurns: 0, longEdge: 100)
        }
    }

    @Test("A thumbnail nobody is waiting for isn't drawn")
    func thumbnailCancelled() async throws {
        let thumbnails = try PDFThumbnails(url: try makePDF(pages: 1))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await thumbnails.image(ofPage: 0, quarterTurns: 0, longEdge: 100)
        }
        await #expect(throws: ConversionError.cancelled) {
            try await task.value
        }
    }

    // MARK: Fixtures

    private static let packetWithThumbnail = packet(fields: """
    <xmp:Thumbnails xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:xmpGImg="http://ns.adobe.com/xap/1.0/g/img/"><rdf:Alt><rdf:li \
    rdf:parseType="Resource"><xmpGImg:image>PREVIEWBYTES</xmpGImg:image></rdf:li></rdf:Alt></xmp:Thumbnails>
    """)

    private static func packet(fields: String) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">\
        <dc:identifier>kept-identifier</dc:identifier>\(fields)</rdf:Description></rdf:RDF></x:xmpmeta>
        """
    }

    /// A PDF written by hand, for what Quartz and PDFKit wouldn't produce.
    private func makeHandmadePDF(pages: Int, info: String = "/Title (Doc)", packet: String? = nil,
                                 catalog: String = "", page: String = "") throws -> URL {
        let pageNumbers = (0..<pages).map { 5 + $0 }
        var body = "%PDF-1.5\n"
        var offsets: [Int: Int] = [:]
        func object(_ number: Int, _ text: String) {
            offsets[number] = body.utf8.count
            body += "\(number) 0 obj\n\(text)\nendobj\n"
        }
        let metadata = packet == nil ? "" : "/Metadata 4 0 R"
        object(1, "<< /Type /Catalog /Pages 2 0 R \(metadata) \(catalog) >>")
        let kids = pageNumbers.map { "\($0) 0 R" }.joined(separator: " ")
        object(2, "<< /Type /Pages /Kids [\(kids)] /Count \(pages) >>")
        object(3, "<< \(info) >>")
        if let packet {
            object(4, "<< /Type /Metadata /Subtype /XML /Length \(packet.utf8.count) >>\nstream\n\(packet)\nendstream")
        } else {
            object(4, "null")
        }
        for number in pageNumbers {
            object(number, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> \(page) >>")
        }
        let count = 5 + pages
        let table = body.utf8.count
        body += "xref\n0 \(count)\n0000000000 65535 f \n"
        for number in 1..<count {
            body += String(format: "%010ld 00000 n \n", offsets[number] ?? 0)
        }
        body += "trailer\n<< /Size \(count) /Root 1 0 R /Info 3 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        let url = folder.appendingPathComponent("doc.pdf")
        try Data(body.utf8).write(to: url)
        return url
    }

    private func makePDF(pages: Int, title: String? = nil, password: String? = nil, ownerPassword: String? = nil,
                         noiseOnPage: Int? = nil) throws -> URL {
        let url = folder.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        if let ownerPassword {
            info[kCGPDFContextOwnerPassword] = ownerPassword
            info[kCGPDFContextAllowsCopying] = false
        }
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for number in 1...pages {
            context.beginPDFPage(nil)
            let text = CFAttributedStringCreate(nil, "PAGE\(number)" as CFString, [kCTFontAttributeName: font] as CFDictionary)
            context.textPosition = CGPoint(x: 20, y: 200)
            CTLineDraw(CTLineCreateWithAttributedString(try #require(text)), context)
            if number == noiseOnPage {
                context.draw(try noise(), in: CGRect(x: 0, y: 0, width: 100, height: 100))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// Random pixels, which no compression can shrink.
    private func noise() throws -> CGImage {
        let side = 256
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<side * side * 4).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Changes a fixture through PDFKit. A PDF can't be saved over itself.
    private func update(_ url: URL, _ change: (PDFDocument) throws -> Void) throws {
        let document = try #require(PDFDocument(url: url))
        try change(document)
        let changed = folder.appendingPathComponent("changed.pdf")
        #expect(document.write(to: changed))
        _ = try FileManager.default.replaceItemAt(url, withItemAt: changed)
    }

    private func texts(_ url: URL) throws -> [String] {
        let document = try #require(PDFDocument(url: url))
        return (0..<document.pageCount).map {
            document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// Every bookmark as "label → page number", or "none".
    private func bookmarks(of url: URL) throws -> [String] {
        let document = try #require(PDFDocument(url: url))
        func list(_ item: PDFOutline) -> [String] {
            (0..<item.numberOfChildren).compactMap(item.child).flatMap { child in
                let page = child.destination?.page.map { String(document.index(for: $0) + 1) } ?? "none"
                return ["\(child.label ?? "") → \(page)"] + list(child)
            }
        }
        return document.outlineRoot.map(list) ?? []
    }
}
