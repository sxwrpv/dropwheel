import Foundation

/// Temporary folders for intermediate files, on the same volume as the
/// output so large files aren't copied across disks. They are registered as
/// work in progress, so quitting mid-conversion still removes them.
enum ScratchSpace {
    static func make(near url: URL) throws(ConversionError) -> URL {
        do {
            let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                        appropriateFor: url, create: true)
            WorkInProgress.shared.add(directory)
            return directory
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    static func discard(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        WorkInProgress.shared.remove(directory)
    }
}

/// Reads text files whose encoding isn't declared.
enum TextFile {
    /// UTF-16 is only tried when a byte-order mark says so, because UTF-16
    /// decoding accepts almost any bytes and would turn Windows-1252 text
    /// into nonsense.
    static func read(_ url: URL) throws(ConversionError) -> String {
        guard let data = try? Data(contentsOf: url) else { throw .unreadableInput(url.lastPathComponent) }
        let hasUTF16Mark = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let encodings: [String.Encoding] = hasUTF16Mark ? [.utf16] : [.utf8, .windowsCP1252, .isoLatin1]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw .unreadableInput(url.lastPathComponent)
    }

    static func write(_ text: String, to url: URL) throws(ConversionError) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }
}

extension URL {
    /// The file name without its format extension.
    var formatStem: String {
        let name = lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") { return String(name.dropLast(".tar.gz".count)) }
        return deletingPathExtension().lastPathComponent
    }
}
