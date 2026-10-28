import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Edit Photo: light, colour and detail sliders with a live preview.
struct PhotoAdjustEditorView: View {
    /// Live previews render at this size, so sliders stay smooth.
    private static let previewEdge = 1400
    private static let renderDebounce: Duration = .milliseconds(30)
    private static let controlsWidth: CGFloat = 250

    let url: URL
    let onSave: (ToolOptions) -> Void
    let onCancel: () -> Void

    @State private var original: CGImage?
    @State private var rendered: CGImage?
    @State private var loadError: String?
    @State private var adjustments = PhotoAdjustments.neutral
    @State private var showOriginal = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                preview
                controls.frame(width: Self.controlsWidth)
            }
            EditorFooter(canSave: original != nil && !adjustments.isNeutral, onCancel: onCancel,
                         onSave: { onSave(.photoEdit(adjustments.clamped())) }) {
                Toggle("Show Original", isOn: $showOriginal)
                    .help("Compare with the photo before your changes")
            }
        }
        .padding(16)
        .task { await load() }
        .task(id: adjustments) {
            try? await Task.sleep(for: Self.renderDebounce)
            guard !Task.isCancelled else { return }
            await render()
        }
    }

    @ViewBuilder private var preview: some View {
        if let original {
            PhotoCanvas(image: showOriginal ? original : rendered ?? original)
        } else if let loadError {
            ContentUnavailableNote(text: loadError)
        } else {
            ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Light") {
                    AdjustmentSlider(title: "Exposure", value: $adjustments.exposure, range: PhotoAdjustments.exposureRange)
                    AdjustmentSlider(title: "Contrast", value: $adjustments.contrast, range: PhotoAdjustments.signedRange)
                    AdjustmentSlider(title: "Highlights", value: $adjustments.highlights, range: PhotoAdjustments.highlightsRange)
                    AdjustmentSlider(title: "Shadows", value: $adjustments.shadows, range: PhotoAdjustments.signedRange)
                }
                section("Colour") {
                    AdjustmentSlider(title: "Saturation", value: $adjustments.saturation, range: PhotoAdjustments.signedRange)
                    AdjustmentSlider(title: "Warmth", value: $adjustments.warmth, range: PhotoAdjustments.signedRange)
                }
                section("Detail") {
                    AdjustmentSlider(title: "Sharpness", value: $adjustments.sharpness, range: PhotoAdjustments.amountRange)
                    AdjustmentSlider(title: "Noise Reduction", value: $adjustments.noiseReduction, range: PhotoAdjustments.amountRange)
                    AdjustmentSlider(title: "Vignette", value: $adjustments.vignette, range: PhotoAdjustments.amountRange)
                    AdjustmentSlider(title: "Grain", value: $adjustments.grain, range: PhotoAdjustments.amountRange)
                }
                Button("Reset All") { adjustments = .neutral }
                    .disabled(adjustments.isNeutral)
            }
            .padding(.trailing, 8)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func load() async {
        switch await PreviewImage.loadInBackground(url, maximumEdge: Self.previewEdge) {
        case .success(let loaded): original = loaded.image
        case .failure(let error): loadError = error.localizedDescription
        }
    }

    /// Renders off the main thread; a newer slider move cancels this one's result.
    private func render() async {
        guard let original else { return }
        let values = adjustments
        let image = await Task.detached(priority: .userInitiated) {
            try? PhotoRendering.adjusted(original, values)
        }.value
        guard !Task.isCancelled else { return }
        rendered = image
    }
}
