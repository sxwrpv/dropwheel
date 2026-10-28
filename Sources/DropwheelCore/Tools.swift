import Foundation

/// File tools on the Command wheel. Case order is the order slices appear.
public enum ToolKind: String, CaseIterable, Sendable {
    case compress
    case removeMetadata
    case crop
    case editPhoto
    case annotate
    case addBackground
    case redactPhoto
    case trim
    case normalizeVolume
    case audioChannels
    case changeSpeed
    case splitVideo
    case createPDF
    case mergePDFs
    case joinVideos

    public var title: String {
        switch self {
        case .compress: "Compress"
        case .removeMetadata: "Remove Metadata"
        case .crop: "Crop"
        case .editPhoto: "Edit Photo"
        case .annotate: "Annotate"
        case .addBackground: "Add a Background"
        case .redactPhoto: "Redact"
        case .trim: "Trim"
        case .normalizeVolume: "Normalize Volume"
        case .audioChannels: "Audio Channels"
        case .changeSpeed: "Change Speed"
        case .splitVideo: "Split Video"
        case .createPDF: "Create PDF"
        case .mergePDFs: "Merge PDFs"
        case .joinVideos: "Join Videos"
        }
    }

    /// Short uppercase name drawn on a wheel slice.
    public var label: String {
        switch self {
        case .compress: "COMPRESS"
        case .removeMetadata: "METADATA"
        case .crop: "CROP"
        case .editPhoto: "EDIT"
        case .annotate: "ANNOTATE"
        case .addBackground: "BACKGROUND"
        case .redactPhoto: "REDACT"
        case .trim: "TRIM"
        case .normalizeVolume: "NORMALIZE"
        case .audioChannels: "CHANNELS"
        case .changeSpeed: "SPEED"
        case .splitVideo: "SPLIT"
        case .createPDF: "PDF"
        case .mergePDFs: "MERGE"
        case .joinVideos: "JOIN"
        }
    }

    public var symbolName: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .removeMetadata: "tag.slash"
        case .crop: "crop"
        case .editPhoto: "slider.horizontal.3"
        case .annotate: "pencil.tip.crop.circle"
        case .addBackground: "rectangle.inset.filled"
        case .redactPhoto: "eye.slash"
        case .trim: "timeline.selection"
        case .normalizeVolume: "speaker.wave.3"
        case .audioChannels: "hifispeaker.2"
        case .changeSpeed: "speedometer"
        case .splitVideo: "scissors"
        case .createPDF: "doc.badge.plus"
        case .mergePDFs: "doc.on.doc"
        case .joinVideos: "film.stack"
        }
    }

    /// Tools that ask for a choice (a preset, a speed, a number of parts) before running.
    public var needsOptions: Bool {
        switch self {
        case .compress, .normalizeVolume, .audioChannels, .changeSpeed, .splitVideo: true
        case .removeMetadata, .createPDF, .mergePDFs, .joinVideos, .crop, .trim,
             .editPhoto, .annotate, .addBackground, .redactPhoto: false
        }
    }

    /// Tools that open an editing window, one per file, instead of running straight away.
    public var opensEditor: Bool {
        switch self {
        case .crop, .trim, .editPhoto, .annotate, .addBackground, .redactPhoto: true
        default: false
        }
    }

    /// Tools that turn the whole selection into one result, rather than
    /// running once per file.
    public var usesWholeSelection: Bool {
        self == .createPDF || self == .mergePDFs || self == .joinVideos
    }
}

/// Which tools apply to a selection.
public enum ToolCatalog {
    private static let compressibleImages: Set<FileFormat> = [.jpg, .png, .heic, .tiff, .avif, .webp]

    /// `capabilities` leaves out image formats this Mac can't read or write,
    /// since every image tool decodes and re-encodes or copies them.
    public static func tools(for selection: [SelectionItem], capabilities: FormatCapabilities = .unrestricted) -> [ToolKind] {
        var formats: [FileFormat] = []
        for item in selection {
            guard case .input(let format) = item else { return [] }
            if format.family == .image, !capabilities.canRead(format) || !capabilities.canWrite(format) { return [] }
            formats.append(format)
        }
        guard let first = formats.first else { return [] }

        let shared = formats.dropFirst().reduce(singleFileTools(for: first)) { shared, format in
            shared.intersection(singleFileTools(for: format))
        }
        var available = shared
        if formats.count > 1, let combining = wholeSelectionTool(for: formats) {
            available.insert(combining)
        }
        return ToolKind.allCases.filter(available.contains)
    }

    private static func singleFileTools(for format: FileFormat) -> Set<ToolKind> {
        switch format.family {
        case .image: compressibleImages.contains(format)
            ? [.compress, .removeMetadata, .crop, .editPhoto, .annotate, .addBackground, .redactPhoto] : []
        case .pdf: [.compress, .removeMetadata]
        case .audio: [.compress, .removeMetadata, .trim, .normalizeVolume, .audioChannels]
        case .video: format == .gif ? [] : [.compress, .removeMetadata, .crop, .trim, .changeSpeed, .splitVideo]
        default: []
        }
    }

    private static func wholeSelectionTool(for formats: [FileFormat]) -> ToolKind? {
        if formats.allSatisfy({ $0.family == .image && $0 != .svg }) { return .createPDF }
        if formats.allSatisfy({ $0 == .pdf }) { return .mergePDFs }
        if formats.allSatisfy({ $0.family == .video && $0 != .gif }) { return .joinVideos }
        return nil
    }
}

// MARK: Options

public enum CompressionLevel: String, CaseIterable, Sendable {
    case light
    case balanced
    case strong

    public var title: String { rawValue.capitalized }
}

/// What "smaller" means: a preset, a size to reach, or a share to remove.
public enum CompressionGoal: Equatable, Sendable {
    case level(CompressionLevel)
    case targetBytes(Int)
    case reducePercent(Int)

    /// Size to aim for, given the original's size, or nil for a preset.
    public func targetBytes(originalBytes: Int) -> Int? {
        switch self {
        case .level: nil
        case .targetBytes(let bytes): bytes
        case .reducePercent(let percent): originalBytes * (100 - min(max(percent, 1), 99)) / 100
        }
    }
}

public enum ChannelLayout: String, CaseIterable, Sendable {
    case mono
    case stereo

    public var title: String { rawValue.capitalized }
    public var channelCount: Int { self == .mono ? 1 : 2 }
}

/// Loudness targets in LUFS for common destinations.
public enum LoudnessTarget: String, CaseIterable, Sendable {
    case podcast
    case music
    case broadcast

    public var integratedLUFS: Int {
        switch self {
        case .podcast: -16
        case .music: -14
        case .broadcast: -23
        }
    }

    public var title: String {
        switch self {
        case .podcast: "Speech and podcasts (−16 LUFS)"
        case .music: "Music streaming (−14 LUFS)"
        case .broadcast: "Broadcast (−23 LUFS)"
        }
    }
}

public enum SplitPlan: Equatable, Sendable {
    case equalParts(Int)
    case everySeconds(Int)
}

/// The choice made in a tool's options panel.
public enum ToolOptions: Equatable, Sendable {
    case none
    case compress(CompressionGoal)
    case speed(Double)
    case split(SplitPlan)
    case channels(ChannelLayout)
    case loudness(LoudnessTarget)
    /// From the crop editor; an output size resizes the cropped area to exact pixels.
    case crop(CropRecipe, outputWidth: Int?, outputHeight: Int?)
    /// From the trim editor.
    case trim(TrimRange)
    /// Trim only the silence at the start and end of a recording.
    case trimSilence
    case photoEdit(PhotoAdjustments)
    case background(BackgroundRecipe)
    case annotations([Annotation])
    case redactions([RedactionRegion])

    public static let speedChoices: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 4]

    public static func `default`(for tool: ToolKind) -> ToolOptions {
        switch tool {
        case .compress: .compress(.level(.balanced))
        case .changeSpeed: .speed(2)
        case .splitVideo: .split(.equalParts(2))
        case .audioChannels: .channels(.mono)
        case .normalizeVolume: .loudness(.podcast)
        case .removeMetadata, .createPDF, .mergePDFs, .joinVideos, .crop, .trim,
             .editPhoto, .annotate, .addBackground, .redactPhoto: .none
        }
    }
}

extension OutputNaming {
    /// "photo compressed.heic" beside the input, or a folder such as
    /// "clip parts" when `fileExtension` is nil. Never an existing name.
    public static func toolDestination(
        for input: URL,
        suffix: String,
        fileExtension: String?,
        exists: (URL) -> Bool
    ) -> URL {
        let base = "\(stem(of: input.lastPathComponent)) \(suffix)"
        let name = fileExtension.map { "\(base).\($0)" } ?? base
        return FilePaths.uniqueDestination(for: name, in: input.deletingLastPathComponent(),
                                           isDirectory: fileExtension == nil, exists: exists)
    }
}
