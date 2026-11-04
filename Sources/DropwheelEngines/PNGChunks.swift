import Compression
import Foundation

/// PNG chunks ImageIO neither shows nor writes back: text under names of its
/// own, such as image generators leave, and the time of the last change.
enum PNGChunks {
    static let keyPrefix = "png:"
    private static let timeKey = "png:tIME"
    private static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    /// Length and type before a chunk's body, and a checksum after it.
    private static let headerSize = 8
    private static let checksumSize = 4
    private static let timeSize = 7
    /// All that is shown of any text. A small chunk can expand enormously.
    private static let maximumText = 64_000
    /// Text ImageIO reads into its own fields, and writes back from them.
    private static let mappedKeywords: Set<String> = ["Title", "Author", "Description", "Copyright", "Comment", "Software",
                                                      "XML:com.adobe.xmp"]

    struct Chunk {
        let key: String
        let text: String
        /// The whole chunk, ready to go back into a file.
        let bytes: Data
    }

    private struct RawChunk {
        let type: String
        let whole: Range<Int>
        let body: Data
    }

    static func extras(of url: URL) -> [Chunk] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return rawChunks(in: data).compactMap { chunk in
            guard let (key, text) = field(for: chunk) else { return nil }
            return Chunk(key: key, text: text, bytes: Data(data[chunk.whole]))
        }
    }

    /// Adds chunks before the one that ends the file.
    static func insert(_ chunks: [Chunk], into url: URL) throws(ConversionError) {
        guard !chunks.isEmpty else { return }
        guard let data = try? Data(contentsOf: url), let end = rawChunks(in: data).last(where: { $0.type == "IEND" }) else {
            throw .writeFailed("The picture couldn’t be rewritten.")
        }
        let added = chunks.reduce(Data()) { $0 + $1.bytes }
        do {
            try (data[..<end.whole.lowerBound] + added + data[end.whole.lowerBound...]).write(to: url)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    private static func rawChunks(in data: Data) -> [RawChunk] {
        guard data.starts(with: signature) else { return [] }
        var chunks: [RawChunk] = []
        var offset = data.startIndex + signature.count
        while offset + headerSize + checksumSize <= data.endIndex {
            let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let bodyStart = offset + headerSize
            guard length <= data.endIndex - bodyStart - checksumSize else { break }
            let end = bodyStart + length + checksumSize
            let type = String(decoding: data[offset + 4..<bodyStart], as: UTF8.self)
            chunks.append(RawChunk(type: type, whole: offset..<end, body: Data(data[bodyStart..<bodyStart + length])))
            offset = end
        }
        return chunks
    }

    private static func field(for chunk: RawChunk) -> (key: String, text: String)? {
        if chunk.type == "tIME" { return time(in: chunk.body).map { (timeKey, $0) } }
        guard ["tEXt", "zTXt", "iTXt"].contains(chunk.type), let split = chunk.body.firstIndex(of: 0) else { return nil }
        let keyword = String(decoding: chunk.body[..<split], as: UTF8.self)
        guard !mappedKeywords.contains(keyword) else { return nil }
        let rest = chunk.body[(split + 1)...]
        let text = switch chunk.type {
        case "tEXt": String(data: rest.prefix(maximumText), encoding: .isoLatin1)
        case "zTXt": inflated(rest.dropFirst()).flatMap { String(data: $0, encoding: .isoLatin1) }
        default: internationalText(rest)
        }
        return (keyPrefix + keyword, text ?? "\(rest.count) compressed bytes")
    }

    /// Two flags, then a language and a translated keyword, each ending in a zero.
    private static func internationalText(_ body: Data) -> String? {
        guard body.count > 2, let language = body.dropFirst(2).firstIndex(of: 0),
              let translated = body[(language + 1)...].firstIndex(of: 0) else { return nil }
        let text = body[(translated + 1)...]
        return (body.first == 0 ? Data(text.prefix(maximumText)) : inflated(text)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// PNG holds zlib streams, and the framework takes the raw deflate inside
    /// one. It stops when the output is full.
    private static func inflated(_ stream: Data) -> Data? {
        guard stream.count > 6 else { return nil }
        let deflated = Data(stream.dropFirst(2).dropLast(4))
        var output = Data(count: maximumText)
        let written = output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
            deflated.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let to = target.bindMemory(to: UInt8.self).baseAddress,
                      let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(to, target.count, from, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written > 0 ? output.prefix(written) : nil
    }

    private static func time(in body: Data) -> String? {
        guard body.count == timeSize else { return nil }
        let bytes = Array(body)
        let year = Int(bytes[0]) << 8 | Int(bytes[1])
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, bytes[2], bytes[3], bytes[4], bytes[5], bytes[6])
    }
}
