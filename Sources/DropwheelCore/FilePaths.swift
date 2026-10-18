import Foundation

/// Path helpers shared by the file actions.
public enum FilePaths {
    /// Full paths, one per line, in the order given.
    public static func copyPathText(for urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }

    /// The folder Terminal should open: the item itself if it is a folder,
    /// otherwise its containing folder.
    public static func terminalDirectory(for url: URL, isDirectory: (URL) -> Bool) -> URL {
        isDirectory(url) ? url : url.deletingLastPathComponent()
    }

    /// A destination in `directory` named like `fileName` that does not exist
    /// yet. Clashes get Finder-style numbering: "photo.jpg", "photo 2.jpg", ...
    /// Folders are numbered after the whole name ("My.Folder 2"), as Finder does.
    public static func uniqueDestination(
        for fileName: String,
        in directory: URL,
        isDirectory: Bool = false,
        exists: (URL) -> Bool
    ) -> URL {
        let first = directory.appendingPathComponent(fileName)
        guard exists(first) else { return first }

        let (stem, ext) = isDirectory ? (fileName, "") : splitExtension(fileName)
        var counter = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }

    /// Whether `candidate` is `ancestor` itself or somewhere inside it.
    /// Symlinks are resolved and letter case is ignored, matching the
    /// default case-insensitive APFS volume.
    public static func isSameOrInside(_ candidate: URL, _ ancestor: URL) -> Bool {
        let candidatePath = normalizedPath(candidate)
        let ancestorPath = normalizedPath(ancestor)
        return candidatePath == ancestorPath || candidatePath.hasPrefix(ancestorPath + "/")
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Splits "archive.tar.gz" into ("archive.tar", "gz"). Names with no dot,
    /// or only a leading dot such as ".env", have no extension.
    static func splitExtension(_ fileName: String) -> (stem: String, ext: String) {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return (fileName, "")
        }
        let stem = String(fileName[..<dot])
        let ext = String(fileName[fileName.index(after: dot)...])
        return (stem, ext)
    }
}
