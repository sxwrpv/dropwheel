import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Collage: the selected photos in a grid. Drag names in the list to
/// change their order; the preview uses the same layout as the saved copy.
struct CollageEditorView: View {
    private static let thumbnailEdge = 800
    private static let previewLongEdge = 1200
    private static let renderDebounce: Duration = .milliseconds(30)
    private static let maximumColumns = 6
    private static let controlsWidth: CGFloat = 250

    /// What the preview shows: this layout of these photos in this order.
    private struct RenderKey: Equatable {
        let recipe: CollageRecipe
        let order: [Int]
        let loaded: Int
    }

    let urls: [URL]
    let onSave: (ToolOptions, [URL]) -> Void
    let onCancel: () -> Void

    /// Positions in `urls`, so the same file picked twice still counts twice.
    @State private var order: [Int]
    /// One per entry in `urls`, in the same order.
    @State private var thumbnails: [CGImage] = []
    @State private var loadError: String?
    @State private var rendered: CGImage?
    /// Zero means automatic.
    @State private var columns = 0
    @State private var aspect = CollageRecipe.standard.aspect
    @State private var spacing = CollageRecipe.standard.spacing
    @State private var cornerRadius = CollageRecipe.standard.cornerRadius
    @State private var background = CollageRecipe.standard.background.cgColor
    @State private var longEdge = CollageRecipe.standard.longEdge

    init(urls: [URL], onSave: @escaping (ToolOptions, [URL]) -> Void, onCancel: @escaping () -> Void) {
        self.urls = urls
        self.onSave = onSave
        self.onCancel = onCancel
        _order = State(initialValue: Array(urls.indices))
    }

    private var recipe: CollageRecipe {
        CollageRecipe(columns: columns == 0 ? nil : columns, aspect: aspect, longEdge: longEdge, spacing: spacing,
                      cornerRadius: cornerRadius, background: RGBA(background))
    }

    private var isLoaded: Bool { thumbnails.count == urls.count }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                preview
                controls.frame(width: Self.controlsWidth)
            }
            EditorFooter(canSave: isLoaded, onCancel: onCancel, onSave: { onSave(.collage(recipe), order.map { urls[$0] }) }) {
                let layout = recipe.layout(count: urls.count)
                Text("\(layout.canvasWidth) × \(layout.canvasHeight) px")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .task { await load() }
        .task(id: RenderKey(recipe: recipe, order: order, loaded: thumbnails.count)) {
            try? await Task.sleep(for: Self.renderDebounce)
            guard !Task.isCancelled else { return }
            await render()
        }
    }

    @ViewBuilder private var preview: some View {
        if let rendered {
            PhotoCanvas(image: rendered)
        } else if let loadError {
            ContentUnavailableNote(text: loadError)
        } else {
            ProgressView("Loading \(urls.count) photos…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Order").font(.headline)
            List {
                ForEach(order, id: \.self) { index in
                    Text(urls[index].lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
                .onMove { offsets, destination in
                    var reordered = order
                    reordered.move(fromOffsets: offsets, toOffset: destination)
                    order = reordered
                }
            }
            .frame(minHeight: 120, maxHeight: 180)
            Picker("Columns", selection: $columns) {
                Text("Automatic").tag(0)
                ForEach(1...min(Self.maximumColumns, urls.count), id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Shape", selection: $aspect) {
                ForEach(AspectRatio.allCases.filter { $0 != .original }, id: \.self) {
                    Text($0 == .free ? "Fit Grid" : $0.title).tag($0)
                }
            }
            Picker("Size", selection: $longEdge) {
                ForEach(CollageRecipe.longEdgeChoices, id: \.self) { Text("\($0) px").tag($0) }
            }
            AdjustmentSlider(title: "Spacing", value: $spacing, range: CollageRecipe.spacingRange)
            AdjustmentSlider(title: "Corners", value: $cornerRadius, range: CollageRecipe.cornerRange)
            ColorPicker("Background", selection: $background, supportsOpacity: false)
        }
    }

    private func load() async {
        var loaded: [CGImage] = []
        for url in urls {
            switch await PreviewImage.loadInBackground(url, maximumEdge: Self.thumbnailEdge) {
            case .success(let preview): loaded.append(preview.image)
            case .failure(let error):
                loadError = error.localizedDescription
                return
            }
        }
        thumbnails = loaded
    }

    /// The same recipe at a smaller size: spacing and corners are shares,
    /// so the layout matches the saved copy.
    private func render() async {
        guard isLoaded else { return }
        let images = order.map { thumbnails[$0] }
        var small = recipe
        small.longEdge = Self.previewLongEdge
        let result = await Task.detached(priority: .userInitiated) {
            Result { () throws(ConversionError) in try PhotoRendering.collage(images, recipe: small) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let image): rendered = image
        case .failure(let error): loadError = error.localizedDescription
        }
    }
}
