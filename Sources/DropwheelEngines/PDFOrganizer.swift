import CoreGraphics
import DropwheelCore
import Foundation
import PDFKit

extension PDFTools {
    /// Puts the PDF's pages into the order and turning of `slots`. The
    /// document is changed in place, as a new one would lose its bookmarks
    /// and any links between pages.
    static func organize(_ input: URL, pages slots: [PDFPageSlot], output: URL) throws(ConversionError) {
        guard !isEncrypted(input) else { throw .passwordProtected(input.lastPathComponent) }
        let document = try open(input)
        guard !slots.isEmpty else { throw .noPagesLeft(input.lastPathComponent) }
        let originals = (0..<document.pageCount).compactMap(document.page(at:))
        guard originals.count == document.pageCount, slots.allSatisfy({ originals.indices.contains($0.sourceIndex) }) else {
            throw .unreadableInput(input.lastPathComponent)
        }
        let rotations = originals.map(\.rotation)

        let kept = Set(slots.map(\.sourceIndex))
        let removed = Set(originals.indices).subtracting(kept)
        removePointers(to: removed, in: document)
        for index in removed.sorted(by: >) {
            document.removePage(at: index)
        }

        // The first use of a page is the page itself, so what points at it
        // still does; any further use is a copy.
        var seen = Set<Int>()
        let isFirstUse = slots.map { seen.insert($0.sourceIndex).inserted }
        let firstUses = zip(slots, isFirstUse).filter(\.1).map { originals[$0.0.sourceIndex] }
        for (position, page) in firstUses.enumerated() {
            let current = document.index(for: page)
            if current != position {
                document.exchangePage(at: current, withPageAt: position)
            }
        }
        // Copies go straight to their places: PDFKit raises an exception,
        // which Swift can't catch, if asked to exchange one.
        for (position, slot) in slots.enumerated() where !isFirstUse[position] {
            guard let copy = originals[slot.sourceIndex].copy() as? PDFPage else { throw .unreadableInput(input.lastPathComponent) }
            document.insert(copy, at: position)
        }
        for (position, slot) in slots.enumerated() {
            document.page(at: position)?.rotation = (rotations[slot.sourceIndex] + slot.quarterTurns * 90) % 360
        }
        guard document.write(to: output) else { throw .writeFailed("The PDF couldn’t be saved.") }

        // PDFKit stamps its own producer and dates. Only the change date is right.
        let changeDate = PDFDocumentAttribute.modificationDateAttribute.rawValue
        var info = PDFInfo.entries(of: input)
        info[changeDate] = PDFInfo.entries(of: output)[changeDate]
        try PDFInfo.write(info, in: output)
        try PDFMetadata.refreshPacket(of: input, in: output, previewIsStale: slots[0].sourceIndex != 0)
    }

    /// Bookmarks and links to a removed page would land on the wrong page.
    /// Run before the pages go, while they can still be told apart.
    private static func removePointers(to removed: Set<Int>, in document: PDFDocument) {
        guard !removed.isEmpty else { return }
        let isRemoved: (PDFDestination?) -> Bool = { destination in
            destination?.page.map { removed.contains(document.index(for: $0)) } ?? false
        }
        for page in (0..<document.pageCount).compactMap(document.page(at:)) {
            page.annotations.filter { isRemoved($0.destination) }.forEach(page.removeAnnotation)
        }
        if let root = document.outlineRoot {
            removeBookmarks(under: root, where: isRemoved)
        }
    }

    /// A bookmark with others under it stays as a heading that goes nowhere.
    private static func removeBookmarks(under item: PDFOutline, where isRemoved: (PDFDestination?) -> Bool) {
        for index in (0..<item.numberOfChildren).reversed() {
            guard let child = item.child(at: index) else { continue }
            removeBookmarks(under: child, where: isRemoved)
            guard isRemoved(child.destination) else { continue }
            if child.numberOfChildren == 0 {
                child.removeFromParent()
            } else {
                child.action = nil
                child.destination = nil
            }
        }
    }
}

/// Draws a PDF's pages small, one at a time, for the page organizer.
public actor PDFThumbnails {
    public nonisolated let pageCount: Int
    private let document: CGPDFDocument

    public init(url: URL) throws(ConversionError) {
        guard let document = CGPDFDocument(url as CFURL) else { throw .unreadableInput(url.lastPathComponent) }
        if document.isEncrypted { throw .passwordProtected(url.lastPathComponent) }
        self.document = document
        pageCount = document.numberOfPages
    }

    /// `index` is zero-based and `quarterTurns` clockwise.
    public func image(ofPage index: Int, quarterTurns: Int, longEdge: Double) throws(ConversionError) -> CGImage {
        // Requests queue here, and a page scrolled past needn't be drawn.
        try Task.checkCancellation(or: .cancelled)
        guard let page = document.page(at: index + 1) else { throw .unreadableInput("PDF page") }
        return try PDFPageRenderer.render(page, maximumLongEdge: longEdge, quarterTurns: quarterTurns)
    }
}

/// Parts of a PDF that PDFKit's saves don't carry, for the editors to name
/// before anything is lost.
public enum PDFStructure {
    public static func partsNotKept(in url: URL) -> [String] {
        guard let document = CGPDFDocument(url as CFURL) else { return [] }
        return withExtendedLifetime(document) {
            guard let catalog = document.catalog else { return [] }
            var names: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(catalog, "Names", &names)
            let parts: [(name: String, isPresent: Bool)] = [
                ("attachments", names.map { has($0, "EmbeddedFiles") } ?? false),
                ("scripts", names.map { has($0, "JavaScript") } ?? false),
                ("accessibility tags", has(catalog, "StructTreeRoot")),
                ("page labels", has(catalog, "PageLabels")),
                ("page scale", isScaled(document)),
            ]
            return parts.filter(\.isPresent).map(\.name)
        }
    }

    /// A sentence naming `parts`, or nil if nothing is lost.
    public static func warning(for parts: [String]) -> String? {
        guard let last = parts.last else { return nil }
        let earlier = parts.dropLast().joined(separator: ", ")
        return "A saved copy leaves out this PDF’s \(earlier.isEmpty ? last : "\(earlier) and \(last)")."
    }

    private static func has(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &object)
    }

    /// Pages can declare a unit other than 1/72 inch, which sets their real size.
    private static func isScaled(_ document: CGPDFDocument) -> Bool {
        guard document.numberOfPages > 0 else { return false }
        return (1...document.numberOfPages).contains { number in
            var unit: CGPDFReal = 1
            guard let page = document.page(at: number)?.dictionary else { return false }
            return CGPDFDictionaryGetNumber(page, "UserUnit", &unit) && unit != 1
        }
    }
}
