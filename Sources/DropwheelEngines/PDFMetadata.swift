import CoreGraphics
import DropwheelCore
import Foundation
import ImageIO
import PDFKit

/// Reads and rewrites a PDF's fields: its Info dictionary, its XMP packet,
/// which ImageIO reads just as it does a picture's, and who annotated it.
enum PDFMetadata {
    private static let dateKeys = [PDFDocumentAttribute.creationDateAttribute, .modificationDateAttribute].map(\.rawValue)
    private static let annotationAuthorsKey = "AnnotationAuthors"
    private static let unreadablePacketKey = "XMP Packet"
    /// A claim to meet PDF/A, which a file PDFKit rewrote can't be held to.
    private static let conformancePrefix = "pdfaid:"
    /// A small picture of the first page.
    private static let previewKey = "xmp:Thumbnails"
    /// The XMP fields that repeat each Info field. They show once and change together.
    private static let repeats: [String: [String]] = [
        "Title": ["dc:title"], "Author": ["dc:creator"], "Subject": ["dc:description"],
        "Keywords": ["pdf:Keywords", "dc:subject"], "Creator": ["xmp:CreatorTool"], "Producer": ["pdf:Producer"],
        "CreationDate": ["xmp:CreateDate"], "ModDate": ["xmp:ModifyDate"],
    ]

    static func report(of url: URL) throws(ConversionError) -> MetadataReport {
        let document = try PDFTools.open(url)
        let attributes = document.documentAttributes ?? [:]
        let info = PDFInfo.entries(of: url).map { key, value in field(key, value: value, date: attributes[key] as? Date) }
        let repeated = Set(info.flatMap { repeats[$0.key] ?? [] })
        let fields = info + annotationFields(in: document) + packetFields(of: url, leavingOut: repeated)
        let isReadOnly = PDFTools.isEncrypted(url)
        let shown = isReadOnly ? fields.map { MetadataField(scope: .file, key: $0.key, value: $0.value, access: .locked) } : fields
        return MetadataReport(groups: [MetadataGroup(scope: .file, title: "File", fields: MetadataField.sorted(shown))], isReadOnly: isReadOnly)
    }

    static func edit(_ input: URL, recipe: MetadataRecipe, output: URL) throws(ConversionError) {
        guard !PDFTools.isEncrypted(input) else { throw .passwordProtected(input.lastPathComponent) }
        let document = try PDFTools.open(input)
        if recipe.changes.contains(where: { $0.key == annotationAuthorsKey }) {
            PDFTools.clearAnnotationAuthors(in: document)
        }
        guard document.write(to: output) else { throw .writeFailed("The PDF couldn’t be saved.") }

        let original = PDFInfo.entries(of: input)
        let isInfoKey: (String) -> Bool = { original[$0] != nil || isNewInfoKey($0) }
        var info = original
        for change in recipe.changes where isInfoKey(change.key) {
            info[change.key] = change.value.map(PDFInfo.Value.text)
        }
        try PDFInfo.write(info, in: output)
        try updatePacket(of: input, in: output, wipingUnreadable: true) { existing in
            let requested = recipe.changes.flatMap { change -> [MetadataChange] in
                let keys = isInfoKey(change.key) ? repeats[change.key] ?? [] : [change.key]
                return keys.filter(existing.contains).map {
                    MetadataChange(scope: .file, key: $0, value: change.value, original: change.original)
                }
            }
            return requested + staleChanges(in: existing, previewIsStale: false)
        }
    }

    /// For a PDF whose pages were rearranged: the packet stays, but for what
    /// no longer holds. One that can't be read may hold a picture of a page
    /// that's gone, so it goes with it.
    static func refreshPacket(of input: URL, in output: URL, previewIsStale: Bool) throws(ConversionError) {
        try updatePacket(of: input, in: output, wipingUnreadable: previewIsStale) { existing in
            staleChanges(in: existing, previewIsStale: previewIsStale)
        }
    }

    /// XMP names have a prefix, and the other two rows aren't fields of the file.
    private static func isNewInfoKey(_ key: String) -> Bool {
        !key.contains(":") && key != annotationAuthorsKey && key != unreadablePacketKey
    }

    private static func field(_ key: String, value: PDFInfo.Value, date: Date?) -> MetadataField {
        if let date, dateKeys.contains(key) {
            return MetadataField(scope: .file, key: key, value: date.formatted(.iso8601), access: .removable)
        }
        switch value {
        case .text(let text): return MetadataField(scope: .file, key: key, value: text)
        case .name(let text), .literal(let text): return MetadataField(scope: .file, key: key, value: text, access: .locked)
        case .unsupported: return MetadataField(scope: .file, key: key, value: "A list that can’t be shown here", access: .locked, isKept: false)
        }
    }

    private static func annotationFields(in document: PDFDocument) -> [MetadataField] {
        let pages = (0..<document.pageCount).compactMap(document.page(at:))
        let names = Set(pages.flatMap(\.annotations).compactMap(\.userName)).filter { !$0.isEmpty }
        guard !names.isEmpty else { return [] }
        return [MetadataField(scope: .file, key: annotationAuthorsKey, value: names.sorted().joined(separator: ", "), access: .removable)]
    }

    /// A packet ImageIO can't read still gets a row: it can't be kept in step
    /// with the fields, so it won't reach a copy.
    private static func packetFields(of url: URL, leavingOut repeated: Set<String>) -> [MetadataField] {
        guard let packet = PDFXMP.packet(of: url) else { return [] }
        guard let metadata = CGImageMetadataCreateFromXMPData(packet as CFData) else {
            return [MetadataField(scope: .file, key: unreadablePacketKey, value: "\(packet.count) bytes that can’t be read here",
                                  access: .locked, isKept: false)]
        }
        return ImageMetadata.fields(of: metadata).filter { !repeated.contains($0.key) }.map { field in
            guard field.key.hasPrefix(conformancePrefix) else { return field }
            return MetadataField(scope: .file, key: field.key, value: field.value, access: .locked, isKept: false)
        }
    }

    private static func staleChanges(in keys: Set<String>, previewIsStale: Bool) -> [MetadataChange] {
        keys.filter { $0.hasPrefix(conformancePrefix) || (previewIsStale && $0 == previewKey) }.map {
            MetadataChange(scope: .file, key: $0, value: nil, original: nil)
        }
    }

    /// Applies `changes`, worked out from the keys the packet has. A packet
    /// left with no fields is wiped, and one with no changes isn't touched.
    private static func updatePacket(of input: URL, in output: URL, wipingUnreadable: Bool,
                                     changes: (Set<String>) -> [MetadataChange]) throws(ConversionError) {
        guard let packet = PDFXMP.packet(of: input) else { return }
        guard let original = CGImageMetadataCreateFromXMPData(packet as CFData), let metadata = CGImageMetadataCreateMutableCopy(original) else {
            if wipingUnreadable { try PDFXMP.removeDocumentPacket(in: output) }
            return
        }
        let wanted = changes(Set(ImageMetadata.fields(of: original).map(\.key)))
        guard !wanted.isEmpty else { return }
        ImageMetadata.apply(wanted, to: metadata)
        if ImageMetadata.fields(of: metadata).isEmpty {
            try PDFXMP.removeDocumentPacket(in: output)
        } else if let updated = CGImageMetadataCreateXMPData(metadata, nil) {
            try PDFXMP.replace(in: output, with: updated as Data)
        }
    }
}
