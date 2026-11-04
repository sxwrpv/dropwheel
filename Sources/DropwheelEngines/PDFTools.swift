import DropwheelCore
import Foundation
import PDFKit

/// Compress, Remove Metadata and Merge for PDFs.
enum PDFTools {
    /// Re-saves with images stored as JPEG; the stronger presets also
    /// downsample images to screen resolution. Before macOS 13.4 PDFKit has
    /// no such options, so the PDF is only re-saved, and the caller reports
    /// it if that didn't make it smaller.
    static func compress(_ input: URL, level: CompressionLevel, output: URL) throws(ConversionError) {
        let document = try open(input)
        var options: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            options[.saveImagesAsJPEGOption] = true
            if level != .light {
                options[.optimizeImagesForScreenOption] = true
            }
        }
        guard document.write(to: output, withOptions: options) else {
            throw .writeFailed("The PDF couldn’t be saved.")
        }
    }

    /// Clears the document information, every XMP packet, which repeats much
    /// of it, and the names of whoever annotated the pages.
    static func stripMetadata(_ input: URL, output: URL) throws(ConversionError) {
        let document = try open(input)
        clearAnnotationAuthors(in: document)
        guard document.write(to: output) else { throw .writeFailed("The PDF couldn’t be saved.") }
        try PDFInfo.write([:], in: output)
        try PDFXMP.removeAll(in: output)
    }

    static func clearAnnotationAuthors(in document: PDFDocument) {
        for page in (0..<document.pageCount).compactMap(document.page(at:)) {
            page.annotations.forEach { $0.userName = nil }
        }
    }

    /// Appends every page of each PDF, in selection order.
    static func merge(_ inputs: [URL], output: URL, progress: @escaping ProgressHandler) throws(ConversionError) {
        let merged = PDFDocument()
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation(or: .cancelled)
            let document = try open(input)
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex)?.copy() as? PDFPage else {
                    throw .unreadableInput(input.lastPathComponent)
                }
                merged.insert(page, at: merged.pageCount)
            }
            progress(Double(index + 1) / Double(inputs.count))
        }
        guard merged.write(to: output) else { throw .writeFailed("The merged PDF couldn’t be saved.") }
    }

    static func open(_ input: URL) throws(ConversionError) -> PDFDocument {
        try PDFConverter.requireUnlocked(input)
        guard PDFInfo.hasValidNames(input), let document = PDFDocument(url: input) else {
            throw .unreadableInput(input.lastPathComponent)
        }
        return document
    }

    /// True even for a PDF that opens without a password. PDFKit keeps the
    /// encryption, and what is patched into the file it saves couldn't match
    /// it, so these can't be organized or have their details changed.
    static func isEncrypted(_ input: URL) -> Bool {
        CGPDFDocument(input as CFURL)?.isEncrypted ?? false
    }
}
