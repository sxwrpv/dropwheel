import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Bleep Audio: mark the parts to cover on a zoomable waveform, compare the
/// original with the bleeped version, and save a copy.
struct BleepEditorView: View {
    private static let bucketsPerSecond = 200
    private static let maximumBuckets = 400_000
    /// The closest zoom shows this many seconds.
    private static let shortestWindow = 2.0
    private static let newMarkLength = 1.0
    /// The timeline is measured at a lower sample rate than the file's own,
    /// so a mark this close to its end counts as reaching the end.
    private static let endTolerance = 0.002
    /// Wide enough for Pause, so the controls beside it don't shift.
    private static let playButtonWidth: CGFloat = 64

    let url: URL
    let onSave: (ToolOptions) -> Void
    let onCancel: () -> Void

    @StateObject private var playback: BleepPlayback
    @State private var timeline: AudioTimeline?
    @State private var loadError: String?
    @State private var marks: [BleepMark] = []
    @State private var selection: UUID?
    /// While a mark is being dragged the view stays put, or the times under
    /// the pointer would change and carry the mark with them.
    @State private var isDragging = false
    @State private var window = WaveformWindow(start: 0, length: 1)
    /// 0 shows the whole recording, 1 the closest view.
    @State private var zoom = 0.0
    @State private var sound = BleepSound.tone
    @State private var version = BleepPlayback.Version.bleeped
    @State private var startText = ""
    @State private var endText = ""
    @FocusState private var focusedEdge: BleepEdge?

    init(url: URL, onSave: @escaping (ToolOptions) -> Void, onCancel: @escaping () -> Void) {
        self.url = url
        self.onSave = onSave
        self.onCancel = onCancel
        _playback = StateObject(wrappedValue: BleepPlayback(url: url))
    }

    private var selectedMark: BleepMark? { marks.first { $0.id == selection } }

    private var recipe: BleepRecipe { recipe(for: marks) }

    /// A mark reaching the end of the timeline runs past it, so it also
    /// covers the file's very last samples.
    private func recipe(for marks: [BleepMark]) -> BleepRecipe {
        let duration = timeline?.seconds ?? 0
        let ranges = marks.map { mark in
            TrimRange(start: mark.start, end: mark.end >= duration - Self.endTolerance ? duration + 1 : mark.end)
        }
        return BleepRecipe(ranges: ranges, sound: sound)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let timeline {
                BleepWaveform(timeline: timeline, window: window, marks: $marks, selection: $selection, isDragging: $isDragging,
                              clock: playback.clock, onPress: commitFields) {
                    playback.seek(to: $0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                WaveformOverview(timeline: timeline, marks: marks, window: $window)
                    .frame(height: 36)
                markControls
                playbackControls
            } else if let loadError {
                ContentUnavailableNote(text: loadError)
            } else {
                ProgressView("Reading \(url.lastPathComponent)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The time fields take Return to finish typing.
            EditorFooter(canSave: !marks.isEmpty, savesOnReturn: false, onCancel: onCancel, onSave: save) {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .task { await load() }
        .onChange(of: zoom) { applyZoom($0) }
        .onChange(of: selectedMark) { syncFields(with: $0) }
        .onChange(of: focusedEdge) { _ in commitFields() }
        .onChange(of: recipe) { playback.recipeChanged(to: $0) }
        .onChange(of: version) { newVersion in
            if playback.isPlaying || playback.isPreparing { playback.play(newVersion, recipe: recipe) }
        }
        .onReceive(playback.clock.$time) { follow($0) }
        .onDisappear { playback.stop() }
    }

    private var markControls: some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $zoom, in: 0...1) { Text("Zoom") }
                .labelsHidden()
                .frame(width: 130)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Button(action: addMark) { Label("Add Bleep", systemImage: "plus") }
                .help("Mark a part starting at the playhead")
            Spacer()
            if selectedMark != nil {
                timeField("Start", text: $startText, edge: .start)
                timeField("End", text: $endText, edge: .end)
                Button("Remove", action: removeSelection)
            }
        }
    }

    private func timeField(_ title: String, text: Binding<String>, edge: BleepEdge) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            TextField(title, text: text)
                .labelsHidden()
                .monospacedDigit()
                .frame(width: 84)
                .focused($focusedEdge, equals: edge)
                .onSubmit(commitFields)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            Button(action: togglePlayback) {
                Label(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: Self.playButtonWidth)
            }
            .keyboardShortcut(.space, modifiers: [])
            Picker("Listen to", selection: $version) {
                ForEach(BleepPlayback.Version.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            if playback.isPreparing { ProgressView().controlSize(.small) }
            PlayheadTime(clock: playback.clock)
            Spacer()
            Picker("Cover with", selection: $sound) {
                ForEach(BleepSound.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(width: 180)
        }
    }

    private var summary: String {
        if let errorText = playback.errorText { return errorText }
        let count = BleepPlans.merged(recipe.ranges).count
        return count == 0 ? "" : "\(count) \(count == 1 ? "part" : "parts") marked · tags and chapters are left out of the copy"
    }

    // MARK: Editing

    private func addMark() {
        commitFields()
        guard let timeline else { return }
        let start = min(playback.clock.time, max(timeline.seconds - Self.newMarkLength, 0))
        let mark = BleepMark(id: UUID(), start: start, end: min(start + Self.newMarkLength, timeline.seconds))
        marks = marks + [mark]
        selection = mark.id
    }

    private func removeSelection() {
        marks = marks.filter { $0.id != selection }
        selection = nil
    }

    /// The marks with whatever is typed in the time fields applied to the
    /// selected mark. Text that isn't a time, or hasn't changed, leaves it alone.
    private var marksWithFields: [BleepMark] {
        guard let mark = selectedMark, let timeline else { return marks }
        func typed(_ text: String, instead current: Double) -> Double {
            guard text != Timecode.string(from: current) else { return current }
            return Timecode.seconds(from: text.replacingOccurrences(of: ",", with: ".")) ?? current
        }
        let updated = mark.with(start: typed(startText, instead: mark.start), end: typed(endText, instead: mark.end),
                                duration: timeline.seconds)
        return marks.map { $0.id == updated.id ? updated : $0 }
    }

    /// Takes in what is typed. Typing the time a mark already has wouldn't
    /// trigger onChange, so the fields are rewritten every time.
    private func commitFields() {
        let committed = marksWithFields
        marks = committed
        syncFields(with: committed.first { $0.id == selection })
    }

    /// Times still being typed count, so the copy matches what the fields show.
    private func save() {
        onSave(.bleep(recipe(for: marksWithFields)))
    }

    private func syncFields(with mark: BleepMark?) {
        startText = mark.map { Timecode.string(from: $0.start) } ?? ""
        endText = mark.map { Timecode.string(from: $0.end) } ?? ""
    }

    private func applyZoom(_ zoom: Double) {
        guard let timeline else { return }
        let length = WaveformWindow.length(zoom: zoom, duration: timeline.seconds, closest: Self.shortestWindow)
        let playhead = playback.clock.time
        let inView = playhead >= window.start && playhead <= window.end
        let centre = inView ? playhead : window.start + window.length / 2
        window = .around(centre, length: length, duration: timeline.seconds)
    }

    /// While playing, the view moves on when the playhead leaves it.
    private func follow(_ time: Double) {
        guard playback.isPlaying, !isDragging, let timeline, time < window.start || time > window.end else { return }
        window = .around(time + window.length * 0.4, length: window.length, duration: timeline.seconds)
    }

    private func togglePlayback() {
        if playback.isPlaying || playback.isPreparing {
            playback.pause()
        } else {
            commitFields()
            playback.play(version, recipe: recipe(for: marksWithFields))
        }
    }

    private func load() async {
        do {
            let loaded = try await MediaPreview.timeline(of: url, bucketsPerSecond: Self.bucketsPerSecond,
                                                         maximumBuckets: Self.maximumBuckets)
            timeline = loaded
            window = WaveformWindow(start: 0, length: loaded.seconds)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// The current time. It watches the clock itself, so nothing else redraws
/// as the time changes.
private struct PlayheadTime: View {
    @ObservedObject var clock: PlayheadClock

    var body: some View {
        Text(Timecode.string(from: clock.time))
            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
    }
}
