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

    /// Clears the document information: title, author, subject, keywords,
    /// creator and dates.
    static func stripMetadata(_ input: URL, output: URL) throws(ConversionError) {
        let document = try open(input)
        document.documentAttributes = [:]
        guard document.write(to: output) else { throw .writeFailed("The PDF couldn’t be saved.") }
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

    private static func open(_ input: URL) throws(ConversionError) -> PDFDocument {
        try PDFConverter.requireUnlocked(input)
        guard let document = PDFDocument(url: input) else { throw .unreadableInput(input.lastPathComponent) }
        return document
    }
}
