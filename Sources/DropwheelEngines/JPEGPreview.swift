import Foundation

/// Takes the small preview out of a JPEG's EXIF block. It can show the photo
/// as it once was, perhaps before it was cropped, and ImageIO copies it along
/// with everything else. It is wiped where it lies, so nothing else moves.
enum JPEGPreview {
    private static let startOfImage = Data([0xFF, 0xD8])
    private static let exifHeader = Data("Exif\0\0".utf8)
    private static let segmentMarker: UInt8 = 0xFF
    private static let startOfScan: UInt8 = 0xDA
    private static let app1: UInt8 = 0xE1
    private static let entrySize = 12
    /// A count of entries before them, and a link to the next table after.
    private static let tableOverhead = 6
    private static let shortType = 3
    /// Tags saying where a preview's bytes are and how many: as a JPEG, or as a TIFF strip.
    private static let locationTags = [(offset: 0x0201, length: 0x0202), (offset: 0x0111, length: 0x0117)]

    static func remove(from url: URL) throws(ConversionError) {
        guard var data = try? Data(contentsOf: url), let exif = exifBlock(in: data),
              let wiped = wipes(in: TIFFBlock(data: data, range: exif)) else { return }
        wiped.forEach { data.resetBytes(in: (exif.lowerBound + $0.lowerBound)..<(exif.lowerBound + $0.upperBound)) }
        do {
            try data.write(to: url)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    /// The EXIF block's bytes, from the segments before the picture.
    private static func exifBlock(in data: Data) -> Range<Int>? {
        guard data.starts(with: startOfImage) else { return nil }
        var offset = data.startIndex + startOfImage.count
        while data.endIndex - offset >= 4, data[offset] == segmentMarker, data[offset + 1] != startOfScan {
            let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let end = offset + 2 + length
            guard length >= 2, end <= data.endIndex else { return nil }
            let body = (offset + 4)..<end
            if data[offset + 1] == app1, data[body].starts(with: exifHeader) {
                return (body.lowerBound + exifHeader.count)..<end
            }
            offset = end
        }
        return nil
    }

    /// What to wipe, within the block: the second table, which only describes
    /// the preview, what it points at, and the link to it. Nil if there is no
    /// such table, or it makes no sense.
    private static func wipes(in block: TIFFBlock) -> [Range<Int>]? {
        guard let first = block.uint32(at: 4), let entries = block.uint16(at: first) else { return nil }
        let link = first + 2 + entries * entrySize
        guard let second = block.uint32(at: link), second != 0, let count = block.uint16(at: second) else { return nil }
        let table = second..<(second + tableOverhead + count * entrySize)
        guard table.upperBound <= block.count else { return nil }

        var values: [Int: Int] = [:]
        for entry in (0..<count).map({ second + 2 + $0 * entrySize }) {
            guard let tag = block.uint16(at: entry), let type = block.uint16(at: entry + 2) else { return nil }
            values[tag] = type == shortType ? block.uint16(at: entry + 8) : block.uint32(at: entry + 8)
        }
        let preview = locationTags.compactMap { tags -> Range<Int>? in
            guard let offset = values[tags.offset], let length = values[tags.length], offset <= block.count,
                  length <= block.count - offset else { return nil }
            return offset..<(offset + length)
        }
        return preview + [table, link..<(link + 4)]
    }
}

/// Numbers in the TIFF structure of an EXIF block, read by their offset in it.
private struct TIFFBlock {
    let data: Data
    let range: Range<Int>

    var count: Int { range.count }

    private var isLittleEndian: Bool {
        data[range].starts(with: Data("II".utf8))
    }

    func uint16(at offset: Int) -> Int? {
        bytes(at: offset, count: 2)
    }

    func uint32(at offset: Int) -> Int? {
        bytes(at: offset, count: 4)
    }

    private func bytes(at offset: Int, count: Int) -> Int? {
        guard offset >= 0, offset <= range.count - count else { return nil }
        let bytes = data[(range.lowerBound + offset)..<(range.lowerBound + offset + count)]
        return (isLittleEndian ? Array(bytes.reversed()) : Array(bytes)).reduce(0) { $0 << 8 | Int($1) }
    }
}
