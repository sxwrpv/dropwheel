import AppKit
import DropwheelCore
import Foundation

/// Conversions among DOCX, Pages, Markdown, plain text, EPUB, RTF, RTFD and
/// text clippings, plus HTML and PDF export.
///
/// pandoc does the text-format work. Formats it can't read are first turned
/// into something it can: plain text into HTML, RTFD and clippings into
/// DOCX through AppKit, Pages documents into DOCX through Pages. PDF comes
/// from LibreOffice, and .pages output from Pages.
struct DocumentConverter: Converter {
    func convert(_ input: URL, to target: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        guard let format = FileFormat(fileName: input.lastPathComponent) else {
            throw .unsupported(input: input.lastPathComponent, target: target)
        }
        progress(0)
        let scratch = try ScratchSpace.make(near: output)
        defer { ScratchSpace.discard(scratch) }
        let title = input.formatStem
        let source = try await pandocSource(for: input, format: format, scratch: scratch)

        switch target {
        case .docx, .md, .txt, .epub, .html:
            try await Pandoc.convert(source.url, reader: source.reader, to: target, output: output, title: title)
        case .pdf:
            let word = try await wordFile(from: input, format: format, source: source, scratch: scratch, title: title)
            try await LibreOffice.convert(word, filter: "pdf", to: output)
        case .pages:
            let word = try await wordFile(from: input, format: format, source: source, scratch: scratch, title: title)
            try await PagesBridge.saveAsPages(word, output: output)
        default:
            throw .unsupported(input: input.lastPathComponent, target: target)
        }
        progress(1)
    }

    private struct PandocSource {
        let url: URL
        /// pandoc's name for the input format.
        let reader: String
    }

    private func pandocSource(for input: URL, format: FileFormat, scratch: URL) async throws(ConversionError) -> PandocSource {
        switch format {
        case .docx: return PandocSource(url: input, reader: "docx")
        case .md: return PandocSource(url: input, reader: "markdown")
        case .epub: return PandocSource(url: input, reader: "epub")
        case .rtf: return PandocSource(url: input, reader: "rtf")
        case .html: return PandocSource(url: input, reader: "html")
        case .txt:
            // pandoc has no plain-text reader, and reading it as Markdown
            // would turn stray asterisks into formatting.
            let html = scratch.appendingPathComponent("source.html")
            try TextFile.write(HTMLDocument.fromPlainText(try TextFile.read(input), title: input.formatStem), to: html)
            return PandocSource(url: html, reader: "html")
        case .rtfd, .textClipping:
            let word = scratch.appendingPathComponent("source.docx")
            try Self.writeWord(try Self.attributedText(of: input, format: format), to: word)
            return PandocSource(url: word, reader: "docx")
        case .pages:
            let word = scratch.appendingPathComponent("source.docx")
            try await PagesBridge.exportToWord(input, output: word)
            return PandocSource(url: word, reader: "docx")
        default:
            throw .unsupported(input: input.lastPathComponent, target: .docx)
        }
    }

    /// A DOCX of the input, for LibreOffice and Pages to open.
    private func wordFile(from input: URL, format: FileFormat, source: PandocSource, scratch: URL, title: String) async throws(ConversionError) -> URL {
        if format == .docx { return input }
        if source.reader == "docx" { return source.url }
        let word = scratch.appendingPathComponent("\(title).docx")
        try await Pandoc.convert(source.url, reader: source.reader, to: .docx, output: word, title: title)
        return word
    }

    // MARK: Rich text

    private static func attributedText(of input: URL, format: FileFormat) throws(ConversionError) -> NSAttributedString {
        if format == .rtfd {
            guard let text = try? NSAttributedString(url: input, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                     documentAttributes: nil) else {
                throw .unreadableInput(input.lastPathComponent)
            }
            return text
        }
        return try clippingText(input)
    }

    /// Text clippings are property lists holding the dragged text under
    /// type identifiers; rich text is preferred over plain.
    private static func clippingText(_ input: URL) throws(ConversionError) -> NSAttributedString {
        guard let data = try? Data(contentsOf: input),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let contents = plist["UTI-Data"] as? [String: Any] else {
            throw .unreadableInput(input.lastPathComponent)
        }
        if let rtf = contents["public.rtf"] as? Data,
           let text = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                              documentAttributes: nil) {
            return text
        }
        let plainTextTypes: [(key: String, encoding: String.Encoding)] = [
            ("public.utf8-plain-text", .utf8),
            ("public.utf16-plain-text", .utf16LittleEndian),
            ("public.plain-text", .utf8),
            ("com.apple.traditional-mac-plain-text", .macOSRoman),
        ]
        for type in plainTextTypes {
            if let string = contents[type.key] as? String { return NSAttributedString(string: string) }
            if let raw = contents[type.key] as? Data, let string = String(data: raw, encoding: type.encoding) {
                return NSAttributedString(string: string)
            }
        }
        throw .unreadableInput(input.lastPathComponent)
    }

    private static func writeWord(_ text: NSAttributedString, to url: URL) throws(ConversionError) {
        let attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        do {
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
            try data.write(to: url)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }
}
