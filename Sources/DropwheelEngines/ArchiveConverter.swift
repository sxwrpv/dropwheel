import DropwheelCore
import Foundation

/// Packs folders into ZIP, TAR or GZIP, and repacks archives (including RAR,
/// which macOS's bsdtar can read) into another archive format.
struct ArchiveConverter: Converter {
    private static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    private static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    private static let gunzip = URL(fileURLWithPath: "/usr/bin/gunzip")
    /// Names macOS adds to archives that shouldn't be carried into a repack.
    private static let metadataNames: Set<String> = ["__MACOSX", ".DS_Store"]
    /// Names are passed to tar as "./name" so ones starting with "-" or "@"
    /// aren't read as options; this strips the "./" again inside the archive,
    /// leaving symlink targets untouched.
    private static let stripDotSlash = ",^\\./,,S"

    func convert(_ input: URL, to target: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        progress(0)
        if let format = FileFormat(fileName: input.lastPathComponent), format.family == .archive,
           !Self.isDirectory(input) {
            try await repack(input, as: format, to: target, output: output)
        } else {
            try await pack([input], from: input.deletingLastPathComponent(), to: target, output: output, keepParent: true)
        }
        progress(1)
    }

    /// Extracts into a scratch folder, then packs what came out.
    private func repack(_ archive: URL, as source: FileFormat, to target: FileFormat, output: URL) async throws(ConversionError) {
        let scratch = try Self.makeScratchDirectory(near: output)
        WorkInProgress.shared.add(scratch)
        defer {
            try? FileManager.default.removeItem(at: scratch)
            WorkInProgress.shared.remove(scratch)
        }

        try await extract(archive, as: source, into: scratch)
        Self.removeMetadata(in: scratch)
        let contents = try Self.visibleContents(of: scratch)
        guard !contents.isEmpty else { throw .unreadableInput(archive.lastPathComponent) }
        try await pack(contents, from: scratch, to: target, output: output, keepParent: contents.count == 1)
    }

    private func extract(_ archive: URL, as source: FileFormat, into directory: URL) async throws(ConversionError) {
        let name = archive.lastPathComponent.lowercased()
        let isPlainGzip = source == .gzip && !name.hasSuffix(".tar.gz") && !name.hasSuffix(".tgz")
        if isPlainGzip {
            // A single gzipped file: decompress it under its original name.
            let stem = String(archive.lastPathComponent.dropLast(".gz".count))
            let target = directory.appendingPathComponent(stem.isEmpty ? "file" : stem)
            try await ProcessRunner.run(Self.gunzip, arguments: ["-c", archive.path], standardOutputFile: target)
        } else if source == .zip {
            // bsdtar rejects ZIPs that carry Apple "._" resource entries, which
            // many Mac-made ZIPs do; ditto reads them and keeps paths inside
            // the target folder.
            try await ProcessRunner.run(Self.ditto, arguments: ["-x", "-k", archive.path, directory.path])
        } else {
            try await ProcessRunner.run(Self.tar, arguments: ["-xf", archive.path, "-C", directory.path])
        }
    }

    /// Packs `items` (all inside `base`) into `output`.
    private func pack(_ items: [URL], from base: URL, to target: FileFormat, output: URL, keepParent: Bool) async throws(ConversionError) {
        let names = items.map(\.lastPathComponent)
        switch target {
        case .zip:
            if keepParent, let only = items.first, items.count == 1 {
                try await ProcessRunner.run(Self.ditto, arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", only.path, output.path])
            } else {
                try await ProcessRunner.run(Self.ditto, arguments: ["-c", "-k", "--sequesterRsrc", base.path, output.path])
            }
        case .tar, .gzip:
            let create = target == .gzip ? "-czf" : "-cf"
            let safeNames = names.map { "./" + $0 }
            try await ProcessRunner.run(Self.tar, arguments: [create, output.path, "-s", Self.stripDotSlash, "-C", base.path] + safeNames)
        default:
            throw .unsupported(input: names.joined(separator: ", "), target: target)
        }
    }

    /// A scratch folder on the same volume as the output, so large archives
    /// don't fill the startup disk.
    private static func makeScratchDirectory(near output: URL) throws(ConversionError) -> URL {
        do {
            return try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: output, create: true)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    /// ZIPs made on a Mac often carry these; they would otherwise end up
    /// inside the repacked archive.
    private static func removeMetadata(in directory: URL) {
        for name in metadataNames {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Top-level items, in name order.
    private static func visibleContents(of directory: URL) throws(ConversionError) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { !metadataNames.contains($0.lastPathComponent) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw .unreadableInput(directory.lastPathComponent)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
