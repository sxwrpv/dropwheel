import Darwin
import Foundation

/// Writes results beside the original without ever overwriting anything.
///
/// The work goes to a hidden partial file (or folder) first. Only when it
/// succeeds is it renamed to the final name, with an exclusive rename, so a
/// failure or cancellation never leaves a half-written file behind and a
/// file that appears at the chosen name in the meantime is never replaced.
enum OutputWriter {
    private static let maximumRenameAttempts = 100

    /// `destination` picks the final name; it is told whether the result is
    /// a folder and is asked again if the name is taken by the time of the rename.
    static func write(
        near anchor: URL,
        partialExtension: String?,
        destination: (_ outputIsDirectory: Bool) -> URL,
        produce: (URL) async throws(ConversionError) -> Void
    ) async throws(ConversionError) -> URL {
        let suffix = partialExtension.map { ".\($0)" } ?? ""
        let partial = anchor.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString.prefix(8)).dropwheel-partial\(suffix)")
        WorkInProgress.shared.add(partial)
        defer {
            try? FileManager.default.removeItem(at: partial)
            WorkInProgress.shared.remove(partial)
        }

        try await produce(partial)
        try Task.checkCancellation(or: .cancelled)
        return try moveIntoPlace(partial, destination: destination)
    }

    private static func moveIntoPlace(_ partial: URL, destination: (Bool) -> URL) throws(ConversionError) -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: partial.path, isDirectory: &isDirectory) else {
            throw .writeFailed("The converter finished without producing a file.")
        }
        for _ in 0..<maximumRenameAttempts {
            let target = destination(isDirectory.boolValue)
            switch exclusiveRename(partial, to: target) {
            case 0: return target
            case EEXIST: continue
            case let code: throw .writeFailed(String(cString: strerror(code)))
            }
        }
        throw .writeFailed("Couldn’t find a free name for the result.")
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
