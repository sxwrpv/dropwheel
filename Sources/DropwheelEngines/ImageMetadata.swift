import CoreGraphics
import DropwheelCore
import Foundation
import ImageIO

/// Reads and rewrites a picture's fields through ImageIO, which presents EXIF,
/// IPTC, GPS and XMP as one list and keeps them in step when saving.
enum ImageMetadata {
    /// Formats ImageIO can copy with new metadata and without decoding the
    /// picture. Its copy ignores removals in PNG and TIFF, which are lossless
    /// to rewrite anyway.
    private static let copiedFormats: Set<FileFormat> = [.jpg, .heic]
    /// For formats that have to be re-encoded: a small change would otherwise
    /// cost a generation of quality.
    private static let rewriteQuality = 0.95

    static func report(of url: URL, format: FileFormat) throws(ConversionError) -> MetadataReport {
        try ImageTools.requireSingleFrame(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw .unreadableInput(url.lastPathComponent) }
        let fields = CGImageSourceCopyMetadataAtIndex(source, 0, nil).map(Self.fields) ?? []
        let all = fields + (format == .png ? chunkFields(of: url) : [])
        return MetadataReport(groups: [MetadataGroup(scope: .file, title: "File", fields: MetadataField.sorted(all))])
    }

    /// One field per tag, leaving out ImageIO's own bookkeeping.
    static func fields(of metadata: CGImageMetadata) -> [MetadataField] {
        tags(of: metadata).compactMap { tag in
            guard let key = key(of: tag) else { return nil }
            let access = MetadataRules.access(forKey: key, scope: .file)
            return MetadataField(scope: .file, key: key, value: text(of: tag, key: key),
                                 access: access == .editable && !isPlainText(tag) ? .removable : access)
        }
    }

    /// Changes `metadata` itself. A field is removed before it is set, as
    /// ImageIO empties a language-tagged field that is written over.
    static func apply(_ changes: [MetadataChange], to metadata: CGMutableImageMetadata) {
        for change in changes {
            let path = change.key as CFString
            let existing = CGImageMetadataCopyTagWithPath(metadata, nil, path)
            let kind = existing.map(valueKind) ?? MetadataRules.valueKind(of: change.key)
            CGImageMetadataRemoveTagWithPath(metadata, nil, path)
            guard let value = change.value else { continue }
            switch kind {
            case .text: CGImageMetadataSetValueWithPath(metadata, nil, path, value as CFString)
            case .languageTagged: CGImageMetadataSetValueWithPath(metadata, nil, "\(change.key)[x-default]" as CFString, value as CFString)
            case .orderedList: setList(value, key: change.key, type: .arrayOrdered, replacing: existing, in: metadata)
            case .unorderedList: setList(value, key: change.key, type: .arrayUnordered, replacing: existing, in: metadata)
            }
        }
    }

    static func edit(_ input: URL, format: FileFormat, recipe: MetadataRecipe, output: URL) async throws(ConversionError) {
        try ImageTools.requireSingleFrame(input)
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw .unreadableInput(input.lastPathComponent) }
        let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let metadata = original.flatMap(CGImageMetadataCreateMutableCopy) ?? CGImageMetadataCreateMutable()
        apply(recipe.changes.filter { !$0.key.hasPrefix(PNGChunks.keyPrefix) }, to: metadata)

        if format == .webp {
            try await writeWebP(input, metadata: metadata, output: output)
        } else if copiedFormats.contains(format), copy(source, metadata: metadata, to: output) {
            if format == .jpg { try JPEGPreview.remove(from: output) }
        } else {
            try? FileManager.default.removeItem(at: output)
            try rewrite(source, metadata: metadata, to: output)
        }
        if format == .png {
            let removed = Set(recipe.changes.filter { $0.value == nil }.map(\.key))
            try PNGChunks.insert(PNGChunks.extras(of: input).filter { !removed.contains($0.key) }, into: output)
        }
    }

    /// A chunk name can repeat, but a field shows once.
    private static func chunkFields(of url: URL) -> [MetadataField] {
        var seen = Set<String>()
        return PNGChunks.extras(of: url).filter { seen.insert($0.key).inserted }.map {
            MetadataField(scope: .file, key: $0.key, value: $0.text, access: .removable)
        }
    }

    private static func valueKind(of tag: CGImageMetadataTag) -> MetadataValueKind {
        switch CGImageMetadataTagGetType(tag) {
        case .alternateText: .languageTagged
        case .arrayOrdered: .orderedList
        case .arrayUnordered: .unorderedList
        default: .text
        }
    }

    private static func setList(_ value: String, key: String, type: CGImageMetadataType, replacing existing: CGImageMetadataTag?,
                                in metadata: CGMutableImageMetadata) {
        let name = key.split(separator: ":", maxSplits: 1).map(String.init)
        let namespace = existing.flatMap(CGImageMetadataTagCopyNamespace) ?? kCGImageMetadataNamespaceDublinCore
        let items = value.split(separator: MetadataRules.listSeparator(for: key)).map { $0.trimmingCharacters(in: .whitespaces) }
        guard name.count == 2,
              let tag = CGImageMetadataTagCreate(namespace, name[0] as CFString, name[1] as CFString, type, items as CFArray) else { return }
        CGImageMetadataSetTagWithPath(metadata, nil, key as CFString, tag)
    }

    /// Lists of structures, such as an edit history, can't be typed as text.
    private static func isPlainText(_ tag: CGImageMetadataTag) -> Bool {
        let type = CGImageMetadataTagGetType(tag)
        guard type != .structure, type != .alternateArray else { return false }
        let items = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] ?? []
        return !items.contains { CGImageMetadataTagGetType($0) == .structure }
    }

    private static func copy(_ source: CGImageSource, metadata: CGImageMetadata, to output: URL) -> Bool {
        guard let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else { return false }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false]
        return CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil)
    }

    private static func rewrite(_ source: CGImageSource, metadata: CGImageMetadata, to output: URL) throws(ConversionError) {
        guard let type = CGImageSourceGetType(source), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw .writeFailed("The picture couldn’t be rewritten.")
        }
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, rewriteOptions(for: source) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .writeFailed("The image encoder failed.") }
    }

    /// What a rewrite would otherwise reset, as it isn't taken from the metadata.
    private static func rewriteOptions(for source: CGImageSource) -> [CFString: Any] {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: rewriteQuality]
        options[kCGImagePropertyDPIWidth] = properties[kCGImagePropertyDPIWidth]
        options[kCGImagePropertyDPIHeight] = properties[kCGImagePropertyDPIHeight]
        options[kCGImagePropertyOrientation] = properties[kCGImagePropertyOrientation]
        return options
    }

    /// ImageIO can't write WebP, and cwebp would re-encode it. `webpmux`
    /// swaps the metadata chunks: EXIF goes, as an XMP packet holds it all.
    private static func writeWebP(_ input: URL, metadata: CGImageMetadata, output: URL) async throws(ConversionError) {
        let webpmux = try ToolLocator.require(.webpmux)
        let scratch = try ScratchSpace.make(near: input)
        defer { ScratchSpace.discard(scratch) }
        let stripped = scratch.appendingPathComponent("stripped.webp")
        try await strip("exif", from: input, to: stripped, webpmux: webpmux)
        guard !tags(of: metadata).isEmpty, let packet = CGImageMetadataCreateXMPData(metadata, nil) else {
            try await strip("xmp", from: stripped, to: output, webpmux: webpmux)
            return
        }
        let packetFile = scratch.appendingPathComponent("packet.xmp")
        do {
            try (packet as Data).write(to: packetFile)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        try await ProcessRunner.run(webpmux, arguments: ["-set", "xmp", packetFile.path, stripped.path, "-o", output.path])
    }

    /// webpmux reports a chunk that isn't there as a failure.
    private static func strip(_ chunk: String, from input: URL, to output: URL, webpmux: URL) async throws(ConversionError) {
        do {
            try await ProcessRunner.run(webpmux, arguments: ["-strip", chunk, input.path, "-o", output.path])
        } catch .toolFailed(_, let message) where message.contains("WEBP_MUX_NOT_FOUND") {
            do {
                try FileManager.default.copyItem(at: input, to: output)
            } catch {
                throw .writeFailed(error.localizedDescription)
            }
        }
    }

    private static func tags(of metadata: CGImageMetadata) -> [CGImageMetadataTag] {
        (CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] ?? []).filter { key(of: $0) != nil }
    }

    private static func key(of tag: CGImageMetadataTag) -> String? {
        guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, let name = CGImageMetadataTagCopyName(tag) as String?,
              prefix != "iio" else { return nil }
        return "\(prefix):\(name)"
    }

    private static func text(of tag: CGImageMetadataTag, key: String) -> String {
        text(of: CGImageMetadataTagCopyValue(tag), separator: "\(MetadataRules.listSeparator(for: key)) ")
    }

    /// Lists are joined by `separator`; structures show as "name: value".
    private static func text(of value: AnyObject?, separator: String) -> String {
        switch value {
        case let list as [AnyObject]:
            return list.map { text(of: $0, separator: separator) }.joined(separator: separator)
        case let structure as [String: AnyObject]:
            return structure.sorted { $0.key < $1.key }.map { "\($0.key): \(text(of: $0.value, separator: separator))" }.joined(separator: ", ")
        case let object?:
            if CFGetTypeID(object) == CGImageMetadataTagGetTypeID() {
                // swiftlint:disable:next force_cast
                return text(of: CGImageMetadataTagCopyValue(object as! CGImageMetadataTag), separator: separator)
            }
            return "\(object)"
        case nil:
            return ""
        }
    }
}
