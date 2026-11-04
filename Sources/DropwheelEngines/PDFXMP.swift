import CoreGraphics
import Foundation

/// The XMP packets in a PDF, which repeat its title and author and can hold
/// much more. PDFKit carries them through a save but can't change them.
enum PDFXMP {
    /// A deflate stream with nothing in it. Filling the rest with spaces keeps
    /// every offset in the file right, and readers stop at its end.
    private static let emptyDeflate = Data([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])
    private static let metadataMarker = Data("/Type /Metadata".utf8)

    private struct PacketStream {
        let content: Range<Int>
        let isCompressed: Bool
    }

    /// The document's own packet, uncompressed. Nil if it has none, or only
    /// the blank left by wiping one.
    static func packet(of url: URL) -> Data? {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        // The catalog and its stream belong to the document, and die with it.
        return withExtendedLifetime(document) { () -> Data? in
            var stream: CGPDFStreamRef?
            guard let catalog = document.catalog, CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return nil }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
            return data.allSatisfy { PDFPatch.isWhitespace($0) } ? nil : data
        }
    }

    /// Wipes every packet in the file, including those of pages and pictures.
    static func removeAll(in url: URL) throws(ConversionError) {
        var data = try PDFPatch.read(url)
        var position = data.startIndex
        var wiped = false
        while let marker = data.range(of: metadataMarker, in: position..<data.endIndex) {
            position = marker.upperBound
            if let stream = stream(from: marker.lowerBound, in: data) {
                blank(stream, in: &data)
                wiped = true
            }
        }
        if wiped {
            try PDFPatch.write(data, to: url)
        }
    }

    /// Wipes the document's packet, leaving those of pages and pictures.
    static func removeDocumentPacket(in url: URL) throws(ConversionError) {
        var data = try PDFPatch.read(url)
        let (_, stream) = try documentStream(in: data)
        blank(stream, in: &data)
        try PDFPatch.write(data, to: url)
    }

    /// Swaps the document's packet for `packet`. The old one is wiped, as an
    /// update alone would leave it in the file.
    static func replace(in url: URL, with packet: Data) throws(ConversionError) {
        var data = try PDFPatch.read(url)
        let (number, stream) = try documentStream(in: data)
        blank(stream, in: &data)
        let body = Data("<< /Type /Metadata /Subtype /XML /Length \(packet.count) >>\nstream\n".utf8) + packet + Data("\nendstream".utf8)
        try PDFPatch.append(number, body: body, to: &data)
        try PDFPatch.write(data, to: url)
    }

    /// The object number and stream of the packet the document's catalog names.
    private static func documentStream(in data: Data) throws(ConversionError) -> (number: Int, stream: PacketStream) {
        guard let root = PDFPatch.reference("/Root", in: data), let catalog = PDFPatch.objectBody(root, in: data),
              let reference = data.range(of: Data("/Metadata".utf8), in: catalog),
              let number = PDFPatch.integer(after: reference.upperBound, in: data),
              let object = PDFPatch.objectBody(number, in: data),
              let stream = stream(from: object.lowerBound, in: data) else {
            throw .writeFailed(PDFPatch.unusualFile)
        }
        return (number, stream)
    }

    /// The stream following the dictionary at or after `offset`.
    private static func stream(from offset: Int, in data: Data) -> PacketStream? {
        guard let closing = data.range(of: Data(">>".utf8), in: offset..<data.endIndex),
              let keyword = data.range(of: Data("stream".utf8), in: closing.upperBound..<data.endIndex),
              data[closing.upperBound..<keyword.lowerBound].allSatisfy({ PDFPatch.isWhitespace($0) }) else { return nil }
        var start = keyword.upperBound
        if start < data.endIndex, data[start] == UInt8(ascii: "\r") { start += 1 }
        if start < data.endIndex, data[start] == UInt8(ascii: "\n") { start += 1 }
        guard let end = data.range(of: Data("endstream".utf8), in: start..<data.endIndex) else { return nil }
        let isCompressed = data.range(of: Data("/Filter".utf8), in: offset..<closing.lowerBound) != nil
        return PacketStream(content: start..<end.lowerBound, isCompressed: isCompressed)
    }

    private static func blank(_ stream: PacketStream, in data: inout Data) {
        PDFPatch.blank(stream.content, in: &data)
        if stream.isCompressed, emptyDeflate.count <= stream.content.count {
            data.replaceSubrange(stream.content.lowerBound..<stream.content.lowerBound + emptyDeflate.count, with: emptyDeflate)
        }
    }
}
