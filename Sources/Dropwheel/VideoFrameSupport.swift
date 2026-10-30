import DropwheelCore
import DropwheelEngines
import SwiftUI

/// The video's details and the frame at the chosen time, for editors that
/// show one frame at a time. Fast scrubbing fetches only the last frame asked for.
@MainActor
final class VideoFrameModel: ObservableObject {
    private static let fetchDebounce: Duration = .milliseconds(80)
    private static let defaultFramesPerSecond = 30.0
    /// Rates outside this range are misreported (browser WebM can claim 1000 fps).
    private static let plausibleFrameRates = 1.0...240.0

    let url: URL
    /// Frames are shown no larger than this, so 4K and 8K video stays light.
    let maximumEdge: Int
    @Published private(set) var info: MediaInfo?
    /// The frame at `time` as it plays (square pixels), at most `maximumEdge`.
    @Published private(set) var frame: CGImage?
    @Published private(set) var loadError: String?
    /// Set when the frame at `time` couldn't be read; `frame` is then older.
    @Published private(set) var frameError: String?
    @Published var time = 0.0 {
        didSet { fetchFrame() }
    }

    private var fetch: Task<Void, Never>?

    init(url: URL, maximumEdge: Int) {
        self.url = url
        self.maximumEdge = maximumEdge
    }

    /// Zero when the file doesn't record its length (live recordings often
    /// don't); the first frame can still be shown.
    var duration: Double { info?.durationSeconds ?? 0 }
    var hasDuration: Bool { duration > 0 }

    var frameStep: Double {
        let rate = info?.framesPerSecond ?? Self.defaultFramesPerSecond
        return 1 / (Self.plausibleFrameRates.contains(rate) ? rate : Self.defaultFramesPerSecond)
    }

    func load() async {
        do {
            let loaded = try await MediaPreview.info(of: url)
            guard loaded.hasVideo else { throw ConversionError.unreadableInput(url.lastPathComponent) }
            info = loaded
            fetchFrame()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func step(frames: Int) {
        time = FrameStepping.time(after: time, frames: frames, frameStep: frameStep, duration: duration)
    }

    func stop() {
        fetch?.cancel()
    }

    private func fetchFrame() {
        guard info != nil else { return }
        fetch?.cancel()
        let url = url
        let seconds = time
        let edge = maximumEdge
        fetch = Task { [weak self] in
            try? await Task.sleep(for: Self.fetchDebounce)
            guard !Task.isCancelled else { return }
            do {
                let image = try await MediaPreview.displayFrame(of: url, at: seconds, maximumEdge: edge)
                guard !Task.isCancelled else { return }
                self?.frame = image
                self?.frameError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.frameError = error.localizedDescription
            }
        }
    }
}

/// A slider across the whole video, with frame steps and the current time.
struct VideoScrubberBar: View {
    @ObservedObject var model: VideoFrameModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.step(frames: -1) } label: { Image(systemName: "chevron.left") }
                .help("Back one frame")
            Slider(value: $model.time, in: 0...max(model.duration, 0.001))
            Button { model.step(frames: 1) } label: { Image(systemName: "chevron.right") }
                .help("Forward one frame")
            Text(Timecode.string(from: model.time))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .disabled(!model.hasDuration)
    }
}
