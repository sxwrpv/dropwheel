import Darwin
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
    private static let maximumRenameAttempts = 100

    public init() {}

    /// What a dragged URL counts as for the conversion wheel. Symlinks to
    /// folders count as folders; package formats such as RTFD are files.
    public static func selectionItem(for url: URL) -> SelectionItem {
        let format = FileFormat(fileName: url.lastPathComponent)
        let resolved = url.resolvingSymlinksInPath()
        let isDirectory = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory, format?.isPackage != true { return .folder }
        return format.map(SelectionItem.input) ?? .unknown
    }

    /// Deletes the hidden partial files and scratch folders of conversions
    /// still running. The app calls this when it quits, after stopping the tools.
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

        // Work in a hidden file beside the result, then rename it into place.
        // A failure or cancellation never leaves a half-written file behind.
        let directory = input.deletingLastPathComponent()
        let partial = directory.appendingPathComponent(
            ".\(UUID().uuidString.prefix(8)).dropwheel-partial.\(target.preferredExtension)")
        WorkInProgress.shared.add(partial)
        defer {
            try? FileManager.default.removeItem(at: partial)
            WorkInProgress.shared.remove(partial)
        }

        try await converter.convert(input, to: target, output: partial, progress: progress)
        try Task.checkCancellation(or: .cancelled)
        return try Self.moveIntoPlace(partial, for: input, as: target, isDirectory: item == .folder)
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

    /// Renames with RENAME_EXCL, so a file that appears at the chosen name
    /// in the meantime (another app, another conversion) is never replaced.
    /// Converters that produce several pages write a folder instead of a file.
    private static func moveIntoPlace(_ partial: URL, for input: URL, as target: FileFormat, isDirectory: Bool) throws(ConversionError) -> URL {
        let fileManager = FileManager.default
        var partialIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: partial.path, isDirectory: &partialIsDirectory) else {
            throw .writeFailed("The converter finished without producing a file.")
        }
        // A package such as an RTFD is a folder on disk but a single document.
        let outputIsFolder = partialIsDirectory.boolValue && !target.isPackage
        for _ in 0..<maximumRenameAttempts {
            let destination = OutputNaming.destination(for: input, as: target, isDirectory: isDirectory,
                                                       outputIsDirectory: outputIsFolder) {
                fileManager.fileExists(atPath: $0.path)
            }
            switch exclusiveRename(partial, to: destination) {
            case 0: return destination
            case EEXIST: continue
            case let code: throw .writeFailed(String(cString: strerror(code)))
            }
        }
        throw .writeFailed("Couldn’t find a free name for the converted file.")
    }

    /// Returns 0 on success or an errno value.
    private static func exclusiveRename(_ source: URL, to destination: URL) -> Int32 {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let renameError = errno
        guard renameError == ENOTSUP || renameError == EINVAL else { return renameError }
        return placeholderRename(source, to: destination)
    }

    /// For volumes without RENAME_EXCL (exFAT, FAT, some network shares):
    /// claim the name with an exclusive create (a file, or an empty folder
    /// for folder output), then rename over that placeholder. Hard links,
    /// the usual alternative, fail on those volumes and never work for folders.
    static func placeholderRename(_ source: URL, to destination: URL) -> Int32 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return ENOENT }
        if isDirectory.boolValue {
            guard mkdir(destination.path, 0o755) == 0 else { return errno }
        } else {
            let descriptor = open(destination.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard descriptor >= 0 else { return errno }
            close(descriptor)
        }
        guard rename(source.path, destination.path) == 0 else {
            let code = errno
            // Remove only the placeholder made above, which is still empty.
            _ = isDirectory.boolValue ? rmdir(destination.path) : unlink(destination.path)
            return code
        }
        return 0
    }
}

/// Partial files and scratch folders that belong to running conversions.
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
