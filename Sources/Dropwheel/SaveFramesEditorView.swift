import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Save Frames: the frame shown as a picture, or one frame every few
/// seconds into a folder.
struct SaveFramesEditorView: View {
    private static let previewEdge = 1600

    private enum Mode: String, CaseIterable {
        case current
        case every

        var title: String { self == .current ? "This Frame" : "Every…" }
    }

    let url: URL
    let onSave: (ToolOptions) -> Void
    let onCancel: () -> Void

    @StateObject private var video: VideoFrameModel
    @State private var mode = Mode.current
    @State private var intervalText = "1"
    @State private var format = FrameImageFormat.png

    init(url: URL, onSave: @escaping (ToolOptions) -> Void, onCancel: @escaping () -> Void) {
        self.url = url
        self.onSave = onSave
        self.onCancel = onCancel
        _video = StateObject(wrappedValue: VideoFrameModel(url: url, maximumEdge: Self.previewEdge))
    }

    private var export: FrameExport? {
        switch mode {
        case .current: FrameExport(plan: .single(seconds: video.time), format: format)
        case .every: Double(intervalText.replacingOccurrences(of: ",", with: ".")).map {
            FrameExport(plan: .every(seconds: $0), format: format)
        }
        }
    }

    /// "This Frame" also needs the frame shown to have loaded, or the copy
    /// could differ from what is on screen.
    private var canSave: Bool {
        guard video.info != nil, video.hasDuration, export?.isValid(durationSeconds: video.duration) == true else { return false }
        return mode == .every || video.frameError == nil
    }

    var body: some View {
        VStack(spacing: 12) {
            preview
            VideoScrubberBar(model: video)
            controls
            // The interval field takes Return to finish typing.
            EditorFooter(canSave: canSave, savesOnReturn: false, onCancel: onCancel,
                         onSave: { export.map { onSave(.frames($0)) } }) {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .task { await video.load() }
        .onDisappear { video.stop() }
    }

    @ViewBuilder private var preview: some View {
        if let frame = video.frame {
            PhotoCanvas(image: frame)
        } else if let loadError = video.loadError {
            ContentUnavailableNote(text: loadError)
        } else {
            ProgressView("Reading \(url.lastPathComponent)…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Save", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            if mode == .every {
                TextField("Seconds", text: $intervalText).frame(width: 60)
                Text("seconds").foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Format", selection: $format) {
                ForEach(FrameImageFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(width: 160)
        }
    }

    private var summary: String {
        guard video.info != nil else { return "" }
        guard video.hasDuration else { return "This video doesn’t record its length, so frames can’t be picked from it" }
        if mode == .current, let frameError = video.frameError { return frameError }
        guard let export else { return "Type the interval in seconds" }
        switch export.plan {
        case .single(let seconds):
            return "Saves the frame at \(Timecode.string(from: seconds))"
        case .every:
            // Only an estimate: the last interval may or may not hold a frame.
            let count = export.frameCount(durationSeconds: video.duration)
            return export.isValid(durationSeconds: video.duration)
                ? "Saves about \(count) frames into a folder"
                : "Choose an interval that gives 2 to \(FrameExport.maximumFrames) frames"
        }
    }
}
