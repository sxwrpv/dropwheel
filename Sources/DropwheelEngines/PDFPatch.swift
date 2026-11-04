import Foundation

/// Small changes to a PDF that PDFKit has just written, for what PDFKit can't
/// do itself. Its files are always plain objects with a classic
/// cross-reference table, whatever the original looked like.
enum PDFPatch {
    static let unusualFile = "The PDF’s structure is unusual, so its document details couldn’t be updated."
    /// Each line of a cross-reference table, and where its in-use flag sits.
    private static let tableEntrySize = 20
    private static let tableEntryFlag = 17

    static func read(_ url: URL) throws(ConversionError) -> Data {
        guard let data = try? Data(contentsOf: url) else { throw .unreadableInput(url.lastPathComponent) }
        return data
    }

    static func write(_ data: Data, to url: URL) throws(ConversionError) {
        do {
            try data.write(to: url)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    /// The object the last trailer names under `key`, such as "/Info".
    static func reference(_ key: String, in data: Data) -> Int? {
        guard let dictionary = trailer(in: data)?.dictionary, let name = dictionary.range(of: key + " ") else { return nil }
        return Int(dictionary[name.upperBound...].drop(while: \.isWhitespace).prefix(while: \.isNumber))
    }

    /// The bytes between an object's `obj` and `endobj`, in its latest version.
    /// PDFKit puts `endobj` on its own line, which a string can't fool.
    static func objectBody(_ number: Int, in data: Data) -> Range<Int>? {
        guard let offset = objectOffset(number, in: data),
              let start = data.range(of: Data("obj".utf8), in: offset..<data.endIndex),
              let end = data.range(of: Data("\nendobj".utf8), in: start.upperBound..<data.endIndex) else { return nil }
        return start.upperBound..<end.lowerBound
    }

    /// Adds `body` as a new version of the object, in an update at the end
    /// of the file, which is how a PDF changes without moving what's in it.
    static func append(_ number: Int, body: Data, to data: inout Data) throws(ConversionError) {
        guard let trailer = trailer(in: data) else { throw .writeFailed(unusualFile) }
        let object = Data("\(number) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8)
        let objectOffset = data.endIndex
        let tableOffset = objectOffset + object.count
        let dictionary = trailer.dictionary.replacingOccurrences(of: #"\s*/Prev \d+"#, with: "", options: .regularExpression)
        let entry = String(format: "%010ld 00000 n \n", objectOffset)
        let table = "xref\n\(number) 1\n\(entry)trailer\n\(dictionary) /Prev \(trailer.previous) >>\nstartxref\n\(tableOffset)\n%%EOF\n"
        guard let bytes = table.data(using: .isoLatin1) else { throw .writeFailed(unusualFile) }
        data += object + bytes
    }

    /// Overwrites bytes with spaces, which keeps every offset in the file right.
    static func blank(_ range: Range<Int>, in data: inout Data) {
        data.replaceSubrange(range, with: Data(repeating: UInt8(ascii: " "), count: range.count))
    }

    /// The whole number at `offset`, skipping any white space before it.
    static func integer(after offset: Int, in data: Data) -> Int? {
        let digits = data[offset...].drop { isWhitespace($0) }.prefix { (48...57).contains($0) }
        return digits.isEmpty ? nil : Int(String(decoding: digits, as: UTF8.self))
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    /// Where an object starts, from the cross-reference tables, newest first,
    /// as a stream could hold anything that looks like one.
    private static func objectOffset(_ number: Int, in data: Data) -> Int? {
        var table = trailer(in: data)?.previous
        var visited = Set<Int>()
        while let start = table, visited.insert(start).inserted {
            var cursor = start + "xref".utf8.count
            while let first = nextInteger(at: &cursor, in: data), let count = nextInteger(at: &cursor, in: data) {
                let entries = data[cursor...].firstIndex { !isWhitespace($0) } ?? data.endIndex
                if number >= first, number - first < count {
                    let entry = entries + (number - first) * tableEntrySize
                    guard data.endIndex - entry >= tableEntrySize, data[entry + tableEntryFlag] == UInt8(ascii: "n") else { return nil }
                    return integer(after: entry, in: data)
                }
                guard count <= (data.endIndex - entries) / tableEntrySize else { return nil }
                cursor = entries + count * tableEntrySize
            }
            table = previousTable(after: cursor, in: data)
        }
        return nil
    }

    private static func nextInteger(at cursor: inout Int, in data: Data) -> Int? {
        cursor = data[cursor...].firstIndex { !isWhitespace($0) } ?? data.endIndex
        let end = data[cursor...].firstIndex { !(48...57).contains($0) } ?? data.endIndex
        defer { cursor = end }
        return end > cursor ? Int(String(decoding: data[cursor..<end], as: UTF8.self)) : nil
    }

    /// The `/Prev` of the trailer at or after `offset`, if it has one.
    private static func previousTable(after offset: Int, in data: Data) -> Int? {
        guard let end = data.range(of: Data("startxref".utf8), in: offset..<data.endIndex),
              let key = data.range(of: Data("/Prev".utf8), in: offset..<end.lowerBound),
              let previous = integer(after: key.upperBound, in: data), previous < data.endIndex else { return nil }
        return previous
    }

    /// The contents of the last trailer's dictionary, and where the
    /// cross-reference table it belongs to starts.
    private static func trailer(in data: Data) -> (dictionary: String, previous: Int)? {
        guard let keyword = data.range(of: Data("trailer".utf8), options: .backwards),
              let closing = data.range(of: Data(">>".utf8), options: .backwards, in: keyword.upperBound..<data.endIndex),
              let marker = data.range(of: Data("startxref".utf8), options: .backwards),
              let previous = integer(after: marker.upperBound, in: data), previous < data.endIndex,
              data[previous...].starts(with: Data("xref".utf8)),
              let dictionary = String(data: data[keyword.upperBound..<closing.lowerBound], encoding: .isoLatin1) else { return nil }
        return (dictionary, previous)
    }
}
