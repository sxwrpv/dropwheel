import AppKit
import DropwheelCore
import Foundation
import ImageIO

/// Image conversions through ImageIO, with WebP written by `cwebp` (ImageIO
/// can read WebP but not write it) and SVG rendered with AppKit.
struct ImageConverter: Converter {
    private static let lossyQuality: [FileFormat: Double] = [.jpg: 0.9, .heic: 0.85, .avif: 0.8]
    static let webpQuality = "85"
    /// SVGs have no pixel size, so they are rendered with this long edge at least,
    private static let svgMinimumLongEdge: CGFloat = 1024
    /// and never larger than this, to bound memory for huge drawings.
    private static let svgMaximumLongEdge: CGFloat = 8192
    private static let defaultDPI = 72.0

    func convert(_ input: URL, to target: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws(ConversionError) {
        progress(0)
        let source = try Self.load(input)
        try Task.checkCancellation(or: .cancelled)
        switch target {
        case .pdf:
            try Self.writePDF(source, to: output)
        case .webp:
            try await Self.writeWebP(source, to: output)
        default:
            try Self.write(source, as: target, to: output)
        }
        progress(1)
    }

    // MARK: Reading

    struct LoadedImage {
        /// Pixels already rotated upright, so the orientation tag can be reset.
        let image: CGImage
        let properties: [CFString: Any]
        let dpi: Double
    }

    static func load(_ url: URL) throws(ConversionError) -> LoadedImage {
        if FileFormat(fileName: url.lastPathComponent) == .svg {
            return try loadSVG(url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw .unreadableInput(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Without a pixel size the thumbnail call would shrink the image to 1 pixel.
        guard width > 0, height > 0 else { throw .unreadableInput(url.lastPathComponent) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw .unreadableInput(url.lastPathComponent)
        }
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? defaultDPI
        return LoadedImage(image: image, properties: properties, dpi: dpi > 0 ? dpi : defaultDPI)
    }

    private static func loadSVG(_ url: URL) throws(ConversionError) -> LoadedImage {
        guard let svg = NSImage(contentsOf: url), svg.size.width > 0, svg.size.height > 0 else {
            throw .unreadableInput(url.lastPathComponent)
        }
        let longEdge = max(svg.size.width, svg.size.height)
        let scale = min(max(svgMinimumLongEdge / longEdge, 1), svgMaximumLongEdge / longEdge)
        let width = Int((svg.size.width * scale).rounded())
        let height = Int((svg.size.height * scale).rounded())
        guard let context = makeContext(width: width, height: height, opaque: false) else {
            throw .unreadableInput(url.lastPathComponent)
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        svg.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw .unreadableInput(url.lastPathComponent) }
        return LoadedImage(image: image, properties: [:], dpi: defaultDPI * scale)
    }

    // MARK: Writing

    static func write(_ source: LoadedImage, as target: FileFormat, to output: URL) throws(ConversionError) {
        guard let type = ImageTypes.identifiers[target],
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else {
            throw .writeFailed("This Mac can’t write \(target.label) images.")
        }
        // JPEG and BMP have no transparency: put transparent images on white
        // rather than letting the encoder turn transparent areas black.
        let needsOpaque = target == .jpg || target == .bmp
        let image = needsOpaque ? try flattened(source.image) : source.image
        CGImageDestinationAddImage(destination, image, outputProperties(source.properties, target: target) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw .writeFailed("The \(target.label) encoder failed.")
        }
    }

    /// Keeps camera and location metadata, resets orientation (pixels are
    /// already upright) and sets lossy quality where it applies.
    static func outputProperties(_ properties: [CFString: Any], target: FileFormat) -> [CFString: Any] {
        var result = properties
        result[kCGImagePropertyOrientation] = 1
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let quality = lossyQuality[target] {
            result[kCGImageDestinationLossyCompressionQuality] = quality
        }
        return result
    }

    private static func writePDF(_ source: LoadedImage, to output: URL) throws(ConversionError) {
        let pointsPerPixel = 72.0 / source.dpi
        var mediaBox = CGRect(x: 0, y: 0,
                              width: Double(source.image.width) * pointsPerPixel,
                              height: Double(source.image.height) * pointsPerPixel)
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw .writeFailed("Couldn’t create the PDF.")
        }
        context.beginPDFPage(nil)
        context.draw(source.image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
    }

    /// cwebp reads PNG, so the upright pixels go through a temporary PNG.
    static func writeWebP(_ source: LoadedImage, to output: URL, quality: String = webpQuality) async throws(ConversionError) {
        let cwebp = try ToolLocator.require(.cwebp)
        let temporaryPNG = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropwheel-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporaryPNG) }
        try write(LoadedImage(image: source.image, properties: [:], dpi: source.dpi), as: .png, to: temporaryPNG)
        try await ProcessRunner.run(cwebp, arguments: ["-quiet", "-q", quality, temporaryPNG.path, "-o", output.path])
    }

    static func flattened(_ image: CGImage) throws(ConversionError) -> CGImage {
        guard hasAlpha(image) else { return image }
        guard let context = makeContext(width: image.width, height: image.height, opaque: true) else {
            throw .writeFailed("Couldn’t prepare the image.")
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flat = context.makeImage() else { throw .writeFailed("Couldn’t prepare the image.") }
        return flat
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// An 8-bit RGB context; `like` keeps that picture's colour space when it is RGB, else sRGB.
    static func makeContext(width: Int, height: Int, opaque: Bool, like original: CGImage? = nil) -> CGContext? {
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        let space = original?.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: alpha.rawValue)
    }
}
