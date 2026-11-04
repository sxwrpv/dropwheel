import Foundation

/// How the XMP standard stores a field's value.
public enum MetadataValueKind: Sendable {
    case text
    /// One value per language, as titles and descriptions are.
    case languageTagged
    case orderedList
    case unorderedList
}

/// What each field name means: how to show it, whether it can be changed,
/// and whether it records the camera or software rather than the user.
public enum MetadataRules {
    private static let quickTimePrefix = "com.apple.quicktime."

    // MARK: Access

    private static let structuralKeys: Set<String> = [
        "major_brand", "minor_version", "compatible_brands", "vendor_id", "timecode", "duration", "bps",
        "number_of_frames", "number_of_bytes", "filename", "mimetype",
        "exif:pixelxdimension", "exif:pixelydimension", "exif:colorspace", "exif:componentsconfiguration",
        "exif:exifversion", "exif:flashpixversion", "tiff:orientation", "tiff:resolutionunit", "tiff:xresolution",
        "tiff:yresolution", "tiff:compression", "tiff:photometricinterpretation", "tiff:tilewidth", "tiff:tilelength",
        "tiff:imagewidth", "tiff:imagelength", "tiff:bitspersample", "tiff:samplesperpixel", "tiff:planarconfiguration",
        "tiff:rowsperstrip", "tiff:ycbcrpositioning", "pdf:pdfversion", "pdfaid:part", "pdfaid:conformance",
    ]

    /// Formats write these themselves, so one may be back after it is removed.
    /// That is a generic default rather than what the file said.
    private static let regeneratedKeys: Set<String> = ["handler_name", "language"]
    /// Among a muxer's statistics, which describe the streams, these describe the muxer.
    private static let muxerSignatures: Set<String> = ["_statistics_writing_app", "_statistics_writing_date_utc"]

    public static func access(forKey key: String, scope: MetadataScope) -> MetadataAccess {
        let name = key.lowercased()
        if muxerSignatures.contains(name) { return .editable }
        // ffmpeg reads the first "=" of an argument as the end of the name.
        if structuralKeys.contains(name) || name.hasPrefix("_statistics_") || key.contains("=") { return .locked }
        return .editable
    }

    public static func isRegenerated(_ key: String) -> Bool {
        regeneratedKeys.contains(key.lowercased())
    }

    public static func isQuickTimeKey(_ key: String) -> Bool {
        key.hasPrefix(quickTimePrefix)
    }

    /// For a field a file doesn't have yet. Existing ones keep their own kind.
    public static func valueKind(of key: String) -> MetadataValueKind {
        switch key {
        case "dc:title", "dc:description", "dc:rights": .languageTagged
        case "dc:creator": .orderedList
        case "dc:subject": .unorderedList
        default: .text
        }
    }

    /// What separates a list's items as they are shown and typed. Commas
    /// won't do for people, whose names can have them.
    public static func listSeparator(for key: String) -> Character {
        key == "dc:creator" ? ";" : ","
    }

    // MARK: Camera and processing data

    private static let cameraKeys: Set<String> = [
        "make", "model", "software", "encoder", "encoded_by", "encoding_tool", "handler_name", "location", "location-eng",
        "creation_time", "producer", "creator", "creationdate", "moddate", "xmp:creatortool", "xmp:createdate",
        "xmp:modifydate", "xmp:metadatadate", "pdf:producer", "photoshop:datecreated", "photoshop:datetimeoriginal",
        "photoshop:history", "tiff:make", "tiff:model", "tiff:software", "tiff:hostcomputer", "tiff:datetime",
        "annotationauthors",
    ]
    private static let cameraPrefixes = ["exif:", "exifex:", "exifaux:", "aux:", "crs:", "xmpmm:", "com.android.", "png:", quickTimePrefix]
    /// Under those prefixes, but written by a person.
    private static let personalKeys: Set<String> = [
        "exif:usercomment", "com.apple.quicktime.title", "com.apple.quicktime.description", "com.apple.quicktime.comment",
        "com.apple.quicktime.keywords", "com.apple.quicktime.artist", "com.apple.quicktime.author",
        "com.apple.quicktime.album", "com.apple.quicktime.genre", "com.apple.quicktime.copyright",
        "com.apple.quicktime.displayname",
    ]

    public static func isCameraOrProcessing(_ key: String) -> Bool {
        let name = key.lowercased()
        if personalKeys.contains(name) { return false }
        return cameraKeys.contains(name) || muxerSignatures.contains(name) || cameraPrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: Adding fields

    private static let commonKeys = ["title", "artist", "album", "album_artist", "composer", "genre", "date", "comment",
                                     "copyright", "track", "disc", "lyrics"]
    private static let iTunesKeys = commonKeys + ["description", "grouping", "keywords"]
    private static let riffKeys = ["title", "artist", "album", "genre", "date", "comment", "copyright", "track"]
    private static let imageKeys = ["dc:title", "dc:description", "dc:creator", "dc:rights", "dc:subject"]
    private static let pdfKeys = ["Title", "Author", "Subject", "Keywords"]

    /// The new fields a part of a file can store. Each is checked against
    /// the real muxer by the engine tests.
    public static func addableKeys(for format: FileFormat, scope: MetadataScope) -> [String] {
        switch scope {
        case .chapter:
            return ["title"]
        case .track:
            switch format {
            case .ogg, .opus: return commonKeys
            case .mkv, .webm: return ["title", "language"]
            case .mp4, .mov, .m4a: return ["language"]
            default: return []
            }
        case .file:
            break
        }
        switch format {
        case .mp4, .m4a: return iTunesKeys
        case .mov: return ["title", "artist", "album", "genre", "date", "comment", "copyright"]
        case .mp3, .flac, .aiff, .mkv, .webm: return commonKeys
        case .wav: return riffKeys
        case .avi: return riffKeys.filter { $0 != "album" }
        case .wma, .wmv: return riffKeys
        case .pdf: return pdfKeys
        default: return format.family == .image ? imageKeys : []
        }
    }

    // MARK: Names

    private static let labels: [String: String] = [
        "album_artist": "Album Artist",
        "track": "Track Number",
        "disc": "Disc Number",
        "make": "Camera Make",
        "model": "Camera Model",
        "creationdate": "Created",
        "moddate": "Modified",
        "creator": "Created With",
        "dc:title": "Title",
        "dc:description": "Description",
        "dc:creator": "Author",
        "dc:rights": "Copyright",
        "dc:subject": "Keywords",
        "tiff:make": "Camera Make",
        "tiff:model": "Camera Model",
        "tiff:software": "Software",
        "xmp:creatortool": "Software",
        "xmp:createdate": "Created",
        "xmp:modifydate": "Modified",
        "xmp:metadatadate": "Metadata Changed",
        "pdf:producer": "Producer",
        "pdf:keywords": "Keywords",
        "photoshop:datecreated": "Date Taken",
        "photoshop:datetimeoriginal": "Date Taken",
        "exif:datetimeoriginal": "Date Taken",
        "png:time": "Last Modified",
        "exif:pixelxdimension": "Pixel Width",
        "exif:pixelydimension": "Pixel Height",
        "exif:gpslatitude": "Latitude",
        "exif:gpslongitude": "Longitude",
        "exif:gpsaltitude": "Altitude",
        "exifex:lensmodel": "Lens",
        "exifex:lensmake": "Lens Make",
        "exifex:bodyserialnumber": "Camera Serial Number",
        "com.apple.quicktime.make": "Camera Make",
        "com.apple.quicktime.model": "Camera Model",
        "com.apple.quicktime.location.iso6709": "Location",
        "com.apple.quicktime.creationdate": "Date Taken",
    ]

    public static func label(for key: String) -> String {
        labels[key.lowercased()] ?? words(of: key)
    }

    /// "exif:FocalLength" as "Focal Length", "handler_name" as "Handler Name".
    private static func words(of key: String) -> String {
        let name = key.split { $0 == ":" || $0 == "." }.last.map(String.init) ?? key
        let cased = name.contains(where: \.isLowercase) ? name : name.lowercased()
        let spaced = cased.reduce(into: "") { text, letter in
            if letter == "_" || letter == "-" {
                text.append(" ")
            } else {
                if letter.isUppercase, text.last?.isLowercase == true { text.append(" ") }
                text.append(letter)
            }
        }
        return spaced.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
