import DropwheelCore
import DropwheelEngines
import SwiftUI

/// The recording's peaks in a stretch of time, one bar per point. Equatable
/// so that it redraws only when the stretch changes, not as marks move.
private struct PeaksCanvas: View, Equatable {
    let peaks: [Float]
    let duration: Double
    let window: WaveformWindow

    nonisolated static func == (first: PeaksCanvas, second: PeaksCanvas) -> Bool {
        first.window == second.window && first.duration == second.duration && first.peaks.count == second.peaks.count
    }

    var body: some View {
        Canvas { context, size in
            let columns = Int(size.width)
            guard columns > 0, !peaks.isEmpty, duration > 0 else { return }
            let bucketsPerSecond = Double(peaks.count) / duration
            let secondsPerColumn = window.length / Double(columns)
            var bars = Path()
            for column in 0..<columns {
                let time = window.start + Double(column) * secondsPerColumn
                let first = min(Int(time * bucketsPerSecond), peaks.count - 1)
                let last = min(max(Int((time + secondsPerColumn) * bucketsPerSecond), first + 1), peaks.count)
                let peak = peaks[first..<last].max() ?? 0
                let height = max(1, CGFloat(peak) * size.height)
                bars.addRect(CGRect(x: CGFloat(column), y: (size.height - height) / 2, width: 1, height: height))
            }
            context.fill(bars, with: .color(.accentColor.opacity(0.8)))
        }
    }
}

/// The line showing where playback is. It watches the clock itself, so
/// nothing else redraws as the time changes.
private struct PlayheadLine: View {
    private static let width: CGFloat = 1.5

    @ObservedObject var clock: PlayheadClock
    let window: WaveformWindow

    var body: some View {
        GeometryReader { geometry in
            if clock.time >= window.start, clock.time <= window.end {
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: Self.width)
                    .offset(x: CGFloat((clock.time - window.start) / window.length) * geometry.size.width - Self.width / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The waveform of the stretch in view. Drag across it to mark a part, drag
/// a mark to move it or its edges to fine-tune it, and click to move the playhead.
struct BleepWaveform: View {
    /// How close to a mark's edge a press takes hold of the edge.
    private static let edgeReach: CGFloat = 6
    /// How far the pointer moves before a press counts as a drag.
    private static let dragThreshold: CGFloat = 3
    private static let markColor = Color.orange

    let timeline: AudioTimeline
    let window: WaveformWindow
    @Binding var marks: [BleepMark]
    @Binding var selection: UUID?
    @Binding var isDragging: Bool
    let clock: PlayheadClock
    /// Called before a press does anything, so what is being typed counts first.
    let onPress: () -> Void
    let onSeek: (Double) -> Void

    @State private var drag: BleepDrag?
    /// Whether the pointer has moved far enough for this press to count as a drag.
    @State private var hasMoved = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                PeaksCanvas(peaks: timeline.peaks, duration: timeline.seconds, window: window).equatable()
                marksCanvas
                PlayheadLine(clock: clock, window: window)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragChanged($0, width: width) }
                    .onEnded { _ in dragEnded() }
            )
        }
    }

    private var marksCanvas: some View {
        Canvas { context, size in
            for mark in marks where mark.end > window.start && mark.start < window.end {
                let left = CGFloat((mark.start - window.start) / window.length) * size.width
                let right = CGFloat((mark.end - window.start) / window.length) * size.width
                let area = CGRect(x: left, y: 0, width: right - left, height: size.height)
                context.fill(Path(area), with: .color(Self.markColor.opacity(mark.id == selection ? 0.5 : 0.3)))
                for edge in [left, right] {
                    context.fill(Path(CGRect(x: edge - 1, y: 0, width: 2, height: size.height)), with: .color(Self.markColor))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        width > 0 ? window.start + Double(min(max(x, 0), width) / width) * window.length : window.start
    }

    private func dragChanged(_ value: DragGesture.Value, width: CGFloat) {
        if drag == nil {
            onPress()
            isDragging = true
            let started = BleepDrag.starting(at: time(at: value.startLocation.x, width: width), marks: marks, selection: selection,
                                             edgeReach: Double(Self.edgeReach / max(width, 1)) * window.length)
            drag = started
            switch started {
            case .resizing(let mark, _, _), .moving(let mark, _): selection = mark.id
            case .pressing, .drawing: break
            }
        }
        // Nothing changes until the pointer really moves, so a click never disturbs a mark.
        hasMoved = hasMoved || abs(value.translation.width) >= Self.dragThreshold
        guard hasMoved, var current = drag else { return }
        if case .pressing(let start) = current {
            let id = UUID()
            current = .drawing(id: id, from: start)
            drag = current
            selection = id
        }
        marks = current.applied(to: marks, at: time(at: value.location.x, width: width), duration: timeline.seconds)
    }

    private func dragEnded() {
        defer {
            drag = nil
            hasMoved = false
            isDragging = false
        }
        guard let drag else { return }
        if case .pressing(let time) = drag {
            selection = nil
            onSeek(time)
            return
        }
        let kept = drag.finished(with: marks)
        if kept != marks {
            marks = kept
            selection = nil
        }
    }
}

/// The whole recording, with the stretch in view outlined. Click or drag to
/// move around it.
struct WaveformOverview: View {
    let timeline: AudioTimeline
    let marks: [BleepMark]
    @Binding var window: WaveformWindow

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06))
                PeaksCanvas(peaks: timeline.peaks, duration: timeline.seconds,
                            window: WaveformWindow(start: 0, length: timeline.seconds)).equatable()
                overlay
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let share = width > 0 ? Double(value.location.x / width) : 0
                    window = .around(share * timeline.seconds, length: window.length, duration: timeline.seconds)
                }
            )
        }
    }

    private var overlay: some View {
        Canvas { context, size in
            let duration = timeline.seconds
            guard duration > 0 else { return }
            for mark in marks {
                let left = CGFloat(mark.start / duration) * size.width
                let right = CGFloat(mark.end / duration) * size.width
                context.fill(Path(CGRect(x: left, y: 0, width: max(right - left, 1), height: size.height)), with: .color(.orange))
            }
            let view = CGRect(x: CGFloat(window.start / duration) * size.width, y: 0,
                              width: CGFloat(window.length / duration) * size.width, height: size.height)
            context.stroke(Path(view.insetBy(dx: 0.75, dy: 0.75)), with: .color(.primary.opacity(0.7)), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}
