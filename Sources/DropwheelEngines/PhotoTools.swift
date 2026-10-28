import CoreGraphics
import CoreImage
import CoreText
import DropwheelCore
import Foundation
import ImageIO
import Vision

/// The picture-in, picture-out work behind Edit Photo, Add a Background,
/// Annotate and Redact. The editors call these on their previews, so what
/// they show is what gets saved.
public enum PhotoRendering {
    /// 100 megapixels: an RGBA bitmap this size already needs 400 MB.
    public static let maximumPixels = 100_000_000

    /// Shared: Core Image contexts are thread-safe.
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: Edit Photo

    /// White balance the warmth slider swings around, in kelvin.
    private static let neutralTemperature = 6500.0
    private static let warmthSwing = 3000.0

    public static func adjusted(_ image: CGImage, _ adjustments: PhotoAdjustments) throws(ConversionError) -> CGImage {
        let values = adjustments.clamped()
        guard !values.isNeutral else { return image }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let shortEdge = Double(min(image.width, image.height))
        var result = CIImage(cgImage: image)

        if values.exposure != 0 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: values.exposure])
        }
        if values.warmth != 0 {
            // A higher source white point than the target turns the picture warmer.
            let source = CIVector(x: neutralTemperature + values.warmth * warmthSwing, y: 0)
            result = result.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": source, "inputTargetNeutral": CIVector(x: neutralTemperature, y: 0),
            ])
        }
        if values.highlights != 0 || values.shadows != 0 {
            result = result.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + values.highlights, "inputShadowAmount": values.shadows,
            ])
        }
        if values.contrast != 0 || values.saturation != 0 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + values.contrast * 0.5, kCIInputSaturationKey: 1 + values.saturation,
            ])
        }
        if values.noiseReduction > 0 {
            result = result.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": values.noiseReduction * 0.1, "inputSharpness": 0.4,
            ])
        }
        if values.sharpness > 0 {
            // The radius follows the picture's size, so the preview sharpens like the saved copy.
            result = result.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: values.sharpness * 2, kCIInputRadiusKey: max(shortEdge * 0.0015, 0.5),
            ])
        }
        if values.vignette > 0 {
            result = result.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: hypot(extent.width, extent.height) * 0.45,
                kCIInputIntensityKey: values.vignette,
            ])
        }
        if values.grain > 0 {
            result = grained(result, amount: values.grain, grainSize: max(shortEdge / 1000, 1))
        }
        return try render(result.cropped(to: extent), like: image)
    }

    /// Opaque grey noise around mid-grey, soft-lit over the picture: soft
    /// light leaves mid-grey unchanged, so brightness holds on average.
    private static func grained(_ image: CIImage, amount: Double, grainSize: Double) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let strength = amount * 0.6
        let channel = CIVector(x: strength, y: 0, z: 0, w: 0)
        let offset = 0.5 - strength / 2
        // The generator's alpha is random too; colour filters divide by it,
        // which would skew the noise bright, so alpha is made opaque first.
        let mono = noise
            .transformed(by: CGAffineTransform(scaleX: grainSize, y: grainSize))
            .settingAlphaOne(in: image.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": channel, "inputGVector": channel, "inputBVector": channel,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: offset, y: offset, z: offset, w: 1),
            ])
            .cropped(to: image.extent)
        // Core Image works in linear light, where soft light would brighten
        // on average; blending on the sRGB tone curve keeps it balanced.
        let perceptual = image.applyingFilter("CILinearToSRGBToneCurve")
        return mono.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: perceptual])
            .applyingFilter("CISRGBToneCurveToLinear")
    }

    // MARK: Add a Background

    public static func framed(_ image: CGImage, _ recipe: BackgroundRecipe) throws(ConversionError) -> CGImage {
        let layout = recipe.layout(imageWidth: image.width, imageHeight: image.height)
        guard layout.canvasWidth * layout.canvasHeight <= maximumPixels,
              let canvas = ImageConverter.makeContext(width: layout.canvasWidth, height: layout.canvasHeight, opaque: true,
                                                      like: image) else {
            throw .writeFailed("The framed picture would be too large.")
        }
        let bounds = CGRect(x: 0, y: 0, width: layout.canvasWidth, height: layout.canvasHeight)
        try fill(canvas, bounds: bounds, with: recipe.fill, photo: image)

        // Core Graphics counts up from the bottom; the layout counts down from the top.
        let photoRect = CGRect(x: layout.imageRect.x, y: layout.canvasHeight - layout.imageRect.y - layout.imageRect.height,
                               width: layout.imageRect.width, height: layout.imageRect.height)
        let radius = CGFloat(recipe.cornerRadiusPixels(imageWidth: image.width, imageHeight: image.height))
        let outline = CGPath(roundedRect: photoRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // The photo is drawn once, as a layer that casts the shadow, so the
        // shadow follows its own shape and transparent parts stay see-through.
        let shadow = recipe.shadowStrength
        let shortEdge = CGFloat(min(image.width, image.height))
        canvas.saveGState()
        if shadow > 0 {
            canvas.setShadow(offset: CGSize(width: 0, height: -shortEdge * 0.02 * shadow), blur: shortEdge * 0.06 * shadow,
                             color: CGColor(gray: 0, alpha: 0.55 * shadow))
        }
        canvas.beginTransparencyLayer(auxiliaryInfo: nil)
        canvas.addPath(outline)
        canvas.clip()
        canvas.draw(image, in: photoRect)
        canvas.endTransparencyLayer()
        canvas.restoreGState()
        guard let result = canvas.makeImage() else { throw .writeFailed("Couldn’t draw the background.") }
        return result
    }

    private static func fill(_ canvas: CGContext, bounds: CGRect, with fill: BackgroundFill, photo: CGImage) throws(ConversionError) {
        switch fill {
        case .color(let color):
            canvas.setFillColor(cgColor(color))
            canvas.fill(bounds)
        case .gradient(let start, let end, let angleDegrees):
            guard let gradient = CGGradient(colorsSpace: sRGB, colors: [cgColor(start), cgColor(end)] as CFArray, locations: [0, 1]) else {
                throw .writeFailed("Couldn’t draw the gradient.")
            }
            // 0° runs left to right and 90° top to bottom; Core Graphics' y axis points up.
            let angle = angleDegrees * .pi / 180
            let direction = CGPoint(x: cos(angle), y: -sin(angle))
            let reach = (abs(bounds.width * direction.x) + abs(bounds.height * direction.y)) / 2
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            canvas.drawLinearGradient(gradient,
                                      start: CGPoint(x: centre.x - direction.x * reach, y: centre.y - direction.y * reach),
                                      end: CGPoint(x: centre.x + direction.x * reach, y: centre.y + direction.y * reach),
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .blurredPhoto:
            // Blurred at a small fixed size and stretched: cheap for huge
            // canvases, and the preview looks the same as the saved copy.
            let small = CGRect(origin: .zero, size: CGSize(width: bounds.width, height: bounds.height)
                .applying(CGAffineTransform(scaleX: blurredBackgroundEdge / max(bounds.width, bounds.height),
                                            y: blurredBackgroundEdge / max(bounds.width, bounds.height))))
            let scale = max(small.width / CGFloat(photo.width), small.height / CGFloat(photo.height))
            let scaled = CIImage(cgImage: photo).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let offset = CGAffineTransform(translationX: (small.width - scaled.extent.width) / 2,
                                           y: (small.height - scaled.extent.height) / 2)
            let blurred = scaled.transformed(by: offset)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: blurredBackgroundEdge * 0.03)
                .cropped(to: small.integral)
            canvas.interpolationQuality = .high
            canvas.draw(try render(blurred, like: photo), in: bounds)
        }
    }

    private static let blurredBackgroundEdge: CGFloat = 512

    // MARK: Annotate

    public static func annotated(_ image: CGImage, _ annotations: [Annotation]) throws(ConversionError) -> CGImage {
        guard let canvas = ImageConverter.makeContext(width: image.width, height: image.height, opaque: false, like: image) else {
            throw .writeFailed("Couldn’t prepare the image.")
        }
        let size = CGSize(width: image.width, height: image.height)
        canvas.draw(image, in: CGRect(origin: .zero, size: size))
        // Draw from the top left, as the editor does.
        canvas.translateBy(x: 0, y: size.height)
        canvas.scaleBy(x: 1, y: -1)
        canvas.setLineCap(.round)
        canvas.setLineJoin(.round)
        for annotation in annotations {
            AnnotationPainter(canvas: canvas, size: size, annotation: annotation).paint()
        }
        guard let result = canvas.makeImage() else { throw .writeFailed("Couldn’t draw the annotations.") }
        return result
    }

    // MARK: Redact

    /// Each area is hidden in turn, working on the result so far, so a blur
    /// over an area already covered can't bring back what was under it.
    public static func redacted(_ image: CGImage, _ regions: [RedactionRegion]) throws(ConversionError) -> CGImage {
        var result = CIImage(cgImage: image)
        let shortEdge = CGFloat(min(image.width, image.height))
        let cell = { (area: CGRect) in redactionCell(for: area, imageShortEdge: shortEdge) }
        for region in regions {
            let area = pixelBounds(region.rect, width: image.width, height: image.height)
            guard !area.isEmpty else { continue }
            let only = result.cropped(to: area).clampedToExtent()
            let cover: CIImage
            switch region.style {
            case .solid:
                cover = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            case .blur:
                // Pixelated first, so no detail survives for a deblur to bring back.
                cover = pixelated(only, area: area, cell: cell(area)).applyingGaussianBlur(sigma: cell(area))
            case .pixelate:
                cover = pixelated(only, area: area, cell: cell(area))
            }
            result = cover.cropped(to: area).composited(over: result)
        }
        return try render(result.cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height)), like: image)
    }

    /// Cell size in pixels for hiding an area: half its shorter side, so a
    /// line of text is at most two cells tall, with a floor for tiny areas.
    /// Both terms grow with the picture, so a preview hides exactly as much
    /// as the full-size copy.
    static func redactionCell(for area: CGRect, imageShortEdge: CGFloat) -> CGFloat {
        max(min(area.width, area.height) / 2, imageShortEdge * 0.01)
    }

    /// Pixellate keeps one sample per cell, which can still show fine detail;
    /// averaging first makes each cell a true mean.
    private static func pixelated(_ image: CIImage, area: CGRect, cell: CGFloat) -> CIImage {
        image
            .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: cell / 2])
            .applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: cell, kCIInputCenterKey: CIVector(x: area.minX, y: area.minY),
            ])
    }

    /// The area in Core Image pixels (origin bottom left), rounded outwards
    /// so no edge pixel is left showing.
    static func pixelBounds(_ rect: CropRecipe, width: Int, height: Int) -> CGRect {
        let left = floor(min(max(rect.x, 0), 1) * Double(width))
        let right = ceil(min(max(rect.x + rect.width, 0), 1) * Double(width))
        let top = floor(min(max(rect.y, 0), 1) * Double(height))
        let bottom = ceil(min(max(rect.y + rect.height, 0), 1) * Double(height))
        guard right > left, bottom > top else { return .null }
        return CGRect(x: left, y: Double(height) - bottom, width: right - left, height: bottom - top)
    }

    public enum Detection: Sendable {
        case faces
        case text
    }

    private static let faceMargin = 0.02
    /// Vision's text boxes hug the letters, so they get a little room too.
    private static let textMargin = 0.01

    /// Faces and lines of text Vision finds, as areas ready to redact.
    public static func detect(_ kinds: Set<Detection>, in image: CGImage, style: RedactionStyle) throws(ConversionError) -> [RedactionRegion] {
        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        var requests: [VNRequest] = []
        if kinds.contains(.faces) { requests.append(faces) }
        if kinds.contains(.text) { requests.append(text) }
        guard !requests.isEmpty else { return [] }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)
        } catch {
            throw .toolFailed(tool: "Vision", message: error.localizedDescription)
        }
        let faceBoxes = kinds.contains(.faces) ? (faces.results ?? []).map { ($0.boundingBox, faceMargin) } : []
        let textBoxes = kinds.contains(.text) ? (text.results ?? []).map { ($0.boundingBox, textMargin) } : []
        return (faceBoxes + textBoxes).map { box, margin in
            RedactionRegion.fromVision(x: box.minX, y: box.minY, width: box.width, height: box.height, margin: margin, style: style)
        }
    }

    // MARK: Shared

    static func cgColor(_ color: RGBA) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// Renders in the picture's own colour space when it is RGB, else sRGB.
    private static func render(_ image: CIImage, like original: CGImage) throws(ConversionError) -> CGImage {
        let space = original.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space) else {
            throw .writeFailed("Couldn’t render the picture.")
        }
        return result
    }
}

/// Draws one annotation on a canvas already flipped to a top-left origin.
private struct AnnotationPainter {
    let canvas: CGContext
    let size: CGSize
    let annotation: Annotation

    private var shortEdge: CGFloat { min(size.width, size.height) }
    private var lineWidth: CGFloat { max(1, annotation.lineWidth * shortEdge) }
    /// Text and callouts grow with the chosen line width.
    private var scale: CGFloat { annotation.lineWidth / Annotation.defaultLineWidth }

    func paint() {
        let color = PhotoRendering.cgColor(annotation.color)
        canvas.setStrokeColor(color)
        canvas.setFillColor(color)
        canvas.setLineWidth(lineWidth)
        switch annotation.shape {
        case .arrow(let from, let to): arrow(from: point(from), to: point(to))
        case .rectangle(let from, let to): canvas.stroke(rect(from, to))
        case .ellipse(let from, let to): canvas.strokeEllipse(in: rect(from, to))
        case .highlight(let from, let to):
            canvas.saveGState()
            canvas.setBlendMode(.multiply)
            canvas.setFillColor(color.copy(alpha: 0.4) ?? color)
            canvas.fill(rect(from, to))
            canvas.restoreGState()
        case .text(let at, let string): text(string, at: point(at), color: color)
        case .callout(let at, let number): callout(number, at: point(at), color: color)
        case .freehand(let points):
            guard points.count > 1 else { return }
            canvas.addLines(between: points.map(point))
            canvas.strokePath()
        }
    }

    private func point(_ point: DropwheelCore.NormalizedPoint) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func rect(_ a: DropwheelCore.NormalizedPoint, _ b: DropwheelCore.NormalizedPoint) -> CGRect {
        let box = AnnotationGeometry.rect(from: a, to: b)
        return CGRect(x: box.x * size.width, y: box.y * size.height, width: box.width * size.width, height: box.height * size.height)
    }

    private func arrow(from start: CGPoint, to tip: CGPoint) {
        let length = max(lineWidth * 4, shortEdge * 0.02)
        let barbs = AnnotationGeometry.arrowheadBarbs(from: (start.x, start.y), to: (tip.x, tip.y), length: length)
        // The shaft stops inside the head, so its round cap doesn't poke past the point.
        let shaftEnd = CGPoint(x: (barbs.left.x + barbs.right.x) / 2, y: (barbs.left.y + barbs.right.y) / 2)
        canvas.addLines(between: [start, shaftEnd])
        canvas.strokePath()
        canvas.addLines(between: [tip, CGPoint(x: barbs.left.x, y: barbs.left.y), CGPoint(x: barbs.right.x, y: barbs.right.y)])
        canvas.closePath()
        canvas.fillPath()
    }

    private func text(_ string: String, at origin: CGPoint, color: CGColor) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, max(10, shortEdge * 0.045 * scale), nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil)
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        for (index, line) in string.components(separatedBy: .newlines).enumerated() {
            draw(line, font: font, color: color, top: CGPoint(x: origin.x, y: origin.y + CGFloat(index) * lineHeight))
        }
    }

    private func callout(_ number: Int, at centre: CGPoint, color: CGColor) {
        let radius = max(8, shortEdge * 0.03 * scale)
        canvas.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, radius * 1.1, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, radius, nil)
        let label = String(number)
        let white = CGColor(gray: 1, alpha: 1)
        let width = CTLineGetTypographicBounds(line(label, font: font, color: white), nil, nil, nil)
        let height = CTFontGetAscent(font) + CTFontGetDescent(font)
        draw(label, font: font, color: white, top: CGPoint(x: centre.x - width / 2, y: centre.y - height / 2))
    }

    private func line(_ string: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// Text would come out upside down on the flipped canvas, so it is
    /// drawn in a locally unflipped space whose origin is the text's top left.
    private func draw(_ string: String, font: CTFont, color: CGColor, top: CGPoint) {
        canvas.saveGState()
        canvas.translateBy(x: top.x, y: top.y)
        canvas.scaleBy(x: 1, y: -1)
        canvas.textPosition = CGPoint(x: 0, y: -CTFontGetAscent(font))
        CTLineDraw(line(string, font: font, color: color), canvas)
        canvas.restoreGState()
    }
}

/// Loads, changes and saves photos for the four photo tools.
enum PhotoTools {
    static func fitsInMemory(width: Int, height: Int) -> Bool {
        width * height <= PhotoRendering.maximumPixels
    }

    /// Redacted copies drop all metadata: a location or an embedded preview
    /// could give away what was hidden.
    static func apply(
        _ input: URL, format: FileFormat, output: URL, keepMetadata: Bool,
        _ change: (CGImage) throws(ConversionError) -> CGImage
    ) async throws(ConversionError) {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw .unreadableInput(input.lastPathComponent) }
        if CGImageSourceGetCount(source) > 1 { throw .multiFrame(input.lastPathComponent) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        if let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
           !fitsInMemory(width: width, height: height) {
            throw .writeFailed("\(input.lastPathComponent) is over 100 megapixels, too large to edit.")
        }
        let loaded = try ImageConverter.load(input)
        let result = ImageConverter.LoadedImage(image: try change(loaded.image),
                                                properties: keepMetadata ? loaded.properties : [:], dpi: loaded.dpi)
        if format == .webp {
            try await ImageConverter.writeWebP(result, to: output)
        } else {
            try ImageConverter.write(result, as: format, to: output)
        }
    }
}
