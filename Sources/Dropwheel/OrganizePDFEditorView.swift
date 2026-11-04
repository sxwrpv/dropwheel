import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Organize Pages: reorder, turn, duplicate or remove a PDF's pages on a grid.
struct OrganizePDFEditorView: View {
    let url: URL
    let onSave: (ToolOptions) -> Void
    let onCancel: () -> Void

    @State private var cache: PDFThumbnailCache?
    @State private var pageCount = 0
    @State private var pages: [PDFPageSlot] = []
    /// The page lists before each edit, newest last.
    @State private var history: [[PDFPageSlot]] = []
    @State private var selection: Set<UUID> = []
    @State private var problem: String?
    @State private var warning: String?

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            if let warning { EditorNote(text: warning) }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            EditorFooter(canSave: !pages.isEmpty && pages.hasChanges(fromPageCount: pageCount), onCancel: onCancel,
                         onSave: { onSave(.pdfPages(pages)) }) {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .task { await load() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { rotate(by: -1) } label: { Label("Rotate Left", systemImage: "rotate.left") }
            Button { rotate(by: 1) } label: { Label("Rotate Right", systemImage: "rotate.right") }
            Button(action: duplicate) { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(action: remove) { Label("Remove", systemImage: "trash") }
            Spacer()
            Button(action: undo) { Label("Undo", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(history.isEmpty)
        }
        .disabled(cache == nil)
    }

    @ViewBuilder private var content: some View {
        if let cache {
            PDFPageGrid(pages: pages, selection: $selection, cache: cache, onMove: move, onDelete: remove)
        } else if let problem {
            ContentUnavailableNote(text: problem)
        } else {
            ProgressView("Reading \(url.lastPathComponent)…")
        }
    }

    private var summary: String {
        if pages.isEmpty { return cache == nil ? "" : "Keep at least one page" }
        let count = "\(pages.count) \(pages.count == 1 ? "page" : "pages")"
        return selection.isEmpty ? "\(count) · select pages to change them" : "\(count) · \(selection.count) selected"
    }

    private func apply(_ edited: [PDFPageSlot]) {
        history = history + [pages]
        pages = edited
    }

    private func rotate(by quarterTurns: Int) {
        guard !selection.isEmpty else { return }
        apply(pages.rotating(selection, by: quarterTurns))
    }

    /// The copies end up selected, ready to be moved.
    private func duplicate() {
        guard !selection.isEmpty else { return }
        let existing = Set(pages.map(\.id))
        let doubled = pages.duplicating(selection)
        apply(doubled)
        selection = Set(doubled.map(\.id)).subtracting(existing)
    }

    private func remove() {
        guard !selection.isEmpty else { return }
        apply(pages.removing(selection))
        selection = []
    }

    private func move(_ ids: Set<UUID>, to destination: Int) {
        let moved = pages.moving(ids, to: destination)
        if moved != pages { apply(moved) }
    }

    private func undo() {
        guard let previous = history.last else { return }
        history = Array(history.dropLast())
        pages = previous
        selection = selection.intersection(previous.map(\.id))
    }

    /// Opened away from the main thread, as a long PDF takes time to index.
    private func load() async {
        let opened = await Task.detached { [url] in
            Result { () throws(ConversionError) in try PDFThumbnails(url: url) }
        }.value
        switch opened {
        case .success(let thumbnails):
            pageCount = thumbnails.pageCount
            pages = .allPages(count: thumbnails.pageCount)
            cache = PDFThumbnailCache(thumbnails: thumbnails)
            warning = await MediaPreview.copyWarning(for: url)
        case .failure(let error):
            problem = error.localizedDescription
        }
    }
}
