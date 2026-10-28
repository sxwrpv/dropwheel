import Foundation

/// A colour with components from 0 to 1.
public struct RGBA: Equatable, Sendable {
    public static let white = RGBA(red: 1, green: 1, blue: 1)
    public static let black = RGBA(red: 0, green: 0, blue: 0)
    public static let red = RGBA(red: 0.92, green: 0.2, blue: 0.2)

    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

// MARK: Edit Photo

/// Light, colour and detail adjustments. Zero everywhere changes nothing.
public struct PhotoAdjustments: Equatable, Sendable {
    public static let neutral = PhotoAdjustments()
    public static let exposureRange = -2.0...2.0
    public static let signedRange = -1.0...1.0
    public static let amountRange = 0.0...1.0
    /// Highlights can only be recovered; Exposure brightens.
    public static let highlightsRange = -1.0...0.0

    /// Stops of light.
    public var exposure = 0.0
    public var contrast = 0.0
    public var saturation = 0.0
    /// Negative is cooler, positive warmer.
    public var warmth = 0.0
    /// From -1 to 0: negative recovers bright areas.
    public var highlights = 0.0
    /// Positive lifts dark areas.
    public var shadows = 0.0
    public var sharpness = 0.0
    public var noiseReduction = 0.0
    public var vignette = 0.0
    public var grain = 0.0

    public init() {}

    public var isNeutral: Bool { clamped() == .neutral }

    /// Every value inside its range; NaN becomes neutral.
    public func clamped() -> PhotoAdjustments {
        func fit(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            value.isNaN ? 0 : min(max(value, range.lowerBound), range.upperBound)
        }
        var result = PhotoAdjustments()
        result.exposure = fit(exposure, Self.exposureRange)
        result.contrast = fit(contrast, Self.signedRange)
        result.saturation = fit(saturation, Self.signedRange)
        result.warmth = fit(warmth, Self.signedRange)
        result.highlights = fit(highlights, Self.highlightsRange)
        result.shadows = fit(shadows, Self.signedRange)
        result.sharpness = fit(sharpness, Self.amountRange)
        result.noiseReduction = fit(noiseReduction, Self.amountRange)
        result.vignette = fit(vignette, Self.amountRange)
        result.grain = fit(grain, Self.amountRange)
        return result
    }
}

// MARK: Add a Background

public enum BackgroundFill: Equatable, Sendable {
    case color(RGBA)
    case gradient(RGBA, RGBA, angleDegrees: Double)
    /// The photo itself, scaled to fill the canvas and blurred.
    case blurredPhoto
}

/// Where the photo sits on the new canvas, in pixels (origin top left).
public struct BackgroundLayout: Equatable, Sendable {
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let imageRect: PixelRect
}

/// A photo placed on a new canvas: padding around it, an optional canvas
/// shape, rounded corners, a shadow, and what fills the space.
public struct BackgroundRecipe: Equatable, Sendable {
    public static let paddingRange = 0.0...0.5
    public static let cornerRange = 0.0...0.5

    public var aspect: AspectRatio
    /// Space around the photo, as a share of its long edge.
    public var padding: Double
    /// Corner rounding, as a share of the photo's short edge.
    public var cornerRadius: Double
    /// Shadow strength from 0 to 1.
    public var shadow: Double
    public var fill: BackgroundFill

    public init(aspect: AspectRatio, padding: Double, cornerRadius: Double, shadow: Double, fill: BackgroundFill) {
        self.aspect = aspect
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.fill = fill
    }

    public static let standard = BackgroundRecipe(
        aspect: .free, padding: 0.08, cornerRadius: 0.03, shadow: 0.4,
        fill: .gradient(RGBA(red: 0.36, green: 0.4, blue: 0.95), RGBA(red: 0.75, green: 0.35, blue: 0.85), angleDegrees: 45)
    )

    /// The canvas grows to fit the padding, then (for a chosen shape) grows
    /// further in one direction; the photo is never cropped and stays centred.
    public func layout(imageWidth: Int, imageHeight: Int) -> BackgroundLayout {
        let pad = Int((Self.fit(padding, Self.paddingRange) * Double(max(imageWidth, imageHeight))).rounded())
        var width = imageWidth + 2 * pad
        var height = imageHeight + 2 * pad
        if let wanted = aspect.ratio, width > 0, height > 0 {
            if Double(width) / Double(height) < wanted {
                width = Int((Double(height) * wanted).rounded())
            } else {
                height = Int((Double(width) / wanted).rounded())
            }
        }
        let rect = PixelRect(x: (width - imageWidth) / 2, y: (height - imageHeight) / 2, width: imageWidth, height: imageHeight)
        return BackgroundLayout(canvasWidth: width, canvasHeight: height, imageRect: rect)
    }

    public func cornerRadiusPixels(imageWidth: Int, imageHeight: Int) -> Int {
        Int((Self.fit(cornerRadius, Self.cornerRange) * Double(min(imageWidth, imageHeight))).rounded())
    }

    public var shadowStrength: Double { Self.fit(shadow, 0...1) }

    private static func fit(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isNaN ? 0 : min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: Annotate

/// A point as a share of the picture's width and height, origin top left.
public struct NormalizedPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum AnnotationShape: Equatable, Sendable {
    case arrow(from: NormalizedPoint, to: NormalizedPoint)
    case rectangle(from: NormalizedPoint, to: NormalizedPoint)
    case ellipse(from: NormalizedPoint, to: NormalizedPoint)
    /// A translucent marker over an area.
    case highlight(from: NormalizedPoint, to: NormalizedPoint)
    case text(at: NormalizedPoint, String)
    /// A filled circle with a number, for step-by-step callouts.
    case callout(at: NormalizedPoint, number: Int)
    case freehand([NormalizedPoint])
}

public struct Annotation: Equatable, Sendable, Identifiable {
    public static let defaultLineWidth = 0.006

    public let id: UUID
    public let shape: AnnotationShape
    public let color: RGBA
    /// Line width as a share of the picture's short edge.
    public let lineWidth: Double

    public init(id: UUID = UUID(), shape: AnnotationShape, color: RGBA, lineWidth: Double = Annotation.defaultLineWidth) {
        self.id = id
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
    }
}

public enum AnnotationGeometry {
    /// Barbs sit this far either side of the shaft (30°).
    static let barbSpread = Double.pi / 6

    /// The rectangle between two corners, whichever way the drag went.
    public static func rect(from a: NormalizedPoint, to b: NormalizedPoint) -> CropRecipe {
        CropRecipe(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The two ends of an arrowhead's barbs, behind the tip on either side of the shaft.
    public static func arrowheadBarbs(
        from start: (x: Double, y: Double), to tip: (x: Double, y: Double), length: Double
    ) -> (left: (x: Double, y: Double), right: (x: Double, y: Double)) {
        let angle = atan2(tip.y - start.y, tip.x - start.x)
        let left = (x: tip.x - length * cos(angle - barbSpread), y: tip.y - length * sin(angle - barbSpread))
        let right = (x: tip.x - length * cos(angle + barbSpread), y: tip.y - length * sin(angle + barbSpread))
        return (left, right)
    }
}

// MARK: Redact

public enum RedactionStyle: String, CaseIterable, Sendable {
    case solid
    case blur
    case pixelate

    public var title: String { rawValue.capitalized }
}

/// An area to hide, as a share of the picture (origin top left).
public struct RedactionRegion: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let rect: CropRecipe
    public let style: RedactionStyle

    public init(id: UUID = UUID(), rect: CropRecipe, style: RedactionStyle = .solid) {
        self.id = id
        self.rect = rect
        self.style = style
    }

    /// Vision reports boxes with the origin at the bottom left; the editor
    /// uses the top left. `margin` grows the box on every side so the edges
    /// of a face or word aren't left showing.
    public static func fromVision(
        x: Double, y: Double, width: Double, height: Double, margin: Double, style: RedactionStyle = .solid
    ) -> RedactionRegion {
        let left = max(x - margin, 0)
        let top = max(1 - y - height - margin, 0)
        let right = min(x + width + margin, 1)
        let bottom = min(1 - y + margin, 1)
        return RedactionRegion(rect: CropRecipe(x: left, y: top, width: right - left, height: bottom - top), style: style)
    }
}
