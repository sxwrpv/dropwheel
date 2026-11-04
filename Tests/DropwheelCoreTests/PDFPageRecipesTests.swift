import Foundation
import Testing
@testable import DropwheelCore

struct PDFPageRecipesTests {
    private let pages = [PDFPageSlot].allPages(count: 4)

    private func sources(_ slots: [PDFPageSlot]) -> [Int] {
        slots.map(\.sourceIndex)
    }

    @Test("A new list has every page in order with no turns")
    func allPages() {
        #expect(sources(pages) == [0, 1, 2, 3])
        #expect(pages.allSatisfy { $0.quarterTurns == 0 })
        #expect(Set(pages.map(\.id)).count == 4)
    }

    @Test("Rotating turns only the chosen pages")
    func rotatesChosenPages() {
        let turned = pages.rotating([pages[1].id], by: 1)
        #expect(turned.map(\.quarterTurns) == [0, 1, 0, 0])
        #expect(turned.map(\.id) == pages.map(\.id))
    }

    @Test("Turns wrap in both directions", arguments: [(1, 1), (-1, 3), (4, 0), (5, 1), (-6, 2)])
    func turnsWrap(turns: Int, expected: Int) {
        #expect(pages.rotating([pages[0].id], by: turns)[0].quarterTurns == expected)
    }

    @Test("A duplicate lands right after its page, with the same turns and its own identity")
    func duplicates() {
        let turned = pages.rotating([pages[1].id], by: 3)
        let doubled = turned.duplicating([pages[1].id])
        #expect(sources(doubled) == [0, 1, 1, 2, 3])
        #expect(doubled[2].quarterTurns == 3)
        #expect(doubled[1].id == pages[1].id)
        #expect(doubled[2].id != pages[1].id)
    }

    @Test("Duplicating two pages copies each one where it is")
    func duplicatesSeveral() {
        #expect(sources(pages.duplicating([pages[0].id, pages[2].id])) == [0, 0, 1, 2, 2, 3])
    }

    @Test("Removing leaves the rest in order")
    func removes() {
        #expect(sources(pages.removing([pages[0].id, pages[2].id])) == [1, 3])
    }

    @Test("Moving a page later counts the destination in the current list")
    func movesLater() {
        #expect(sources(pages.moving([pages[0].id], to: 3)) == [1, 2, 0, 3])
        #expect(sources(pages.moving([pages[0].id], to: 4)) == [1, 2, 3, 0])
    }

    @Test("Moving a page earlier")
    func movesEarlier() {
        #expect(sources(pages.moving([pages[3].id], to: 0)) == [3, 0, 1, 2])
    }

    @Test("Several pages move together and keep their order, wherever they started")
    func movesSeveral() {
        #expect(sources(pages.moving([pages[3].id, pages[0].id], to: 2)) == [1, 0, 3, 2])
    }

    @Test("Dropping a block inside itself leaves it there")
    func movesInsideItself() {
        #expect(sources(pages.moving([pages[1].id, pages[2].id], to: 2)) == sources(pages))
    }

    @Test("A destination past either end is held to the list", arguments: [(-3, [3, 0, 1, 2]), (99, [0, 1, 2, 3])])
    func clampsDestination(destination: Int, expected: [Int]) {
        #expect(sources(pages.moving([pages[3].id], to: destination)) == expected)
    }

    @Test("An untouched list has nothing to save")
    func untouched() {
        #expect(!pages.hasChanges(fromPageCount: 4))
        #expect(!pages.rotating([pages[0].id], by: 4).hasChanges(fromPageCount: 4))
    }

    @Test("Any edit counts as a change")
    func changes() {
        #expect(pages.rotating([pages[0].id], by: 1).hasChanges(fromPageCount: 4))
        #expect(pages.moving([pages[0].id], to: 2).hasChanges(fromPageCount: 4))
        #expect(pages.duplicating([pages[0].id]).hasChanges(fromPageCount: 4))
        #expect(pages.removing([pages[0].id]).hasChanges(fromPageCount: 4))
    }

    @Test("Organize Pages is a PDF tool that opens an editor")
    func catalog() {
        #expect(ToolCatalog.tools(for: [.input(.pdf)]).contains(.organizePDF))
        #expect(ToolKind.organizePDF.opensEditor)
        #expect(!ToolKind.organizePDF.usesWholeSelection)
        #expect(!ToolCatalog.tools(for: [.input(.png)]).contains(.organizePDF))
    }
}
