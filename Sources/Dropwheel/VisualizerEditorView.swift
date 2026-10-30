import AppKit
import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Audio Visualizer: turn a recording into a video with an animated
/// waveform or a still picture. The preview is drawn by the same filter
/// as the saved video.
struct VisualizerEditorView: View {
    private static let previewDebounce: Duration = .milliseconds(120)
    private static let controlsWidth: CGFloat = 250
    private static let timelineBucketsPerSecond = 20
    private static let timelineMaximumBuckets = 20_000

    /// What the preview shows: this look, at this moment, once the file is read.
    private struct PreviewKey: Equatable {
        let recipe: VisualizerRecipe
        let seconds: Double
        let isReady: Bool
    }

    let url: URL
    let onSave: (ToolOptions) -> Void
    let onCancel: () -> Void

    @State private var content = VisualizerRecipe.standard.content
    @State private var shape = VisualizerRecipe.standard.shape
    @State private var waveColor = VisualizerRecipe.standard.waveColor.cgColor
    @State private var background = VisualizerRecipe.standard.background.cgColor
    @State private var picture: URL?
    @State private var duration: Double?
    @State private var isReady = false
    @State private var seconds = 0.0
    @State private var preview: CGImage?
    @State private var problem: String?

    private var recipe: VisualizerRecipe {
        VisualizerRecipe(content: content, shape: shape, waveColor: RGBA(waveColor), background: RGBA(background), picture: picture)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                previewArea
                controls.frame(width: Self.controlsWidth)
            }
            EditorFooter(canSave: isReady && recipe.isComplete && problem == nil, onCancel: onCancel,
                         onSave: { onSave(.visualizer(recipe)) }) {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .task { await load() }
        .task(id: PreviewKey(recipe: recipe, seconds: seconds, isReady: isReady)) {
            try? await Task.sleep(for: Self.previewDebounce)
            guard !Task.isCancelled, isReady else { return }
            await render()
        }
    }

    @ViewBuilder private var previewArea: some View {
        if let preview {
            PhotoCanvas(image: preview)
        } else if let problem {
            ContentUnavailableNote(text: problem)
        } else {
            ProgressView("Reading \(url.lastPathComponent)…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Show", selection: $content) {
                ForEach(VisualizerContent.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Shape", selection: $shape) {
                ForEach(VisualizerShape.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if content == .waveform {
                ColorPicker("Waveform", selection: $waveColor, supportsOpacity: false)
            }
            ColorPicker("Background", selection: $background, supportsOpacity: false)
            Divider()
            pictureControls
            if content == .waveform, let duration {
                Divider()
                AdjustmentSlider(title: "Preview at", value: $seconds, range: 0...duration)
            }
            Spacer()
        }
    }

    private var pictureControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Choose Picture…", action: choosePicture)
                if picture != nil {
                    Button("Remove") { picture = nil }
                }
            }
            if let picture {
                Text(picture.lastPathComponent)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var summary: String {
        if let problem { return problem }
        if !recipe.isComplete { return "Choose a picture to show" }
        return "\(shape.width) × \(shape.height) MP4"
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        // After a drop Finder is often frontmost; the panel must stay visible regardless.
        panel.hidesOnDeactivate = false
        if panel.runModal() == .OK {
            picture = panel.url
        }
    }

    /// Reads the sound itself, for its real length and to start the preview
    /// at the loudest moment: a pause between words would look like nothing.
    private func load() async {
        do {
            let timeline = try await MediaPreview.timeline(of: url, bucketsPerSecond: Self.timelineBucketsPerSecond,
                                                           maximumBuckets: Self.timelineMaximumBuckets)
            let loudest = timeline.peaks.indices.max { timeline.peaks[$0] < timeline.peaks[$1] } ?? 0
            duration = timeline.seconds
            seconds = Double(loudest) / Double(timeline.peaks.count) * timeline.seconds
            isReady = true
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Runs in the preview task, so a newer change cancels it and stops ffmpeg.
    private func render() async {
        do {
            let frame = try await MediaPreview.visualizerFrame(of: url, recipe: recipe, at: seconds)
            guard !Task.isCancelled else { return }
            preview = frame
            problem = nil
        } catch {
            guard !Task.isCancelled else { return }
            problem = error.localizedDescription
        }
    }
}
