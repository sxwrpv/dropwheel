import CoreGraphics
import DropwheelCore
import Foundation
import ImageIO
import PDFKit

/// PDF to images, text, documents, slides and spreadsheets.
///
/// Images are exact renders. Everything else rebuilds content from the
/// PDF's text layer, so layout is simplified, and scanned PDFs without a
/// text layer can't be converted to text formats.
struct PDFConverter: Converter {
    func convert(_ input: URL, to target: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        progress(0)
        try Self.requireUnlocked(input)
        switch target {
        case .jpg, .png:
            try PDFPageRenderer.render(input, as: target, to: output, baseName: input.formatStem)
        case .txt:
            try TextFile.write(try Self.pageTexts(of: input).joined(separator: "\n\n") + "\n", to: output)
        case .md, .docx, .epub, .pages:
            try await convertThroughHTML(input, to: target, output: output)
        case .pptx:
            try await LibreOffice.convert(input, filter: "pptx", inputFilter: "impress_pdf_import", to: output)
        case .xlsx:
            try await convertTables(input, output: output)
        default:
            throw .unsupported(input: input.lastPathComponent, target: target)
        }
        progress(1)
    }

    /// Paragraphs go to pandoc as HTML, which then writes the target format.
    private func convertThroughHTML(_ input: URL, to target: FileFormat, output: URL) async throws(ConversionError) {
        let scratch = try ScratchSpace.make(near: output)
        defer { ScratchSpace.discard(scratch) }
        let title = input.formatStem
        let paragraphs = try Self.pageTexts(of: input).flatMap(PlainTextLayout.paragraphs(in:))
        let html = scratch.appendingPathComponent("document.html")
        try TextFile.write(HTMLDocument.make(title: title, paragraphs: paragraphs), to: html)

        if target == .pages {
            let word = scratch.appendingPathComponent("document.docx")
            try await Pandoc.convert(html, reader: "html", to: .docx, output: word, title: title)
            try await PagesBridge.saveAsPages(word, output: output)
        } else {
            try await Pandoc.convert(html, reader: "html", to: target, output: output, title: title)
        }
    }

    /// Lines become rows and runs of spaces become columns, then LibreOffice
    /// builds the workbook from CSV.
    private func convertTables(_ input: URL, output: URL) async throws(ConversionError) {
        let scratch = try ScratchSpace.make(near: output)
        defer { ScratchSpace.discard(scratch) }
        let rows = try Self.pageTexts(of: input).flatMap(PlainTextLayout.tableRows(in:))
        let csv = scratch.appendingPathComponent("\(input.formatStem).csv")
        try TextFile.write(CSV.write(rows, separator: ","), to: csv)
        try await LibreOffice.convert(csv, filter: "xlsx", inputFilter: OfficeConverter.csvImportFilter, to: output)
    }

    /// A locked PDF reports pages it can't open, so it is refused up front
    /// with a message that says why.
    static func requireUnlocked(_ input: URL) throws(ConversionError) {
        guard let document = CGPDFDocument(input as CFURL) else { throw .unreadableInput(input.lastPathComponent) }
        if document.isEncrypted && !document.isUnlocked {
            throw .passwordProtected(input.lastPathComponent)
        }
    }

    /// Text of each page. Throws when the PDF has no text layer at all.
    static func pageTexts(of input: URL) throws(ConversionError) -> [String] {
        guard let document = PDFDocument(url: input) else { throw .unreadableInput(input.lastPathComponent) }
        if document.isLocked { throw .passwordProtected(input.lastPathComponent) }
        var texts: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation(or: .cancelled)
            texts.append(document.page(at: index)?.string ?? "")
        }
        guard texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw .noText(input.lastPathComponent)
        }
        return texts
    }
}

/// Renders PDF pages to PNG or JPEG at print resolution.
enum PDFPageRenderer {
    static let dotsPerInch = 300.0
    /// Keeps posters and huge pages within a sensible bitmap size.
    static let maximumLongEdge = 12_000.0
    private static let pointsPerInch = 72.0
    private static let jpegQuality = 0.9

    /// One page becomes one file at `output`; several pages become a folder
    /// at `output` holding "<baseName> 01.png" and so on.
    static func render(_ pdf: URL, as format: FileFormat, to output: URL, baseName: String) throws(ConversionError) {
        guard let document = CGPDFDocument(pdf as CFURL), document.numberOfPages > 0 else {
            throw .unreadableInput(pdf.lastPathComponent)
        }
        if document.isEncrypted && !document.isUnlocked {
            throw .passwordProtected(pdf.lastPathComponent)
        }
        let pageCount = document.numberOfPages
        if pageCount == 1 {
            guard let page = document.page(at: 1) else { throw .unreadableInput(pdf.lastPathComponent) }
            try write(page, as: format, to: output)
            return
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        let digits = max(2, String(pageCount).count)
        for number in 1...pageCount {
            try Task.checkCancellation(or: .cancelled)
            // A missing page means a damaged file; a folder with gaps would look like success.
            guard let page = document.page(at: number) else { throw .unreadableInput(pdf.lastPathComponent) }
            let index = String(repeating: "0", count: digits - String(number).count) + String(number)
            try write(page, as: format, to: output.appendingPathComponent("\(baseName) \(index).\(format.preferredExtension)"))
        }
    }

    private static func write(_ page: CGPDFPage, as format: FileFormat, to url: URL) throws(ConversionError) {
        let image = try render(page)
        let type = format == .jpg ? "public.jpeg" : "public.png"
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw .writeFailed("Couldn’t create \(url.lastPathComponent).")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
            kCGImagePropertyDPIWidth: dotsPerInch,
            kCGImagePropertyDPIHeight: dotsPerInch,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .writeFailed("The image encoder failed.") }
    }

    /// Draws the page on white, honouring its /Rotate setting plus any
    /// clockwise `quarterTurns`.
    static func render(_ page: CGPDFPage, maximumLongEdge limit: Double = maximumLongEdge,
                       quarterTurns: Int = 0) throws(ConversionError) -> CGImage {
        let box = page.getBoxRect(.cropBox)
        let rotation = (((Int(page.rotationAngle) + quarterTurns * 90) % 360) + 360) % 360
        let isSideways = rotation == 90 || rotation == 270
        let displayWidth = isSideways ? box.height : box.width
        let displayHeight = isSideways ? box.width : box.height
        let longEdge = max(displayWidth, displayHeight)
        guard longEdge > 0 else { throw .unreadableInput("PDF page") }

        let scale = min(dotsPerInch / pointsPerInch, limit / longEdge)
        let width = Int((displayWidth * scale).rounded())
        let height = Int((displayHeight * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw .writeFailed("Couldn’t prepare the page image.")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Rotate about the output, then scale, then move the crop box to the origin.
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: CGFloat(height))
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: CGFloat(width), y: CGFloat(height))
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: CGFloat(width), y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(page)

        guard let image = context.makeImage() else { throw .writeFailed("Couldn’t render the page.") }
        return image
    }
}
