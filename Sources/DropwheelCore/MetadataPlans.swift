import Foundation

extension MetadataReport {
    private static let blankVendor = "[0][0][0][0]"
    /// Data tracks a muxer builds again from the chapters and the timecode.
    private static let rebuiltTracks: Set<String> = ["text", "tmcd"]

    /// Reads `ffprobe -show_format -show_streams -show_chapters` output.
    public static func parse(ffprobeJSON data: Data) -> MetadataReport? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let streams = root["streams"] as? [[String: Any]] ?? []
        let chapters = root["chapters"] as? [[String: Any]] ?? []
        let formatTags = (root["format"] as? [String: Any])?["tags"]
        let file = MetadataGroup(scope: .file, title: "File", fields: fields(formatTags, scope: .file, isKept: true))

        let tracks = streams.compactMap { stream -> MetadataGroup? in
            guard let index = stream["index"] as? Int else { return nil }
            let isData = isDataTrack(stream)
            if isData, rebuiltTracks.contains(stream["codec_tag_string"] as? String ?? "") { return nil }
            return MetadataGroup(scope: .track(index), title: trackTitle(stream, index: index),
                                 fields: fields(stream["tags"], scope: .track(index), isKept: !isData), isKept: !isData)
        }
        let chapterGroups = chapters.enumerated().map { index, chapter in
            MetadataGroup(scope: .chapter(index), title: chapterTitle(chapter, index: index),
                          fields: fields(chapter["tags"], scope: .chapter(index), isKept: true))
        }
        let kept = streams.filter { !isDataTrack($0) }.compactMap { $0["index"] as? Int }
        return MetadataReport(groups: [file] + tracks + chapterGroups, keptTracks: kept)
    }

    private static func isDataTrack(_ stream: [String: Any]) -> Bool {
        stream["codec_type"] as? String == "data"
    }

    private static func fields(_ tags: Any?, scope: MetadataScope, isKept: Bool) -> [MetadataField] {
        let values = (tags as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        return MetadataField.sorted(values.filter { $0.value != blankVendor }.map { key, value in
            MetadataField(scope: scope, key: key, value: value, access: MetadataRules.access(forKey: key, scope: scope), isKept: isKept)
        })
    }

    private static func trackTitle(_ stream: [String: Any], index: Int) -> String {
        let isCoverArt = (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1
        let kind = isCoverArt ? "Cover Art" : (stream["codec_type"] as? String ?? "Track").capitalized
        let codec = stream["codec_name"] as? String ?? stream["codec_tag_string"] as? String
        let note = isDataTrack(stream) ? ["not kept in a copy"] : []
        return (["Track \(index + 1)", kind] + (codec.map { [$0.uppercased()] } ?? []) + note).joined(separator: " · ")
    }

    private static func chapterTitle(_ chapter: [String: Any], index: Int) -> String {
        let time: (String) -> String = { key in
            Timecode.string(from: (chapter[key] as? String).flatMap(Double.init) ?? 0)
        }
        return "Chapter \(index + 1) · \(time("start_time"))–\(time("end_time"))"
    }
}

/// A key and value for a QuickTime `meta` atom.
public struct QuickTimeItem: Equatable, Sendable {
    private static let utf8Type: UInt32 = 1

    public let key: String
    /// The value as stored, which `type` says how to read: text, or a number
    /// that ffprobe would only report as text.
    public let data: Data
    public let type: UInt32
    public let locale: UInt32

    public init(key: String, data: Data, type: UInt32, locale: UInt32 = 0) {
        self.key = key
        self.data = data
        self.type = type
        self.locale = locale
    }

    public init(key: String, value: String) {
        self.init(key: key, data: Data(value.utf8), type: Self.utf8Type)
    }
}

/// How an edit of a media file's fields is carried out and checked.
public enum MetadataPlans {
    private static let quickTimeFormats: Set<FileFormat> = [.mp4, .mov, .m4a]

    /// A stream copy with the changes applied. Data tracks are left out, as
    /// muxers refuse many of them, and `+bitexact` stops ffmpeg signing the
    /// file with its own encoder name.
    public static func options(_ recipe: MetadataRecipe, report: MetadataReport, format: FileFormat) -> [String] {
        let changes = recipe.changes.filter { !usesAtom($0.key, format: format) }.flatMap { change in
            [specifier(for: change.scope, report: report), "\(storedKey(for: change, format: format))=\(change.value ?? "")"]
        }
        return ["-map", "0", "-map", "-0:d", "-c", "copy", "-fflags", "+bitexact"] + formatOptions(format)
            + keptTrackNames(recipe, report: report, format: format) + changes
    }

    /// ffmpeg can't store QuickTime keys where Apple's frameworks read them,
    /// so they are added to the copy afterwards: what the recipe leaves of
    /// `stored`, the file's own items, or of the tags if it has none to read.
    /// Other makers' keys in the same atom aren't Apple's to read, and the
    /// editor has already said they won't be kept.
    public static func quickTimeItems(_ recipe: MetadataRecipe, report: MetadataReport, stored: [QuickTimeItem] = [],
                                      format: FileFormat) -> [QuickTimeItem] {
        guard quickTimeFormats.contains(format) else { return [] }
        let changed = Dictionary(recipe.changes.map { ($0.key, $0) }) { first, _ in first }
        let tags = report.fields.filter { $0.scope == .file && MetadataRules.isQuickTimeKey($0.key) }
        let own = stored.filter { MetadataRules.isQuickTimeKey($0.key) }
        let existing = own.isEmpty ? tags.map { QuickTimeItem(key: $0.key, value: $0.value) } : own
        let kept = existing.compactMap { item -> QuickTimeItem? in
            guard let change = changed[item.key] else { return item }
            return change.value.map { QuickTimeItem(key: item.key, value: $0) }
        }
        let new = recipe.changes.filter { $0.original == nil && MetadataRules.isQuickTimeKey($0.key) }.compactMap { change in
            change.value.map { QuickTimeItem(key: change.key, value: $0) }
        }
        return kept + new
    }

    /// The first change `saved` doesn't show. A format may reword a value,
    /// so a change only counts as missed if the old value is still there or
    /// the field is missing altogether.
    public static func missedChange(in recipe: MetadataRecipe, saved: MetadataReport, report: MetadataReport) -> MetadataChange? {
        recipe.changes.first { change in
            let stored = saved.field(change.key, in: report.copyScope(of: change.scope))?.value
            guard let wanted = change.value else {
                return stored == change.original && stored != nil && !MetadataRules.isRegenerated(change.key)
            }
            guard let stored else { return true }
            return stored != wanted && stored == change.original
        }
    }

    private static func usesAtom(_ key: String, format: FileFormat) -> Bool {
        MetadataRules.isQuickTimeKey(key) && quickTimeFormats.contains(format)
    }

    /// QuickTime muxers only write a track's name if told it again.
    private static func keptTrackNames(_ recipe: MetadataRecipe, report: MetadataReport, format: FileFormat) -> [String] {
        guard quickTimeFormats.contains(format) else { return [] }
        let changed = Set(recipe.changes.map { MetadataField.ID(scope: $0.scope, key: $0.key) })
        return report.fields.filter { field in
            guard case .track = field.scope else { return false }
            return field.key == "name" && field.isKept && !changed.contains(field.id)
        }.flatMap { [specifier(for: $0.scope, report: report), "title=\($0.value)"] }
    }

    private static func specifier(for scope: MetadataScope, report: MetadataReport) -> String {
        switch report.copyScope(of: scope) {
        case .file: "-metadata"
        case .track(let number): "-metadata:s:\(number)"
        case .chapter(let number): "-metadata:c:\(number)"
        }
    }

    /// QuickTime muxers read a track's name from a tag called "title",
    /// though it reads back as "name".
    private static func storedKey(for change: MetadataChange, format: FileFormat) -> String {
        if case .track = change.scope, change.key == "name", quickTimeFormats.contains(format) { return "title" }
        return change.key
    }

    private static func formatOptions(_ format: FileFormat) -> [String] {
        switch format {
        // AIFF only has room for a few fields without an ID3 tag.
        case .aiff: ["-write_id3v2", "1"]
        // A plain WAV header can't describe more than 4 GiB of audio.
        case .wav: ["-rf64", "auto"]
        default: []
        }
    }
}

/// Builds QuickTime metadata the way Apple's own software writes it.
public enum QuickTimeAtoms {
    /// A `meta` atom to go inside `moov`: a handler, a `keys` table of names,
    /// and an `ilst` with each value under its key's number, counted from 1.
    public static func metadata(_ items: [QuickTimeItem]) -> Data {
        let handler = atom("hdlr", zeros(8) + Data("mdta".utf8) + zeros(13))
        let names = items.reduce(Data()) { $0 + number(UInt32(8 + $1.key.utf8.count)) + Data("mdta".utf8) + Data($1.key.utf8) }
        let keys = atom("keys", zeros(4) + number(UInt32(items.count)) + names)
        let values = items.enumerated().reduce(Data()) { data, entry in
            let value = atom("data", number(entry.element.type) + number(entry.element.locale) + entry.element.data)
            return data + atom(number(UInt32(entry.offset + 1)), value)
        }
        return atom("meta", handler + keys + atom("ilst", values))
    }

    private static func atom(_ type: String, _ body: Data) -> Data {
        atom(Data(type.utf8), body)
    }

    private static func atom(_ type: Data, _ body: Data) -> Data {
        number(UInt32(8 + body.count)) + type + body
    }

    private static func number(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func zeros(_ count: Int) -> Data {
        Data(count: count)
    }
}
