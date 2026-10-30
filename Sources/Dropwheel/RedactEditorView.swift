import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Redact for photos and videos: hide parts of a picture behind a solid
/// box, a blur or pixels. Drag to add a box, click a box to remove it, or
/// let Vision find faces (and, in photos, text). In a video the boxes stay
/// in place for its whole length; the scrubber shows them over any frame.
struct RedactEditorView: View {
    /// Larger than the other editors' previews, so Vision can read small text.
    private static let previewEdge = 2048
    /// Pointer travel, as a share of the picture, that makes a drag rather than a click.
    private static let smallestDrag = 0.005
    /// A box needs some width and height, or it would hide nothing.
    private static let smallestSide = 0.004
    private static let renderDebounce: Duration = .milliseconds(30)

    /// What the preview shows: these boxes over this picture.
    private struct RenderKey: Equatable {
        let regions: [RedactionRegion]
        let picture: ObjectIdentifier?
    }

    let url: URL
    let isVideo: Bool
    let onSave: (ToolOptions) -> Void
    let onCancel: () -> Void

    @StateObject private var video: VideoFrameModel
    @State private var photo: CGImage?
    @State private var photoError: String?
    @State private var rendered: CGImage?
    @State private var regions: [RedactionRegion] = []
    @State private var draft: RedactionRegion?
    @State private var style = RedactionStyle.solid
    @State private var searching = false
    @State private var note: String?

    init(url: URL, isVideo: Bool, onSave: @escaping (ToolOptions) -> Void, onCancel: @escaping () -> Void) {
        self.url = url
        self.isVideo = isVideo
        self.onSave = onSave
        self.onCancel = onCancel
        _video = StateObject(wrappedValue: VideoFrameModel(url: url, maximumEdge: Self.previewEdge))
    }

    private var original: CGImage? { isVideo ? video.frame : photo }
    private var loadError: String? { isVideo ? video.loadError : photoError }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            canvas
            if isVideo {
                VideoScrubberBar(model: video)
            }
            // Saving mid-search would leave out whatever the search is about to find.
            EditorFooter(canSave: original != nil && !regions.isEmpty && !searching, onCancel: onCancel,
                         onSave: { onSave(isVideo ? .videoRedactions(regions) : .redactions(regions)) }) {
                HStack(spacing: 8) {
                    Button("Undo") { change(Array(regions.dropLast())) }
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(regions.isEmpty)
                    Button("Clear") { change([]) }
                        .disabled(regions.isEmpty)
                    Text(footnote).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .task {
            if isVideo {
                await video.load()
            } else {
                await loadPhoto()
            }
        }
        // Blurs are slow at full preview size, so committed boxes render off
        // the main thread; a box being dragged shows as an outline until then.
        .task(id: RenderKey(regions: regions, picture: original.map(ObjectIdentifier.init))) {
            try? await Task.sleep(for: Self.renderDebounce)
            guard !Task.isCancelled else { return }
            await render()
        }
        // One style for every box, so the saved copy looks consistent.
        .onChange(of: style) { newStyle in
            regions = regions.map { RedactionRegion(id: $0.id, rect: $0.rect, style: newStyle) }
        }
        .onDisappear { video.stop() }
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
                .help(isVideo ? "Box the faces in the frame shown" : "Box every face in the photo")
            if !isVideo {
                Button { find(.text) } label: { Label("Find Text", systemImage: "text.viewfinder") }
                    .disabled(original == nil || searching)
            }
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

    /// The reminder that video boxes don't follow anything, plus the latest
    /// search result and any boxes drawn solid because they overlap too deeply.
    private var footnote: String {
        var parts = note.map { [$0] } ?? []
        if isVideo {
            parts.append("Boxes stay in place for the whole video")
            if let size = video.info?.rotatedSize {
                let solid = VideoRedaction.solidFallbackCount(regions, width: size.width, height: size.height)
                if solid > 0 { parts.append("\(solid) deeply overlapping \(solid == 1 ? "box is" : "boxes are") drawn solid") }
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Editing

    private func dragged(from start: NormalizedPoint, to current: NormalizedPoint) {
        let rect = AnnotationGeometry.rect(from: start, to: current)
        // A drag along an edge has no height (or width) and would hide nothing.
        guard rect.width >= Self.smallestSide, rect.height >= Self.smallestSide else {
            draft = nil
            return
        }
        draft = RedactionRegion(id: draft?.id ?? UUID(), rect: rect, style: style)
    }

    /// A drag adds its box; a click on a box removes that box.
    private func dragEnded(from start: NormalizedPoint, to end: NormalizedPoint) {
        let moved = hypot(end.x - start.x, end.y - start.y) >= Self.smallestDrag
        if let draft {
            change(regions + [draft])
        } else if !moved, let hit = regions.last(where: { contains($0.rect, end) }) {
            change(regions.filter { $0.id != hit.id })
        }
        draft = nil
    }

    /// A change by hand also clears the last search's note, which no longer describes the boxes.
    private func change(_ newRegions: [RedactionRegion]) {
        regions = newRegions
        note = nil
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
        // Nothing to hide: show the picture as it is.
        guard !regions.isEmpty else {
            rendered = nil
            return
        }
        let regions = regions
        let result: Result<CGImage, ConversionError>
        if isVideo {
            result = await renderedVideoFrame(regions)
        } else {
            result = await Task.detached(priority: .userInitiated) {
                Result { () throws(ConversionError) in try PhotoRendering.redacted(original, regions) }
            }.value
        }
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let image): rendered = image
        case .failure(let error):
            // Never leave an older, less-redacted preview on screen.
            rendered = nil
            note = error.localizedDescription
        }
    }

    /// The frame shown, redacted by ffmpeg with the very filter the saved
    /// copy uses, so the preview matches it. Runs in this task, so a newer
    /// edit or frame cancels it and stops ffmpeg.
    private func renderedVideoFrame(_ regions: [RedactionRegion]) async -> Result<CGImage, ConversionError> {
        guard let size = video.info?.rotatedSize else { return .failure(.unreadableInput(url.lastPathComponent)) }
        let filter = VideoRedaction.filter(regions, width: size.width, height: size.height)
        do {
            return .success(try await MediaPreview.displayFrame(of: url, at: video.time, filter: filter,
                                                                maximumEdge: Self.previewEdge))
        } catch {
            return .failure(error)
        }
    }

    private func loadPhoto() async {
        switch await PreviewImage.loadInBackground(url, maximumEdge: Self.previewEdge) {
        case .success(let loaded): photo = loaded.image
        case .failure(let error): photoError = error.localizedDescription
        }
    }
}
