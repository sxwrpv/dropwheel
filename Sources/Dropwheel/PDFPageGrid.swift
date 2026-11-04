import AppKit
import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Page pictures for the grid, kept while they fit in memory.
@MainActor
final class PDFThumbnailCache {
    /// Twice the size a page is drawn at, for Retina screens.
    private static let longEdge = 320.0

    private let thumbnails: PDFThumbnails
    private let images = NSCache<NSString, NSImage>()

    init(thumbnails: PDFThumbnails) {
        self.thumbnails = thumbnails
    }

    func image(for slot: PDFPageSlot) async -> NSImage? {
        let key = "\(slot.sourceIndex)-\(slot.quarterTurns)" as NSString
        if let image = images.object(forKey: key) { return image }
        guard let image = try? await thumbnails.image(ofPage: slot.sourceIndex, quarterTurns: slot.quarterTurns,
                                                      longEdge: Self.longEdge) else { return nil }
        let picture = NSImage(size: NSSize(width: image.width / 2, height: image.height / 2), flipped: false) { bounds in
            NSGraphicsContext.current?.cgContext.draw(image, in: bounds)
            // A white page needs an edge to show up against the window.
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
        images.setObject(picture, forKey: key)
        return picture
    }
}

/// The pages as a grid. Click, Shift-click or drag across to select, drag to
/// reorder, Delete to remove. A collection view brings all of that, and
/// scrolling a long PDF during a drag, for free.
struct PDFPageGrid: NSViewRepresentable {
    let pages: [PDFPageSlot]
    @Binding var selection: Set<UUID>
    let cache: PDFThumbnailCache
    let onMove: (Set<UUID>, Int) -> Void
    let onDelete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = context.coordinator.collectionView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.show(pages, selection: selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate {
        private static let itemSize = NSSize(width: 160, height: 200)
        private static let spacing: CGFloat = 12
        private static let dragType = NSPasteboard.PasteboardType("dev.dropwheel.pdf-page")

        var parent: PDFPageGrid
        let collectionView = PageCollectionView()
        private var dataSource: NSCollectionViewDiffableDataSource<Int, PDFPageSlot>?
        private var dragged: Set<UUID> = []

        init(parent: PDFPageGrid) {
            self.parent = parent
            super.init()
            configure()
        }

        private func configure() {
            let layout = NSCollectionViewFlowLayout()
            layout.itemSize = Self.itemSize
            layout.minimumInteritemSpacing = Self.spacing
            layout.minimumLineSpacing = Self.spacing
            layout.sectionInset = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            collectionView.collectionViewLayout = layout
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = true
            collectionView.backgroundColors = [.clear]
            collectionView.delegate = self
            collectionView.register(PageItem.self, forItemWithIdentifier: PageItem.identifier)
            collectionView.registerForDraggedTypes([Self.dragType])
            collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
            collectionView.onDelete = { [weak self] in self?.parent.onDelete() }
            dataSource = NSCollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] view, indexPath, slot in
                guard let self, let item = view.makeItem(withIdentifier: PageItem.identifier, for: indexPath) as? PageItem else { return nil }
                item.show(slot, number: indexPath.item + 1, cache: parent.cache)
                return item
            }
        }

        func show(_ pages: [PDFPageSlot], selection: Set<UUID>) {
            guard let dataSource else { return }
            let shown = dataSource.snapshot().itemIdentifiers
            if shown != pages {
                var snapshot = NSDiffableDataSourceSnapshot<Int, PDFPageSlot>()
                snapshot.appendSections([0])
                snapshot.appendItems(pages)
                // A long PDF shouldn't fade in page by page.
                dataSource.apply(snapshot, animatingDifferences: !shown.isEmpty)
                renumberVisibleItems()
            }
            let wanted = Set(pages.indices.filter { selection.contains(pages[$0].id) }.map { IndexPath(item: $0, section: 0) })
            if collectionView.selectionIndexPaths != wanted {
                collectionView.selectionIndexPaths = wanted
            }
        }

        /// A move changes the numbers of pages that themselves stayed put.
        private func renumberVisibleItems() {
            for item in collectionView.visibleItems() {
                guard let page = item as? PageItem, let indexPath = collectionView.indexPath(for: item) else { continue }
                page.number = indexPath.item + 1
            }
        }

        private func ids(at indexPaths: Set<IndexPath>) -> Set<UUID> {
            Set(indexPaths.compactMap { dataSource?.itemIdentifier(for: $0)?.id })
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            parent.selection = ids(at: collectionView.selectionIndexPaths)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            parent.selection = ids(at: collectionView.selectionIndexPaths)
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            let item = NSPasteboardItem()
            item.setString(String(indexPath.item), forType: Self.dragType)
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                            willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            dragged = ids(at: indexPaths)
        }

        func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard !dragged.isEmpty else { return [] }
            proposedDropOperation.pointee = .before
            return .move
        }

        func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
                            dropOperation: NSCollectionView.DropOperation) -> Bool {
            parent.onMove(dragged, indexPath.item)
            return true
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                            endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
            dragged = []
        }
    }
}

final class PageCollectionView: NSCollectionView {
    var onDelete: (() -> Void)?

    /// Finder usually stays frontmost after a drop; the first click should still select.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        let isDelete = event.specialKey == .delete || event.specialKey == .deleteForward
        if isDelete, !selectionIndexPaths.isEmpty {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// One page: its picture and its place in the new order.
private final class PageItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("page")
    private static let cornerRadius: CGFloat = 8
    private static let inset: CGFloat = 6
    private static let labelHeight: CGFloat = 18

    private let picture = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var loading: Task<Void, Never>?

    var number = 0 {
        didSet { label.stringValue = String(number) }
    }

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateHighlight() }
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.cornerRadius
        picture.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        for view in [picture, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.inset),
            picture.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.inset),
            picture.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.inset),
            picture.bottomAnchor.constraint(equalTo: label.topAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            label.heightAnchor.constraint(equalToConstant: Self.labelHeight),
        ])
        view = container
    }

    func show(_ slot: PDFPageSlot, number: Int, cache: PDFThumbnailCache) {
        self.number = number
        loading?.cancel()
        loading = Task { [weak self] in
            let image = await cache.image(for: slot)
            guard !Task.isCancelled else { return }
            self?.picture.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        picture.image = nil
    }

    private func updateHighlight() {
        let isMarked = isSelected || highlightState == .forSelection
        view.layer?.backgroundColor = isMarked ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil
    }
}
