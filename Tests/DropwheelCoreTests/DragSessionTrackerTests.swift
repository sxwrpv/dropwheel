import Testing
@testable import DropwheelCore

@Suite("DragSessionTracker")
struct DragSessionTrackerTests {
    private func sample(
        down: Bool = true,
        count: Int = 1,
        files: Bool = true,
        _ modifiers: Set<ModifierKey> = []
    ) -> InputSample {
        InputSample(isMouseDown: down, dragChangeCount: count, dragHasFiles: files, modifiers: modifiers)
    }

    @Test("Tapping Shift during a file drag opens the conversions wheel")
    func shiftOpensConversions() {
        var tracker = DragSessionTracker()
        #expect(tracker.observe(sample(count: 1)) == [])
        #expect(tracker.observe(sample(count: 2)) == [])
        #expect(tracker.observe(sample(count: 2, [.shift])) == [.showWheel(.conversions)])
    }

    @Test("A modifier held before the drag started does not open a wheel")
    func heldModifierIsIgnored() {
        var tracker = DragSessionTracker()
        _ = tracker.observe(sample(count: 1, [.shift]))
        #expect(tracker.observe(sample(count: 2, [.shift])) == [])
        #expect(tracker.observe(sample(count: 2, [.shift])) == [])
    }

    @Test("Releasing and re-tapping a held modifier opens the wheel")
    func retapAfterHold() {
        var tracker = DragSessionTracker()
        _ = tracker.observe(sample(count: 1, [.shift]))
        _ = tracker.observe(sample(count: 2, [.shift]))
        _ = tracker.observe(sample(count: 2))
        #expect(tracker.observe(sample(count: 2, [.shift])) == [.showWheel(.conversions)])
    }

    @Test("A drag without files is ignored")
    func nonFileDragIgnored() {
        var tracker = DragSessionTracker()
        _ = tracker.observe(sample(count: 1, files: false))
        _ = tracker.observe(sample(count: 2, files: false))
        #expect(tracker.observe(sample(count: 2, files: false, [.shift])) == [])
        #expect(!tracker.isTrackingFileDrag)
    }

    @Test("A plain click with no drag never opens a wheel")
    func clickWithoutDrag() {
        var tracker = DragSessionTracker()
        _ = tracker.observe(sample(count: 5))
        #expect(tracker.observe(sample(count: 5, [.shift])) == [])
        #expect(tracker.observe(sample(down: false, count: 5)) == [])
    }

    @Test("Another bound key switches wheels; the same key again does nothing")
    func switchingWheels() {
        var tracker = DragSessionTracker()
        _ = tracker.observe(sample(count: 1))
        _ = tracker.observe(sample(count: 2))
        #expect(tracker.observe(sample(count: 2, [.shift])) == [.showWheel(.conversions)])
        #expect(tracker.observe(sample(count: 2, [.shift, .command])) == [.showWheel(.tools)])
        #expect(tracker.observe(sample(count: 2)) == [])
        #expect(tracker.observe(sample(count: 2, [.command])) == [])
        #expect(tracker.observe(sample(count: 2, [.command, .control])) == [.showWheel(.actions)])
    }

    @Test("An unbound modifier does nothing")
    func unboundModifier() {
        var tracker = DragSessionTracker()
        _ = tracker.observe(sample(count: 1))
        _ = tracker.observe(sample(count: 2))
        #expect(tracker.observe(sample(count: 2, [.option])) == [])
    }

    @Test("Releasing the mouse ends the drag")
    func mouseUpEndsDrag() {
        var tracker = DragSessionTracker()
        _ = tracker.observe(sample(count: 1))
        _ = tracker.observe(sample(count: 2))
        #expect(tracker.observe(sample(down: false, count: 2)) == [.dragEnded])
        #expect(!tracker.isTrackingFileDrag)
    }

    @Test("Custom bindings are honoured")
    func customBindings() {
        var tracker = DragSessionTracker(bindings: KeyBindings(conversions: .option, tools: .command, actions: .control))
        _ = tracker.observe(sample(count: 1))
        _ = tracker.observe(sample(count: 2))
        #expect(tracker.observe(sample(count: 2, [.shift])) == [])
        #expect(tracker.observe(sample(count: 2, [.shift, .option])) == [.showWheel(.conversions)])
    }
}
