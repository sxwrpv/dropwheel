/// Broad groups of formats. Each family has its own conversion engine.
public enum FormatFamily: String, Sendable {
    case image
    case pdf
    case audio
    case video
    case subtitle
    case document
    case slides
    case spreadsheet
    case archive
}

/// Every format Dropwheel reads or writes. Case order is the order slices
/// appear on the wheel.
public enum FileFormat: String, CaseIterable, Sendable {
    // Images
    case png, jpg, webp, heic, tiff, avif, bmp, svg
    case pdf
    // Audio
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    // Video
    case mp4, mov, mkv, webm, avi, wmv, gif
    // Subtitles
    case srt, vtt
    // Documents
    case docx, pages, md, txt, epub, html, rtf, rtfd, textClipping
    // Slides
    case pptx, ppt
    // Spreadsheets
    case xlsx, ods, csv, tsv, xls
    // Archives
    case zip, tar, gzip, rar

    public var family: FormatFamily {
        switch self {
        case .png, .jpg, .webp, .heic, .tiff, .avif, .bmp, .svg: .image
        case .pdf: .pdf
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: .audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .gif: .video
        case .srt, .vtt: .subtitle
        case .docx, .pages, .md, .txt, .epub, .html, .rtf, .rtfd, .textClipping: .document
        case .pptx, .ppt: .slides
        case .xlsx, .ods, .csv, .tsv, .xls: .spreadsheet
        case .zip, .tar, .gzip, .rar: .archive
        }
    }

    /// Recognised extensions, lowercase. The first is used for output files.
    public var extensions: [String] {
        switch self {
        case .jpg: ["jpg", "jpeg", "jpe"]
        case .tiff: ["tiff", "tif"]
        case .heic: ["heic", "heif"]
        case .aiff: ["aiff", "aif"]
        case .vtt: ["vtt", "webvtt"]
        case .md: ["md", "markdown"]
        case .txt: ["txt", "text"]
        case .html: ["html", "htm"]
        case .textClipping: ["textclipping"]
        case .gzip: ["tar.gz", "tgz", "gz"]
        default: [rawValue]
        }
    }

    public var preferredExtension: String { extensions[0] }

    /// Formats stored as folders (packages) rather than single files.
    public var isPackage: Bool {
        self == .rtfd || self == .pages
    }

    /// Short uppercase name, as drawn on a wheel slice.
    public var label: String {
        switch self {
        case .gzip: "GZIP"
        case .textClipping: "CLIPPING"
        default: rawValue.uppercased()
        }
    }

    /// SF Symbol for the format's family.
    public var symbolName: String {
        switch family {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .audio: "waveform"
        case .video: self == .gif ? "photo.stack" : "film"
        case .subtitle: "captions.bubble"
        case .document: self == .txt ? "text.alignleft" : "doc.text"
        case .slides: "rectangle.on.rectangle"
        case .spreadsheet: "tablecells"
        case .archive: "archivebox"
        }
    }

    public init?(fileExtension: String) {
        let lowered = fileExtension.lowercased()
        guard let match = FileFormat.allCases.first(where: { $0.extensions.contains(lowered) }) else { return nil }
        self = match
    }

    /// Matches multi-part extensions such as "tar.gz" before single ones.
    public init?(fileName: String) {
        let lowered = fileName.lowercased()
        if lowered.hasSuffix(".tar.gz") {
            self = .gzip
            return
        }
        guard let dot = lowered.lastIndex(of: "."), dot != lowered.startIndex else { return nil }
        self.init(fileExtension: String(lowered[lowered.index(after: dot)...]))
    }
}
