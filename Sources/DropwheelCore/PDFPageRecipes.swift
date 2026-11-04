import Foundation

/// One page of an organized PDF: a page of the original plus any turning.
/// A duplicated page has a slot of its own.
public struct PDFPageSlot: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Zero-based, in the original PDF.
    public let sourceIndex: Int
    /// Clockwise, 0 to 3, on top of however the page is already turned.
    public let quarterTurns: Int

    public init(id: UUID = UUID(), sourceIndex: Int, quarterTurns: Int = 0) {
        self.id = id
        self.sourceIndex = sourceIndex
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
    }
}

extension [PDFPageSlot] {
    /// A PDF's pages as they are.
    public static func allPages(count: Int) -> [PDFPageSlot] {
        (0..<count).map { PDFPageSlot(sourceIndex: $0) }
    }

    /// `quarterTurns` is clockwise; negative turns the other way.
    public func rotating(_ ids: Set<UUID>, by quarterTurns: Int) -> [PDFPageSlot] {
        map { slot in
            guard ids.contains(slot.id) else { return slot }
            return PDFPageSlot(id: slot.id, sourceIndex: slot.sourceIndex, quarterTurns: slot.quarterTurns + quarterTurns)
        }
    }

    /// Each copy lands right after its page.
    public func duplicating(_ ids: Set<UUID>) -> [PDFPageSlot] {
        flatMap { slot in
            ids.contains(slot.id) ? [slot, PDFPageSlot(sourceIndex: slot.sourceIndex, quarterTurns: slot.quarterTurns)] : [slot]
        }
    }

    public func removing(_ ids: Set<UUID>) -> [PDFPageSlot] {
        filter { !ids.contains($0.id) }
    }

    /// Moves the pages, keeping their order among themselves, to `destination`,
    /// a position in the list as it is before the move.
    public func moving(_ ids: Set<UUID>, to destination: Int) -> [PDFPageSlot] {
        let held = Swift.min(Swift.max(destination, 0), count)
        let before = self[..<held].filter { !ids.contains($0.id) }
        let after = self[held...].filter { !ids.contains($0.id) }
        return before + filter { ids.contains($0.id) } + after
    }

    /// False for the PDF's own pages, in order, unturned.
    public func hasChanges(fromPageCount pageCount: Int) -> Bool {
        map(\.sourceIndex) != Array<Int>(0..<pageCount) || contains { $0.quarterTurns != 0 }
    }
}
