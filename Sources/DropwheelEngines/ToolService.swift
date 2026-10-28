import DropwheelCore
import Foundation

/// Entry point for the file tools: checks the tool fits the selection, runs
/// it, and writes the result beside the first input without overwriting anything.
public struct ToolService: Sendable {
    public init() {}

    /// Per-file tools take one input; Create PDF, Merge PDFs and Join Videos
    /// take the whole selection, in order. Returns where the result was saved.
    public func run(
        _ tool: ToolKind,
        on inputs: [URL],
        options: ToolOptions = .none,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws(ConversionError) -> URL {
        guard let first = inputs.first, let format = FileFormat(fileName: first.lastPathComponent) else {
            throw .toolUnavailable(tool: tool.title, input: inputs.first?.lastPathComponent ?? "this selection")
        }
        let selection = inputs.map(ConversionService.selectionItem)
        guard ToolCatalog.tools(for: selection).contains(tool), tool.usesWholeSelection || inputs.count == 1 else {
            throw .toolUnavailable(tool: tool.title, input: inputs.count == 1 ? first.lastPathComponent : "this selection")
        }
        let chosen = options == .none ? ToolOptions.default(for: tool) : options
        let naming = Self.outputName(for: tool, format: format, options: chosen)
        let originalBytes = Self.fileSize(first)
        if case .compress(let goal) = chosen, let target = goal.targetBytes(originalBytes: originalBytes) {
            guard target > 0 else { throw .targetTooSmall(first.lastPathComponent) }
            // Already within the target: nothing to do, and no copy to clutter the folder.
            guard target < originalBytes else { throw .notSmaller(first.lastPathComponent) }
        }
        let fileManager = FileManager.default

        return try await OutputWriter.write(near: first, partialExtension: naming.fileExtension) { _ in
            OutputNaming.toolDestination(for: first, suffix: naming.suffix, fileExtension: naming.fileExtension) {
                fileManager.fileExists(atPath: $0.path)
            }
        } produce: { partial throws(ConversionError) in
            try await Self.perform(tool, inputs: inputs, format: format, options: chosen, output: partial, progress: progress)
            // A "compressed" copy that is no smaller would only add clutter.
            if tool == .compress, Self.fileSize(partial) >= originalBytes {
                throw .notSmaller(first.lastPathComponent)
            }
        }
    }

    private static func perform(
        _ tool: ToolKind,
        inputs: [URL],
        format: FileFormat,
        options: ToolOptions,
        output: URL,
        progress: @escaping ProgressHandler
    ) async throws(ConversionError) {
        let input = inputs[0]
        switch (tool, options) {
        case (.compress, .compress(let goal)):
            switch format.family {
            case .image: try await ImageTools.compress(input, goal: goal, output: output)
            case .pdf: try PDFTools.compress(input, level: pdfLevel(for: goal), output: output)
            default: try await MediaTools.compress(input, format: format, goal: goal, output: output, progress: progress)
            }
        case (.removeMetadata, _):
            switch format.family {
            case .image: try await ImageTools.stripMetadata(input, output: output)
            case .pdf: try PDFTools.stripMetadata(input, output: output)
            default: try await MediaTools.stripMetadata(input, output: output, progress: progress)
            }
        case (.normalizeVolume, .loudness(let target)):
            try await MediaTools.normalize(input, format: format, target: target, output: output, progress: progress)
        case (.audioChannels, .channels(let layout)):
            try await MediaTools.changeChannels(input, format: format, layout: layout, output: output, progress: progress)
        case (.changeSpeed, .speed(let factor)):
            try await MediaTools.changeSpeed(input, format: format, factor: factor, output: output, progress: progress)
        case (.splitVideo, .split(let plan)):
            try await MediaTools.split(input, format: format, plan: plan, output: output, progress: progress)
        case (.createPDF, _):
            try ImageTools.createPDF(from: inputs, output: output, progress: progress)
        case (.mergePDFs, _):
            try PDFTools.merge(inputs, output: output, progress: progress)
        case (.crop, .crop(let recipe, let width, let height)):
            if format.family == .video {
                try await EditTools.cropVideo(input, format: format, recipe: recipe, output: output, progress: progress)
            } else {
                try await EditTools.cropImage(input, format: format, recipe: recipe, outputWidth: width,
                                              outputHeight: height, output: output)
            }
        case (.trim, .trim(let range)):
            try await EditTools.trim(input, format: format, range: range, output: output, progress: progress)
        case (.trim, .trimSilence):
            try await EditTools.trimSilence(input, format: format, output: output, progress: progress)
        case (.editPhoto, .photoEdit(let adjustments)):
            try await PhotoTools.apply(input, format: format, output: output, keepMetadata: true) { image throws(ConversionError) in
                try PhotoRendering.adjusted(image, adjustments)
            }
        case (.addBackground, .background(let recipe)):
            try await PhotoTools.apply(input, format: format, output: output, keepMetadata: true) { image throws(ConversionError) in
                try PhotoRendering.framed(image, recipe)
            }
        case (.annotate, .annotations(let annotations)):
            try await PhotoTools.apply(input, format: format, output: output, keepMetadata: true) { image throws(ConversionError) in
                try PhotoRendering.annotated(image, annotations)
            }
        case (.redactPhoto, .redactions(let regions)):
            try await PhotoTools.apply(input, format: format, output: output, keepMetadata: false) { image throws(ConversionError) in
                try PhotoRendering.redacted(image, regions)
            }
        case (.joinVideos, _):
            try await MediaTools.join(inputs, output: output, progress: progress)
        default:
            throw .toolUnavailable(tool: tool.title, input: input.lastPathComponent)
        }
        progress(1)
    }

    /// PDFs can only be compressed with presets; a size goal uses the strongest one.
    private static func pdfLevel(for goal: CompressionGoal) -> CompressionLevel {
        if case .level(let level) = goal { return level }
        return .strong
    }

    /// The suffix and extension of the result, e.g. "compressed" + "mp4".
    /// A nil extension means the result is a folder.
    static func outputName(for tool: ToolKind, format: FileFormat, options: ToolOptions) -> (suffix: String, fileExtension: String?) {
        switch tool {
        case .compress:
            let output = format.family == .audio || format.family == .video ? MediaTools.compressedFormat(for: format) : format
            return ("compressed", output.preferredExtension)
        case .removeMetadata: return ("clean", format.preferredExtension)
        case .normalizeVolume: return ("normalized", format.preferredExtension)
        case .audioChannels:
            if case .channels(let layout) = options { return (layout.rawValue, format.preferredExtension) }
            return ("channels", format.preferredExtension)
        case .changeSpeed:
            if case .speed(let factor) = options { return (MediaToolPlans.speedLabel(factor), format.preferredExtension) }
            return ("speed", format.preferredExtension)
        case .splitVideo: return ("parts", nil)
        case .createPDF: return ("combined", FileFormat.pdf.preferredExtension)
        case .mergePDFs: return ("merged", FileFormat.pdf.preferredExtension)
        case .joinVideos: return ("joined", FileFormat.mp4.preferredExtension)
        case .crop: return ("cropped", format.preferredExtension)
        case .trim: return ("trimmed", format.preferredExtension)
        case .editPhoto: return ("edited", format.preferredExtension)
        case .annotate: return ("annotated", format.preferredExtension)
        case .addBackground: return ("framed", format.preferredExtension)
        case .redactPhoto: return ("redacted", format.preferredExtension)
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
