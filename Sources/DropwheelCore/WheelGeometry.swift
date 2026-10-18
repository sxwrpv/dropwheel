import Foundation

public enum WheelHit: Equatable, Sendable {
    case hub
    case slice(Int)
    case outside
}

/// Layout of a ring of equal slices around a central hub.
///
/// Angles are measured clockwise from 12 o'clock, in radians. Slice 0 is
/// centred at the top. Points use AppKit orientation: relative to the wheel
/// centre, with y pointing up.
public struct WheelGeometry: Equatable, Sendable {
    public let sliceCount: Int
    public let hubRadius: Double
    public let outerRadius: Double

    /// Smallest ring width kept when the radii given are out of order.
    private static let minimumRingWidth = 1.0

    public init(sliceCount: Int, hubRadius: Double, outerRadius: Double) {
        let hub = max(hubRadius, 0)
        self.sliceCount = max(sliceCount, 0)
        self.hubRadius = hub
        self.outerRadius = max(outerRadius, hub + Self.minimumRingWidth)
    }

    public var sliceAngle: Double {
        sliceCount > 0 ? 2 * .pi / Double(sliceCount) : 0
    }

    public func hitTest(dx: Double, dy: Double) -> WheelHit {
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance.isFinite else { return .outside }
        if distance <= hubRadius { return .hub }
        if distance > outerRadius || sliceCount == 0 { return .outside }

        // atan2(dx, dy) is the clockwise angle from +y. Shift by half a
        // slice so slice 0 spans the top instead of starting there.
        let clockwise = Self.normalized(atan2(dx, dy) + sliceAngle / 2)
        let index = Int(clockwise / sliceAngle) % sliceCount
        return .slice(index)
    }

    /// Clockwise angle from 12 o'clock to the middle of slice `index`.
    public func centerAngle(of index: Int) -> Double {
        Double(index) * sliceAngle
    }

    /// Start and end of slice `index` in AppKit degrees (counter-clockwise
    /// from 3 o'clock), as `NSBezierPath.appendArc` expects. The arc runs
    /// clockwise from `start` to `end`.
    public func appKitArcDegrees(of index: Int) -> (start: Double, end: Double) {
        let half = sliceAngle / 2
        let startClockwise = centerAngle(of: index) - half
        let endClockwise = centerAngle(of: index) + half
        return (Self.appKitDegrees(fromClockwise: startClockwise),
                Self.appKitDegrees(fromClockwise: endClockwise))
    }

    /// Point at `radius` along the middle of slice `index`, relative to the centre.
    public func labelOffset(of index: Int, radius: Double) -> (dx: Double, dy: Double) {
        let angle = centerAngle(of: index)
        return (sin(angle) * radius, cos(angle) * radius)
    }

    private static func normalized(_ radians: Double) -> Double {
        let full = 2 * Double.pi
        let remainder = radians.truncatingRemainder(dividingBy: full)
        return remainder < 0 ? remainder + full : remainder
    }

    private static func appKitDegrees(fromClockwise radians: Double) -> Double {
        90 - radians * 180 / .pi
    }
}
