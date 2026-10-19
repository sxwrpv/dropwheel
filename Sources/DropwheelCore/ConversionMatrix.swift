import Foundation

/// One dragged item, as far as conversion is concerned.
public enum SelectionItem: Equatable, Sendable {
    case input(FileFormat)
    case folder
    case unknown
}

/// What this Mac can actually read and write. Some formats (AVIF, HEIC,
/// WebP input) depend on the macOS version, so the wheel asks before offering them.
public struct FormatCapabilities: Sendable {
    public static let unrestricted = FormatCapabilities(canRead: { _ in true }, canWrite: { _ in true })

    public let canRead: @Sendable (FileFormat) -> Bool
    public let canWrite: @Sendable (FileFormat) -> Bool

    public init(canRead: @escaping @Sendable (FileFormat) -> Bool, canWrite: @escaping @Sendable (FileFormat) -> Bool) {
        self.canRead = canRead
        self.canWrite = canWrite
    }
}

/// Which formats each input can become.
public enum ConversionMatrix {
    private static let imageOutputs: [FileFormat] = [.png, .jpg, .webp, .heic, .tiff, .avif, .bmp, .pdf]
    private static let pdfOutputs: [FileFormat] = [.docx, .pages, .pptx, .xlsx, .jpg, .png, .epub, .txt, .md]
    private static let audioOutputs: [FileFormat] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
    private static let videoOutputs: [FileFormat] = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3]
    private static let subtitleOutputs: [FileFormat] = [.srt, .vtt, .txt]
    private static let documentOutputs: [FileFormat] = [.docx, .pages, .md, .txt, .epub, .html, .pdf]
    private static let slideOutputs: [FileFormat] = [.pdf, .jpg, .png, .pptx]
    private static let spreadsheetOutputs: [FileFormat] = [.xlsx, .ods, .csv, .tsv, .pdf]
    private static let archiveOutputs: [FileFormat] = [.zip, .tar, .gzip]
    /// Formats that can be written but aren't offered as inputs.
    private static let exportOnly: Set<FileFormat> = [.html]

    public static func targets(for input: FileFormat) -> [FileFormat] {
        guard !exportOnly.contains(input) else { return [] }
        let candidates: [FileFormat]
        switch input.family {
        case .image: candidates = imageOutputs
        case .pdf: candidates = pdfOutputs
        case .audio: candidates = audioOutputs
        case .video: candidates = input == .gif ? videoOutputs.filter { $0 != .mp3 } : videoOutputs
        case .subtitle: candidates = subtitleOutputs
        case .document: candidates = documentOutputs
        // Only the old binary PPT is offered a PPTX upgrade.
        case .slides: candidates = input == .ppt ? slideOutputs : slideOutputs.filter { $0 != .pptx }
        case .spreadsheet: candidates = spreadsheetOutputs
        case .archive: candidates = archiveOutputs
        }
        return candidates.filter { $0 != input }
    }

    public static func targets(for item: SelectionItem) -> [FileFormat] {
        switch item {
        case .input(let format): targets(for: format)
        case .folder: archiveOutputs
        case .unknown: []
        }
    }

    /// Targets every item in the selection supports, in wheel order, limited
    /// to what `capabilities` says this Mac can read and write.
    public static func targets(
        for selection: [SelectionItem],
        capabilities: FormatCapabilities = .unrestricted
    ) -> [FileFormat] {
        guard let first = selection.first else { return [] }
        let unreadable = selection.contains { item in
            if case .input(let format) = item { return !capabilities.canRead(format) }
            return false
        }
        guard !unreadable else { return [] }
        let shared = selection.dropFirst().reduce(targets(for: first)) { shared, item in
            let allowed = Set(targets(for: item))
            return shared.filter(allowed.contains)
        }
        return shared.filter(capabilities.canWrite)
    }

    /// Total distinct input → output pairs, including folders.
    public static var optionCount: Int {
        FileFormat.allCases.map { targets(for: $0).count }.reduce(0, +) + archiveOutputs.count
    }
}

/// Where a converted file is written: beside the original, never over an existing file.
public enum OutputNaming {
    /// `isDirectory` describes the input. `outputIsDirectory` is for
    /// multi-page image output, which goes in a folder such as "Report (PNG)".
    public static func destination(
        for input: URL,
        as format: FileFormat,
        isDirectory: Bool = false,
        outputIsDirectory: Bool = false,
        exists: (URL) -> Bool
    ) -> URL {
        let name = input.lastPathComponent
        let stem = isDirectory ? name : stem(of: name)
        let outputName = outputIsDirectory ? "\(stem) (\(format.label))" : "\(stem).\(format.preferredExtension)"
        return FilePaths.uniqueDestination(
            for: outputName,
            in: input.deletingLastPathComponent(),
            isDirectory: outputIsDirectory,
            exists: { exists($0) }
        )
    }

    /// The name without its format extension; "backup.tar.gz" becomes "backup".
    static func stem(of fileName: String) -> String {
        if fileName.lowercased().hasSuffix(".tar.gz") {
            return String(fileName.dropLast(".tar.gz".count))
        }
        return FilePaths.splitExtension(fileName).stem
    }
}
