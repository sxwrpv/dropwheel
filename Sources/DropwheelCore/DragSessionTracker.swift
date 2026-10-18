/// One snapshot of global input state, sampled while the mouse is down.
public struct InputSample: Equatable, Sendable {
    public let isMouseDown: Bool
    /// `changeCount` of the system drag pasteboard. It changes when a new drag starts.
    public let dragChangeCount: Int
    /// Whether the drag pasteboard currently offers file URLs.
    public let dragHasFiles: Bool
    public let modifiers: Set<ModifierKey>

    public init(isMouseDown: Bool, dragChangeCount: Int, dragHasFiles: Bool, modifiers: Set<ModifierKey>) {
        self.isMouseDown = isMouseDown
        self.dragChangeCount = dragChangeCount
        self.dragHasFiles = dragHasFiles
        self.modifiers = modifiers
    }
}

public enum DragSessionEvent: Equatable, Sendable {
    /// Show this wheel, or switch the visible wheel to it.
    case showWheel(WheelKind)
    /// The drag finished. Hide any wheel.
    case dragEnded
}

/// Turns a stream of input samples into wheel events.
///
/// A wheel opens only when a modifier is pressed *after* a file drag has
/// started, so holding Shift before dragging does nothing. Pressing a
/// different bound key switches wheels. The wheel stays up until the mouse
/// is released.
public struct DragSessionTracker: Sendable {
    private enum Phase: Equatable, Sendable {
        case idle
        case mouseDown(baselineChangeCount: Int)
        case fileDrag(visibleWheel: WheelKind?)
    }

    private var phase: Phase = .idle
    private var previousModifiers: Set<ModifierKey> = []
    public var bindings: KeyBindings

    public init(bindings: KeyBindings = .standard) {
        self.bindings = bindings
    }

    public var isTrackingFileDrag: Bool {
        if case .fileDrag = phase { return true }
        return false
    }

    public mutating func observe(_ sample: InputSample) -> [DragSessionEvent] {
        let pressedNow = sample.modifiers.subtracting(previousModifiers)
        previousModifiers = sample.modifiers

        guard sample.isMouseDown else {
            let wasDragging = isTrackingFileDrag
            phase = .idle
            return wasDragging ? [.dragEnded] : []
        }

        switch phase {
        case .idle:
            phase = .mouseDown(baselineChangeCount: sample.dragChangeCount)
            return []

        case .mouseDown(let baseline):
            guard sample.dragChangeCount != baseline, sample.dragHasFiles else { return [] }
            phase = .fileDrag(visibleWheel: nil)
            return wheelEvents(pressed: pressedNow, visible: nil)

        case .fileDrag(let visible):
            return wheelEvents(pressed: pressedNow, visible: visible)
        }
    }

    private mutating func wheelEvents(pressed: Set<ModifierKey>, visible: WheelKind?) -> [DragSessionEvent] {
        // If two bound keys go down in the same tick, use a fixed order so
        // the result does not depend on Set iteration order.
        let requested = ModifierKey.allCases
            .filter(pressed.contains)
            .compactMap(bindings.wheel(for:))
            .first
        guard let requested, requested != visible else { return [] }
        phase = .fileDrag(visibleWheel: requested)
        return [.showWheel(requested)]
    }
}
