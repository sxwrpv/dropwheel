import Foundation
import Testing
@testable import DropwheelCore

@Suite("FilePaths")
struct FilePathsTests {
    private let folder = URL(fileURLWithPath: "/tmp/a", isDirectory: true)

    @Test("Copy Path puts one path per line in selection order")
    func copyPathText() {
        let urls = [URL(fileURLWithPath: "/tmp/a/photo.jpg"), URL(fileURLWithPath: "/tmp/b c/notes.txt")]
        #expect(FilePaths.copyPathText(for: urls) == "/tmp/a/photo.jpg\n/tmp/b c/notes.txt")
    }

    @Test("Terminal opens a folder itself")
    func terminalFolder() {
        #expect(FilePaths.terminalDirectory(for: folder, isDirectory: { _ in true }) == folder)
    }

    @Test("Terminal opens a file's containing folder")
    func terminalFile() {
        let file = folder.appendingPathComponent("photo.jpg")
        #expect(FilePaths.terminalDirectory(for: file, isDirectory: { _ in false }).path == "/tmp/a")
    }

    @Test("Unique destination keeps the name when it is free")
    func freeName() {
        let url = FilePaths.uniqueDestination(for: "photo.jpg", in: folder, exists: { _ in false })
        #expect(url.lastPathComponent == "photo.jpg")
    }

    @Test("Clashes are numbered Finder-style")
    func numbered() {
        let taken: Set<String> = ["photo.jpg", "photo 2.jpg"]
        let url = FilePaths.uniqueDestination(for: "photo.jpg", in: folder, exists: { taken.contains($0.lastPathComponent) })
        #expect(url.lastPathComponent == "photo 3.jpg")
    }

    @Test("Names without an extension are numbered too",
          arguments: [("Makefile", "Makefile 2"), (".env", ".env 2"), ("archive.tar.gz", "archive.tar 2.gz")])
    func extensionEdgeCases(name: String, expected: String) {
        let url = FilePaths.uniqueDestination(for: name, in: folder, exists: { $0.lastPathComponent == name })
        #expect(url.lastPathComponent == expected)
    }

    @Test("Folders keep dots in their name when numbered, like Finder")
    func folderNumbering() {
        let url = FilePaths.uniqueDestination(for: "My.Folder", in: folder, isDirectory: true,
                                              exists: { $0.lastPathComponent == "My.Folder" })
        #expect(url.lastPathComponent == "My.Folder 2")
    }

    @Test("A folder contains itself and its descendants, but not siblings",
          arguments: [
              ("/tmp/a", true),
              ("/tmp/a/", true),
              ("/tmp/a/b/c", true),
              ("/tmp/ab", false),
              ("/tmp", false),
          ])
    func containment(candidate: String, expected: Bool) {
        let ancestor = URL(fileURLWithPath: "/tmp/a", isDirectory: true)
        #expect(FilePaths.isSameOrInside(URL(fileURLWithPath: candidate), ancestor) == expected)
    }

    @Test("Containment ignores letter case, as APFS does by default")
    func containmentIgnoresCase() {
        let ancestor = URL(fileURLWithPath: "/tmp/Photos", isDirectory: true)
        #expect(FilePaths.isSameOrInside(URL(fileURLWithPath: "/tmp/photos/2026"), ancestor))
    }

    @Test("Conversion wheel lists the selection's shared targets")
    func conversionCatalog() {
        let items = WheelCatalog.items(for: .conversions, selection: [.input(.heic), .input(.png)])
        #expect(items.map(\.label) == ["JPG", "WEBP", "TIFF", "AVIF", "BMP", "PDF"])
        #expect(items.first?.title == "Convert to JPG")
        #expect(items.first?.action == .convert(.jpg))
    }

    @Test("Conversion wheel is empty when nothing is shared")
    func emptyConversionCatalog() {
        #expect(WheelCatalog.items(for: .conversions, selection: [.unknown]).isEmpty)
    }

    @Test("Tools wheel lists the tools for the selection")
    func toolCatalog() {
        let items = WheelCatalog.items(for: .tools, selection: [.input(.pdf), .input(.pdf)])
        #expect(items.map(\.label) == ["COMPRESS", "METADATA", "TAGS", "PAGES", "MERGE"])
        #expect(items.last?.title == "Merge PDFs")
        #expect(items.last?.action == .tool(.mergePDFs))
    }

    @Test("Action wheel lists all six actions in order")
    func actionCatalog() {
        let titles = WheelCatalog.items(for: .actions).map(\.title)
        #expect(titles == ["AirDrop", "Float", "Copy", "Move", "Copy Path", "Terminal"])
    }
}
