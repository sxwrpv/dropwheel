import AVFoundation
import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Trim for audio and video: drag the handles on the waveform, type exact
/// timecodes, or step a frame at a time. Video shows the frame at the
/// handle being moved.
struct TrimEditorView: View {
    enum Handle { case start, end }

    private static let waveformBuckets = 240
    private static let shortestRange = TrimRange.minimumLength
    private static let defaultFramesPerSecond = 30.0
    /// Rates outside this range are misreported (browser WebM can claim 1000 fps).
    private static let plausibleFrameRates = 1.0...240.0
    /// Wait this long after the last move before fetching a preview frame.
    private static let previewDebounce: Duration = .milliseconds(80)

    /// Identifies the preview wanted: the exact millisecond of the active
    /// handle, once the file's details are known.
    private struct PreviewRequest: Hashable {
        let millisecond: Int
        let ready: Bool
    }

    let url: URL
    let isVideo: Bool
    let onSave: (ToolOptions) -> Void
    let onCancel: () -> Void

    @State private var info: MediaInfo?
    @State private var peaks: [Float] = []
    @State private var frame: CGImage?
    @State private var loadError: String?
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var startText = ""
    @State private var endText = ""
    @State private var active = Handle.start
    @State private var canPlay = false
    @State private var player: AVPlayer?
    @State private var boundaryObserver: Any?

    private var duration: Double { info?.durationSeconds ?? 0 }
    private var frameStep: Double {
        let rate = info?.framesPerSecond ?? Self.defaultFramesPerSecond
        return 1 / (Self.plausibleFrameRates.contains(rate) ? rate : Self.defaultFramesPerSecond)
    }

    private var previewRequest: PreviewRequest {
        PreviewRequest(millisecond: Int(((active == .start ? start : end) * 1000).rounded()), ready: info != nil)
    }

    var body: some View {
        VStack(spacing: 12) {
            if isVideo { framePreview }
            if let loadError {
                ContentUnavailableNote(text: loadError)
            } else if info == nil {
                ProgressView("Reading \(url.lastPathComponent)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WaveformRange(peaks: peaks, start: $start, end: $end, duration: duration,
                              shortestRange: Self.shortestRange, active: $active)
                    .frame(height: isVideo ? 70 : 140)
                timeControls
            }
            EditorFooter(canSave: canSave, onCancel: cancel, onSave: save) {
                HStack(spacing: 10) {
                    Button(action: playSelection) { Label("Play", systemImage: "play.fill") }
                        .disabled(!canPlay)
                        .help(canPlay ? "Play the part you keep" : "This format can’t be played here")
                    if !isVideo {
                        Button("Trim Silence") { finish(with: .trimSilence) }
                            .help("Remove only the silence at the start and end")
                    }
                    Text("Keeps \(Timecode.string(from: end - start))")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .task { await load() }
        .task(id: previewRequest) {
            // A new move cancels this task during the pause, so fast drags fetch only the last frame.
            try? await Task.sleep(for: Self.previewDebounce)
            guard !Task.isCancelled else { return }
            await refreshFrame()
        }
        .onChange(of: start) { startText = Timecode.string(from: $0) }
        .onChange(of: end) { endText = Timecode.string(from: $0) }
        .onDisappear { stopPlayback() }
    }

    @ViewBuilder private var framePreview: some View {
        if let frame {
            Image(decorative: frame, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Rectangle().fill(Color.black.opacity(0.85)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var timeControls: some View {
        HStack {
            timeField("Start", text: $startText, handle: .start)
            Spacer()
            timeField("End", text: $endText, handle: .end)
        }
    }

    private func timeField(_ title: String, text: Binding<String>, handle: Handle) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Button { step(handle, by: -frameStep) } label: { Image(systemName: "chevron.left") }
                .help("Back one frame")
            TextField(title, text: text)
                .frame(width: 96)
                .monospacedDigit()
                .onSubmit { commit(text.wrappedValue, to: handle) }
            Button { step(handle, by: frameStep) } label: { Image(systemName: "chevron.right") }
                .help("Forward one frame")
        }
    }

    private var range: TrimRange { TrimRange(start: start, end: end) }

    private var canSave: Bool {
        info != nil && range.isValid(durationSeconds: duration) && !range.coversWhole(durationSeconds: duration)
    }

    // MARK: Editing

    private func step(_ handle: Handle, by amount: Double) {
        active = handle
        move(handle, to: (handle == .start ? start : end) + amount)
    }

    private func commit(_ text: String, to handle: Handle) {
        guard let seconds = Timecode.seconds(from: text) else {
            startText = Timecode.string(from: start)
            endText = Timecode.string(from: end)
            return
        }
        active = handle
        move(handle, to: seconds)
    }

    private func move(_ handle: Handle, to seconds: Double) {
        switch handle {
        case .start: start = min(max(seconds, 0), end - Self.shortestRange)
        case .end: end = max(min(seconds, duration), start + Self.shortestRange)
        }
        // A typed value clamped back to the current one wouldn't trigger
        // onChange, so the fields are rewritten every time.
        startText = Timecode.string(from: start)
        endText = Timecode.string(from: end)
    }

    private func save() { finish(with: .trim(range)) }

    private func cancel() {
        stopPlayback()
        onCancel()
    }

    private func finish(with options: ToolOptions) {
        stopPlayback()
        onSave(options)
    }

    // MARK: Loading and playback

    private func load() async {
        do {
            let loaded = try await MediaPreview.info(of: url)
            info = loaded
            end = loaded.durationSeconds ?? 0
            startText = Timecode.string(from: 0)
            endText = Timecode.string(from: end)
            if loaded.hasAudio {
                peaks = (try? await MediaPreview.waveform(of: url, buckets: Self.waveformBuckets)) ?? []
            }
            canPlay = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func refreshFrame() async {
        guard isVideo, info != nil else { return }
        let time = active == .start ? start : max(end - frameStep, 0)
        if let image = try? await MediaPreview.frame(of: url, at: time) {
            frame = image
        }
    }

    private func playSelection() {
        stopPlayback()
        let player = AVPlayer(url: url)
        let endTime = CMTime(seconds: end, preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: endTime)], queue: .main) { [weak player] in
            player?.pause()
        }
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        self.player = player
    }

    private func stopPlayback() {
        if let boundaryObserver { player?.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        player?.pause()
        player = nil
    }
}

/// The waveform with the kept part highlighted. Dragging moves whichever
/// handle is nearer to where the drag began.
private struct WaveformRange: View {
    private static let handleWidth: CGFloat = 4

    let peaks: [Float]
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let shortestRange: Double
    @Binding var active: TrimEditorView.Handle

    @State private var dragging: TrimEditorView.Handle?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = position(of: start, width: width)
            let endX = position(of: end, width: width)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                Canvas { context, size in
                    guard !peaks.isEmpty else { return }
                    let barWidth = size.width / CGFloat(peaks.count)
                    for (index, peak) in peaks.enumerated() {
                        let height = max(1, CGFloat(peak) * size.height)
                        let bar = CGRect(x: CGFloat(index) * barWidth, y: (size.height - height) / 2,
                                         width: max(barWidth - 1, 1), height: height)
                        context.fill(Path(bar), with: .color(.accentColor.opacity(0.8)))
                    }
                }
                Rectangle().fill(Color.black.opacity(0.4)).frame(width: max(startX, 0))
                Rectangle().fill(Color.black.opacity(0.4)).frame(width: max(width - endX, 0)).offset(x: endX)
                handle(at: startX, isActive: active == .start)
                handle(at: endX, isActive: active == .end)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let handle = dragging ?? nearerHandle(to: value.startLocation.x, startX: startX, endX: endX)
                        dragging = handle
                        active = handle
                        let time = self.time(at: value.location.x, width: width)
                        switch handle {
                        case .start: start = min(max(time, 0), end - shortestRange)
                        case .end: end = max(min(time, duration), start + shortestRange)
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
    }

    private func handle(at x: CGFloat, isActive: Bool) -> some View {
        Rectangle()
            .fill(isActive ? Color.accentColor : Color.white)
            .frame(width: Self.handleWidth)
            .offset(x: x - Self.handleWidth / 2)
            .allowsHitTesting(false)
    }

    private func nearerHandle(to x: CGFloat, startX: CGFloat, endX: CGFloat) -> TrimEditorView.Handle {
        abs(x - startX) <= abs(x - endX) ? .start : .end
    }

    private func position(of time: Double, width: CGFloat) -> CGFloat {
        duration > 0 ? CGFloat(time / duration) * width : 0
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        width > 0 ? Double(min(max(x, 0), width) / width) * duration : 0
    }
}
