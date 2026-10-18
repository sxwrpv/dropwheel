import AppKit
import DropwheelCore
import os

/// Watches for file drags anywhere on screen and reports wheel events.
///
/// A global mouse-down monitor starts a short polling loop. It samples the
/// mouse button, the modifier keys and the system drag pasteboard, and stops
/// when the button is released. None of these reads need Accessibility or
/// Input Monitoring permission.
@MainActor
final class DragMonitor {
    private static let pollInterval: TimeInterval = 1.0 / 60.0

    var onEvent: ((DragSessionEvent) -> Void)?

    private var tracker: DragSessionTracker
    private var mouseMonitor: Any?
    private var pollTimer: Timer?
    private let dragPasteboard = NSPasteboard(name: .drag)
    private let logger = Logger(subsystem: "dev.dropwheel", category: "DragMonitor")
    /// Pasteboard type lookups cross processes, so the answer is cached until
    /// the pasteboard's change count moves.
    private var cachedChangeCount: Int?
    private var cachedHasFiles = false

    init(bindings: KeyBindings) {
        tracker = DragSessionTracker(bindings: bindings)
    }

    func start() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginPolling() }
        }
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        stopPolling()
    }

    private func beginPolling() {
        guard pollTimer == nil else { return }
        tick()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common keeps the timer firing while menus or drags run their own loops.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func tick() {
        let sample = currentSample()
        let wasTracking = tracker.isTrackingFileDrag
        let events = tracker.observe(sample)
        if tracker.isTrackingFileDrag != wasTracking {
            logger.debug("File drag \(self.tracker.isTrackingFileDrag ? "started" : "ended", privacy: .public)")
        }
        for event in events {
            logger.debug("Wheel event: \(String(describing: event), privacy: .public)")
            onEvent?(event)
        }
        if !sample.isMouseDown { stopPolling() }
    }

    private func currentSample() -> InputSample {
        let isMouseDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let changeCount = dragPasteboard.changeCount
        if changeCount != cachedChangeCount {
            cachedChangeCount = changeCount
            cachedHasFiles = dragPasteboard.types?.contains(.fileURL) ?? false
        }
        return InputSample(
            isMouseDown: isMouseDown,
            dragChangeCount: changeCount,
            dragHasFiles: cachedHasFiles,
            modifiers: Self.modifiers(from: flags)
        )
    }

    private static func modifiers(from flags: CGEventFlags) -> Set<ModifierKey> {
        let mapping: [(CGEventFlags, ModifierKey)] = [
            (.maskShift, .shift),
            (.maskControl, .control),
            (.maskAlternate, .option),
            (.maskCommand, .command),
        ]
        return Set(mapping.filter { flags.contains($0.0) }.map(\.1))
    }
}
