import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Add a Background: put the photo on a padded canvas with rounded corners,
/// a shadow, and a colour, gradient or blurred copy of itself behind it.
struct BackgroundEditorView: View {
    private static let previewEdge = 1400
    private static let renderDebounce: Duration = .milliseconds(30)
    private static let controlsWidth: CGFloat = 250

    private enum FillKind: String, CaseIterable {
        case gradient
        case color
        case blurredPhoto

        var title: String {
            switch self {
            case .gradient: "Gradient"
            case .color: "Colour"
            case .blurredPhoto: "Blurred Photo"
            }
        }
    }

    let url: URL
    let onSave: (ToolOptions) -> Void
    let onCancel: () -> Void

    @State private var original: CGImage?
    /// The photo's real size, to check the framed copy isn't too large to save.
    @State private var pixelSize: (width: Int, height: Int)?
    @State private var rendered: CGImage?
    @State private var loadError: String?
    @State private var aspect = BackgroundRecipe.standard.aspect
    @State private var padding = BackgroundRecipe.standard.padding
    @State private var cornerRadius = BackgroundRecipe.standard.cornerRadius
    @State private var shadow = BackgroundRecipe.standard.shadow
    @State private var fillKind = FillKind.gradient
    @State private var firstColor = Self.standardColors.first
    @State private var secondColor = Self.standardColors.second
    @State private var angle = Self.standardAngle

    private static var standardColors: (first: CGColor, second: CGColor) {
        guard case .gradient(let first, let second, _) = BackgroundRecipe.standard.fill else {
            return (RGBA.white.cgColor, RGBA.white.cgColor)
        }
        return (first.cgColor, second.cgColor)
    }

    private static var standardAngle: Double {
        guard case .gradient(_, _, let angle) = BackgroundRecipe.standard.fill else { return 0 }
        return angle
    }

    private var recipe: BackgroundRecipe {
        let fill: BackgroundFill = switch fillKind {
        case .gradient: .gradient(RGBA(firstColor), RGBA(secondColor), angleDegrees: angle)
        case .color: .color(RGBA(firstColor))
        case .blurredPhoto: .blurredPhoto
        }
        return BackgroundRecipe(aspect: aspect, padding: padding, cornerRadius: cornerRadius, shadow: shadow, fill: fill)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                preview
                controls.frame(width: Self.controlsWidth)
            }
            EditorFooter(canSave: original != nil && fitsInMemory, onCancel: onCancel, onSave: { onSave(.background(recipe)) }) {
                if !fitsInMemory {
                    Text("Too large to save: use less padding or a different shape")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .task { await load() }
        .task(id: recipe) {
            try? await Task.sleep(for: Self.renderDebounce)
            guard !Task.isCancelled else { return }
            await render()
        }
    }

    @ViewBuilder private var preview: some View {
        if let image = rendered ?? original {
            PhotoCanvas(image: image)
        } else if let loadError {
            ContentUnavailableNote(text: loadError)
        } else {
            ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Fill", selection: $fillKind) {
                    ForEach(FillKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                switch fillKind {
                case .gradient:
                    ColorPicker("From", selection: $firstColor, supportsOpacity: false)
                    ColorPicker("To", selection: $secondColor, supportsOpacity: false)
                    AdjustmentSlider(title: "Angle", value: $angle, range: 0...360)
                case .color:
                    ColorPicker("Colour", selection: $firstColor, supportsOpacity: false)
                case .blurredPhoto:
                    EmptyView()
                }
                Divider()
                Picker("Shape", selection: $aspect) {
                    ForEach(AspectRatio.allCases.filter { $0 != .original }, id: \.self) {
                        Text($0 == .free ? "Fit Photo" : $0.title).tag($0)
                    }
                }
                AdjustmentSlider(title: "Padding", value: $padding, range: BackgroundRecipe.paddingRange)
                AdjustmentSlider(title: "Corners", value: $cornerRadius, range: BackgroundRecipe.cornerRange)
                AdjustmentSlider(title: "Shadow", value: $shadow, range: 0...1)
            }
            .padding(.trailing, 8)
        }
    }

    private var fitsInMemory: Bool {
        guard let pixelSize else { return true }
        let layout = recipe.layout(imageWidth: pixelSize.width, imageHeight: pixelSize.height)
        return layout.canvasWidth * layout.canvasHeight <= PhotoRendering.maximumPixels
    }

    private func load() async {
        switch await PreviewImage.loadInBackground(url, maximumEdge: Self.previewEdge) {
        case .success(let loaded):
            original = loaded.image
            pixelSize = loaded.size
            await render()
        case .failure(let error):
            loadError = error.localizedDescription
        }
    }

    private func render() async {
        guard let original else { return }
        let recipe = recipe
        let image = await Task.detached(priority: .userInitiated) {
            try? PhotoRendering.framed(original, recipe)
        }.value
        guard !Task.isCancelled else { return }
        rendered = image
    }
}
