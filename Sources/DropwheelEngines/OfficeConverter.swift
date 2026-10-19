import DropwheelCore
import Foundation

/// Slides (PPT, PPTX) and spreadsheets (XLSX, XLS, ODS, CSV, TSV) through
/// LibreOffice. CSV ↔ TSV is done directly, without starting LibreOffice.
struct OfficeConverter: Converter {
    /// LibreOffice CSV import options, in order: separator (44 = comma),
    /// text delimiter (34 = "), character set (76 = UTF-8), first line,
    /// column formats, language, quoted fields as text, detect special
    /// numbers (off, so "1/2" stays text instead of becoming a date), three
    /// export-only options, sheet, and evaluate formulas (off, so "=1+1"
    /// stays text: cell text may come from an untrusted file).
    static let csvImportFilter = "CSV:44,34,76,1,,0,false,false,false,false,false,0,false"
    private static let tsvImportFilter = "CSV:9,34,76,1,,0,false,false,false,false,false,0,false"
    private static let csvExportFilter = "csv:Text - txt - csv (StarCalc):44,34,76,1"
    private static let tsvExportFilter = "csv:Text - txt - csv (StarCalc):9,34,76,1"

    func convert(_ input: URL, to target: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        guard let format = FileFormat(fileName: input.lastPathComponent) else {
            throw .unsupported(input: input.lastPathComponent, target: target)
        }
        progress(0)
        switch format.family {
        case .slides: try await convertSlides(input, to: target, output: output)
        case .spreadsheet: try await convertSheet(input, as: format, to: target, output: output)
        default: throw .unsupported(input: input.lastPathComponent, target: target)
        }
        progress(1)
    }

    private func convertSlides(_ input: URL, to target: FileFormat, output: URL) async throws(ConversionError) {
        switch target {
        case .pdf, .pptx:
            try await LibreOffice.convert(input, filter: target.preferredExtension, to: output)
        case .jpg, .png:
            // Render each slide from a PDF, at the same resolution as PDF pages.
            let scratch = try ScratchSpace.make(near: output)
            defer { ScratchSpace.discard(scratch) }
            let pdf = scratch.appendingPathComponent("slides.pdf")
            try await LibreOffice.convert(input, filter: "pdf", to: pdf)
            try PDFPageRenderer.render(pdf, as: target, to: output, baseName: input.formatStem)
        default:
            throw .unsupported(input: input.lastPathComponent, target: target)
        }
    }

    /// Only the first sheet of a workbook is exported to CSV or TSV.
    private func convertSheet(_ input: URL, as format: FileFormat, to target: FileFormat, output: URL) async throws(ConversionError) {
        let isDelimited: (FileFormat) -> Bool = { $0 == .csv || $0 == .tsv }
        if isDelimited(format) && isDelimited(target) {
            let rows = CSV.parse(try TextFile.read(input), separator: Self.separator(for: format))
            try TextFile.write(CSV.write(rows, separator: Self.separator(for: target)), to: output)
            return
        }
        let exportFilter: String
        switch target {
        case .csv: exportFilter = Self.csvExportFilter
        case .tsv: exportFilter = Self.tsvExportFilter
        default: exportFilter = target.preferredExtension
        }
        guard isDelimited(format) else {
            try await LibreOffice.convert(input, filter: exportFilter, to: output)
            return
        }
        // The import filter declares UTF-8, so text in other encodings is
        // re-encoded first; otherwise accented letters would come out garbled.
        let scratch = try ScratchSpace.make(near: output)
        defer { ScratchSpace.discard(scratch) }
        let utf8Copy = scratch.appendingPathComponent(input.lastPathComponent)
        try TextFile.write(try TextFile.read(input), to: utf8Copy)
        let importFilter = format == .tsv ? Self.tsvImportFilter : Self.csvImportFilter
        try await LibreOffice.convert(utf8Copy, filter: exportFilter, inputFilter: importFilter, to: output)
    }

    private static func separator(for format: FileFormat) -> Character {
        format == .tsv ? "\t" : ","
    }
}
