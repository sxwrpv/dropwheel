import DropwheelCore
import Foundation

extension MediaPreview {
    /// What a file holds, for the editor.
    public static func metadata(of url: URL) async throws(ConversionError) -> MetadataReport {
        guard let format = FileFormat(fileName: url.lastPathComponent) else { throw .unreadableInput(url.lastPathComponent) }
        switch format.family {
        case .image: return try ImageMetadata.report(of: url, format: format)
        case .pdf: return try PDFMetadata.report(of: url)
        default: return try await MediaMetadata.report(of: url, format: format)
        }
    }
}

extension MediaPreview {
    /// What a saved copy of this file won't carry, as a sentence for its editor.
    public static func copyWarning(for url: URL) async -> String? {
        switch FileFormat(fileName: url.lastPathComponent) {
        case .pdf: PDFTools.isEncrypted(url) ? "This PDF is protected against changes, so its details can only be read."
            : PDFStructure.warning(for: PDFStructure.partsNotKept(in: url))
        case .mp3: "A saved copy rewrites the ID3 tag: lyrics become plain text, and ratings, play counts and attached files aren’t kept."
        default: nil
        }
    }
}

/// Edit Metadata: every family's way of saving a copy with changed fields,
/// and a check that the copy really shows them.
enum MetadataTools {
    static func edit(_ input: URL, format: FileFormat, recipe: MetadataRecipe, output: URL,
                     progress: @escaping ProgressHandler) async throws(ConversionError) {
        let report: MetadataReport
        let saved: MetadataReport
        switch format.family {
        case .image:
            report = try ImageMetadata.report(of: input, format: format)
            try await ImageMetadata.edit(input, format: format, recipe: recipe, output: output)
            saved = try ImageMetadata.report(of: output, format: format)
        case .pdf:
            report = try PDFMetadata.report(of: input)
            try PDFMetadata.edit(input, recipe: recipe, output: output)
            saved = try PDFMetadata.report(of: output)
        default:
            report = try await FFmpegRunner.probeMetadata(input)
            try await MediaMetadata.edit(input, format: format, recipe: recipe, report: report, output: output, progress: progress)
            saved = try await FFmpegRunner.probeMetadata(output)
        }
        if let missed = MetadataPlans.missedChange(in: recipe, saved: saved, report: report) {
            let field = MetadataRules.label(for: missed.key)
            throw missed.value == nil ? .metadataNotRemoved(field: field, input: input.lastPathComponent)
                : .metadataNotSaved(field: field, input: input.lastPathComponent)
        }
    }
}

/// Audio and video, through ffmpeg stream copies.
enum MediaMetadata {
    /// Long enough to reach every track, short enough to take no time.
    private static let trialSeconds = "1"

    /// The file's tags, with those a copy couldn't keep marked. Rather than
    /// guess each muxer's limits, a moment of the file is saved the way a
    /// real copy would be and read back. If that fails, the save will say why.
    static func report(of url: URL, format: FileFormat) async throws(ConversionError) -> MetadataReport {
        let report = try await FFmpegRunner.probeMetadata(url)
        let trial = MediaPreview.temporaryFile(extension: format.preferredExtension)
        defer { MediaPreview.discardTemporaryFile(trial) }
        let ffmpeg = try ToolLocator.require(.ffmpeg)
        let options = MetadataPlans.options(MetadataRecipe(changes: []), report: report, format: format)
        do {
            try await ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-v", "error", "-i", url.path] + options
                + ["-map_metadata", "0", "-t", trialSeconds, "-y", trial.path])
            return report.markingLostFields(comparedTo: try await FFmpegRunner.probeMetadata(trial))
        } catch .cancelled {
            throw .cancelled
        } catch {
            return report
        }
    }

    static func edit(_ input: URL, format: FileFormat, recipe: MetadataRecipe, report: MetadataReport, output: URL,
                     progress: @escaping ProgressHandler) async throws(ConversionError) {
        let duration = (try? await FFmpegRunner.probe(input))?.durationSeconds
        let options = MetadataPlans.options(recipe, report: report, format: format)
        let arguments = FFmpegArguments.command(input: input.path, options: options, output: output.path)
        try await FFmpegRunner.run(arguments, expectedSeconds: duration, progress: progress)
        let items = MetadataPlans.quickTimeItems(recipe, report: report, stored: QuickTimeFile.items(of: input), format: format)
        if !items.isEmpty {
            try QuickTimeFile.append(items, to: output)
        }
    }
}

/// Reads and adds QuickTime keys, in the `moov/meta` atom Apple's frameworks
/// read. ffmpeg can only keep them under `udta`, where only ffmpeg sees them.
enum QuickTimeFile {
    private static let compactHeader: UInt64 = 8
    private static let wideHeader: UInt64 = 16
    private static let unusualFile = "The movie’s structure is unusual, so its camera fields couldn’t be kept."

    private struct Atom {
        let offset: UInt64
        let size: UInt64
        let headerSize: UInt64
        let type: String
    }

    /// The file's items, in order and as stored. ffprobe would only give
    /// them as text. Empty if there are none, or the file isn't a movie.
    static func items(of url: URL) -> [QuickTimeItem] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), let atoms = try? atoms(in: handle, end: end),
              let movie = atoms.first(where: { $0.type == "moov" }),
              (try? handle.seek(toOffset: movie.offset + movie.headerSize)) != nil,
              let body = try? handle.read(upToCount: Int(movie.size - movie.headerSize)) else { return [] }
        let children = children(of: body)
        guard let meta = child("meta", in: children) ?? child("udta", in: children).flatMap({ child("meta", in: self.children(of: $0)) }) else {
            return []
        }
        // Unlike the ISO atom of the same name, QuickTime's has no version field.
        let direct = self.children(of: meta)
        let parts = child("keys", in: direct) != nil ? direct : self.children(of: Data(meta.dropFirst(4)))
        guard let keys = child("keys", in: parts), let list = child("ilst", in: parts) else { return [] }
        let names = keyNames(in: keys)
        return self.children(of: list).compactMap { item in
            let index = Int(bigEndian(item.type)) - 1
            guard names.indices.contains(index), let value = child("data", in: self.children(of: item.body)), value.count >= 8 else { return nil }
            return QuickTimeItem(key: names[index], data: Data(value.dropFirst(8)), type: UInt32(bigEndian(value.prefix(4))),
                                 locale: UInt32(bigEndian(value.dropFirst(4).prefix(4))))
        }
    }

    /// ffmpeg writes `moov` last, so the file only needs to grow at the end
    /// and nothing that points into the media moves.
    static func append(_ items: [QuickTimeItem], to url: URL) throws(ConversionError) {
        do {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            let atom = QuickTimeAtoms.metadata(items)
            guard let movie = try atoms(in: handle, end: end).last, movie.type == "moov", movie.headerSize == compactHeader,
                  movie.offset + movie.size == end, movie.size + UInt64(atom.count) <= UInt64(UInt32.max) else {
                throw ConversionError.writeFailed(unusualFile)
            }
            try handle.seek(toOffset: end)
            try handle.write(contentsOf: atom)
            try handle.seek(toOffset: movie.offset)
            try handle.write(contentsOf: withUnsafeBytes(of: UInt32(movie.size + UInt64(atom.count)).bigEndian) { Data($0) })
        } catch let error as ConversionError {
            throw error
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    /// The top-level atoms, as far as they make sense. A size of 1 means a
    /// 64-bit size follows, as with media over 4 GiB; 0 means "to the end".
    private static func atoms(in handle: FileHandle, end: UInt64) throws -> [Atom] {
        var found: [Atom] = []
        var offset: UInt64 = 0
        while end >= compactHeader, offset <= end - compactHeader {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: Int(wideHeader)), header.count >= Int(compactHeader) else { break }
            var size = bigEndian(header.prefix(4))
            var headerSize = compactHeader
            if size == 1 {
                guard header.count == Int(wideHeader) else { break }
                size = bigEndian(header.dropFirst(8))
                headerSize = wideHeader
            } else if size == 0 {
                size = end - offset
            }
            guard size >= headerSize, size <= end - offset else { break }
            found.append(Atom(offset: offset, size: size, headerSize: headerSize,
                              type: String(decoding: header.dropFirst(4).prefix(4), as: UTF8.self)))
            offset += size
        }
        return found
    }

    /// The atoms directly inside another's body.
    private static func children(of data: Data) -> [(type: Data, body: Data)] {
        var found: [(type: Data, body: Data)] = []
        var offset = data.startIndex
        while data.endIndex - offset >= Int(compactHeader) {
            let size = Int(bigEndian(data[offset..<offset + 4]))
            guard size >= Int(compactHeader), size <= data.endIndex - offset else { break }
            found.append((Data(data[offset + 4..<offset + 8]), Data(data[offset + Int(compactHeader)..<offset + size])))
            offset += size
        }
        return found
    }

    private static func child(_ type: String, in atoms: [(type: Data, body: Data)]) -> Data? {
        atoms.first { $0.type == Data(type.utf8) }?.body
    }

    /// After a version and a count, each key is a size, a namespace and its name.
    private static func keyNames(in atom: Data) -> [String] {
        var names: [String] = []
        var offset = atom.startIndex + 8
        while atom.endIndex - offset >= Int(compactHeader) {
            let size = Int(bigEndian(atom[offset..<offset + 4]))
            guard size >= Int(compactHeader), size <= atom.endIndex - offset else { break }
            names.append(String(decoding: atom[offset + Int(compactHeader)..<offset + size], as: UTF8.self))
            offset += size
        }
        return names
    }

    private static func bigEndian(_ bytes: Data) -> UInt64 {
        bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }
}
