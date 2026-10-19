import DropwheelCore
import Foundation

/// Reports progress from 0 to 1. Called from background threads.
public typealias ProgressHandler = @Sendable (Double) -> Void

/// Converts one input into one output file at a path chosen by the caller.
protocol Converter: Sendable {
    func convert(_ input: URL, to target: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError)
}

/// Entry point for all conversions: picks the engine, and writes the result
/// beside the original without ever overwriting an existing file.
public struct ConversionService: Sendable {
    public init() {}

    /// What a dragged URL counts as for the wheels. Symlinks to folders
    /// count as folders; package formats such as RTFD are files.
    public static func selectionItem(for url: URL) -> SelectionItem {
        let format = FileFormat(fileName: url.lastPathComponent)
        let resolved = url.resolvingSymlinksInPath()
        let isDirectory = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory, format?.isPackage != true { return .folder }
        return format.map(SelectionItem.input) ?? .unknown
    }

    /// Deletes the hidden partial files and scratch folders of work still
    /// running. The app calls this when it quits, after stopping the tools.
    public static func discardWorkInProgress() {
        WorkInProgress.shared.removeAll()
    }

    /// Converts `input` and returns where the result was saved.
    public func convert(_ input: URL, to target: FileFormat, progress: @escaping ProgressHandler = { _ in }) async throws(ConversionError) -> URL {
        let item = Self.selectionItem(for: input)
        guard ConversionMatrix.targets(for: [item], capabilities: .system).contains(target) else {
            throw .unsupported(input: input.lastPathComponent, target: target)
        }
        let converter = try converter(for: item, target: target)
        let fileManager = FileManager.default

        return try await OutputWriter.write(near: input, partialExtension: target.preferredExtension) { outputIsDirectory in
            // A package such as an RTFD is a folder on disk but a single document.
            OutputNaming.destination(for: input, as: target, isDirectory: item == .folder,
                                     outputIsDirectory: outputIsDirectory && !target.isPackage) {
                fileManager.fileExists(atPath: $0.path)
            }
        } produce: { partial throws(ConversionError) in
            try await converter.convert(input, to: target, output: partial, progress: progress)
        }
    }

    /// Picks the engine for the input. Folders and archives go to the
    /// archiver whatever the target.
    private func converter(for item: SelectionItem, target: FileFormat) throws(ConversionError) -> any Converter {
        switch item {
        case .folder:
            return ArchiveConverter()
        case .unknown:
            throw .unsupported(input: String(describing: item), target: target)
        case .input(let format):
            switch format.family {
            case .image: return ImageConverter()
            case .pdf: return PDFConverter()
            case .audio, .video: return MediaConverter()
            case .subtitle: return SubtitleConverter()
            case .document: return DocumentConverter()
            case .slides, .spreadsheet: return OfficeConverter()
            case .archive: return ArchiveConverter()
            }
        }
    }
}

/// Partial files and scratch folders that belong to running work.
final class WorkInProgress: @unchecked Sendable {
    static let shared = WorkInProgress()
    private let lock = NSLock()
    private var urls: Set<URL> = []

    func add(_ url: URL) {
        lock.withLock { _ = urls.insert(url) }
    }

    func remove(_ url: URL) {
        lock.withLock { _ = urls.remove(url) }
    }

    func removeAll() {
        let pending = lock.withLock {
            defer { urls.removeAll() }
            return urls
        }
        pending.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

extension Task where Success == Never, Failure == Never {
    /// Throws `error` if the current task has been cancelled.
    static func checkCancellation(or error: ConversionError) throws(ConversionError) {
        if isCancelled { throw error }
    }
}
