import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Redact: hide parts of a picture behind a solid box, a blur or pixels.
/// Drag to add a box, click a box to remove it, or let Vision find faces
/// and text.
struct RedactEditorView: View {
    /// Larger than the other editors' previews, so Vision can read small text.
    private static let previewEdge = 2048
    private static let smallestDrag = 0.005
    private static let renderDebounce: Duration = .milliseconds(30)

    let url: URL
    let onSave: (ToolOptions) -> Void
    let onCancel: () -> Void

    @State private var original: CGImage?
    @State private var rendered: CGImage?
    @State private var loadError: String?
    @State private var regions: [RedactionRegion] = []
    @State private var draft: RedactionRegion?
    @State private var style = RedactionStyle.solid
    @State private var searching = false
    @State private var note: String?

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            canvas
            // Saving mid-search would leave out whatever the search is about to find.
            EditorFooter(canSave: original != nil && !regions.isEmpty && !searching, onCancel: onCancel,
                         onSave: { onSave(.redactions(regions)) }) {
                HStack(spacing: 8) {
                    Button("Undo") { regions = Array(regions.dropLast()) }
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(regions.isEmpty)
                    Button("Clear") { regions = [] }
                        .disabled(regions.isEmpty)
                    if let note {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .task { await load() }
        // Blurs are slow at full preview size, so committed boxes render off
        // the main thread; a box being dragged shows as an outline until then.
        .task(id: regions) {
            try? await Task.sleep(for: Self.renderDebounce)
            guard !Task.isCancelled else { return }
            await render()
        }
        // One style for every box, so the saved copy looks consistent.
        .onChange(of: style) { newStyle in
            regions = regions.map { RedactionRegion(id: $0.id, rect: $0.rect, style: newStyle) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Style", selection: $style) {
                ForEach(RedactionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            Spacer()
            if searching { ProgressView().controlSize(.small) }
            Button { find(.faces) } label: { Label("Find Faces", systemImage: "person.crop.square") }
                .disabled(original == nil || searching)
            Button { find(.text) } label: { Label("Find Text", systemImage: "text.viewfinder") }
                .disabled(original == nil || searching)
        }
    }

    @ViewBuilder private var canvas: some View {
        if let image = rendered ?? original {
            PhotoCanvas(image: image, onDrag: dragged, onDragEnd: dragEnded) { size in
                // Outlines show every box, even blurred ones that blend in.
                ForEach(regions + (draft.map { [$0] } ?? [])) { region in
                    Rectangle()
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: region.rect.width * size.width, height: region.rect.height * size.height)
                        .offset(x: region.rect.x * size.width, y: region.rect.y * size.height)
                        .allowsHitTesting(false)
                }
            }
        } else if let loadError {
            ContentUnavailableNote(text: loadError)
        } else {
            ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Editing

    private func dragged(from start: NormalizedPoint, to current: NormalizedPoint) {
        guard hypot(current.x - start.x, current.y - start.y) >= Self.smallestDrag else { return }
        draft = RedactionRegion(id: draft?.id ?? UUID(), rect: AnnotationGeometry.rect(from: start, to: current), style: style)
    }

    /// A drag adds its box; a click on a box removes that box.
    private func dragEnded(from start: NormalizedPoint, to end: NormalizedPoint) {
        if let draft {
            regions = regions + [draft]
        } else if let hit = regions.last(where: { contains($0.rect, end) }) {
            regions = regions.filter { $0.id != hit.id }
        }
        draft = nil
    }

    private func contains(_ rect: CropRecipe, _ point: NormalizedPoint) -> Bool {
        point.x >= rect.x && point.x <= rect.x + rect.width && point.y >= rect.y && point.y <= rect.y + rect.height
    }

    private func find(_ kind: PhotoRendering.Detection) {
        guard let original else { return }
        searching = true
        note = nil
        let style = style
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws(ConversionError) in try PhotoRendering.detect([kind], in: original, style: style) }
            }.value
            searching = false
            switch result {
            case .success(let found):
                let new = found.filter { candidate in !regions.contains { $0.rect == candidate.rect } }
                regions = regions + new
                note = Self.findingNote(count: new.count, kind: kind)
            case .failure(let error):
                note = error.localizedDescription
            }
        }
    }

    private static func findingNote(count: Int, kind: PhotoRendering.Detection) -> String {
        switch (kind, count) {
        case (.faces, 0): "No faces found"
        case (.faces, 1): "Found 1 face"
        case (.faces, _): "Found \(count) faces"
        case (.text, 0): "No text found"
        case (.text, 1): "Found 1 line of text"
        case (.text, _): "Found \(count) lines of text"
        }
    }

    private func render() async {
        guard let original else { return }
        let regions = regions
        let result = await Task.detached(priority: .userInitiated) {
            Result { () throws(ConversionError) in try PhotoRendering.redacted(original, regions) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let image): rendered = image
        case .failure(let error):
            // Never leave an older, less-redacted preview on screen.
            rendered = nil
            note = error.localizedDescription
        }
    }

    private func load() async {
        switch await PreviewImage.loadInBackground(url, maximumEdge: Self.previewEdge) {
        case .success(let loaded): original = loaded.image
        case .failure(let error): loadError = error.localizedDescription
        }
    }
}
