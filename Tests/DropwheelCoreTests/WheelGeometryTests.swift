import Testing
@testable import DropwheelCore

@Suite("WheelGeometry")
struct WheelGeometryTests {
    private let six = WheelGeometry(sliceCount: 6, hubRadius: 40, outerRadius: 120)

    @Test("Points inside the hub hit the hub")
    func hub() {
        #expect(six.hitTest(dx: 0, dy: 0) == .hub)
        #expect(six.hitTest(dx: 30, dy: -20) == .hub)
    }

    @Test("Points beyond the outer radius miss")
    func outside() {
        #expect(six.hitTest(dx: 0, dy: 121) == .outside)
        #expect(six.hitTest(dx: -100, dy: -100) == .outside)
    }

    @Test("Slices run clockwise from the top",
          arguments: [
              (0.0, 80.0, 0),    // 12 o'clock
              (69.3, 40.0, 1),   // 2 o'clock
              (69.3, -40.0, 2),  // 4 o'clock
              (0.0, -80.0, 3),   // 6 o'clock
              (-69.3, -40.0, 4), // 8 o'clock
              (-69.3, 40.0, 5),  // 10 o'clock
          ])
    func clockwiseOrder(dx: Double, dy: Double, expected: Int) {
        #expect(six.hitTest(dx: dx, dy: dy) == .slice(expected))
    }

    @Test("Slice 0 straddles 12 o'clock")
    func sliceZeroStraddlesTop() {
        #expect(six.hitTest(dx: -10, dy: 80) == .slice(0))
        #expect(six.hitTest(dx: 10, dy: 80) == .slice(0))
    }

    @Test("An empty wheel only has a hub")
    func emptyWheel() {
        let empty = WheelGeometry(sliceCount: 0, hubRadius: 40, outerRadius: 120)
        #expect(empty.hitTest(dx: 0, dy: 80) == .outside)
        #expect(empty.hitTest(dx: 0, dy: 10) == .hub)
    }

    @Test("Non-finite points miss instead of crashing")
    func nonFinite() {
        #expect(six.hitTest(dx: .nan, dy: 10) == .outside)
        #expect(six.hitTest(dx: .infinity, dy: 0) == .outside)
    }

    @Test("Invalid radii are clamped instead of crashing")
    func clampedRadii() {
        let odd = WheelGeometry(sliceCount: 4, hubRadius: 50, outerRadius: 20)
        #expect(odd.outerRadius > odd.hubRadius)
    }

    @Test("AppKit arc for slice 0 is centred on 90 degrees")
    func appKitArc() {
        let arc = six.appKitArcDegrees(of: 0)
        #expect(abs(arc.start - 120) < 0.0001)
        #expect(abs(arc.end - 60) < 0.0001)
    }

    @Test("Label offset for slice 0 points straight up")
    func labelOffset() {
        let offset = six.labelOffset(of: 0, radius: 80)
        #expect(abs(offset.dx) < 0.0001)
        #expect(abs(offset.dy - 80) < 0.0001)
    }
}
