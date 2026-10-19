import CoreGraphics
import DropwheelCore
import Foundation
import ImageIO

/// Compress, Remove Metadata and Create PDF for images.
enum ImageTools {
    private static let presetQuality: [CompressionLevel: Double] = [.light: 0.8, .balanced: 0.6, .strong: 0.4]
    /// PNG and TIFF are lossless, so presets shrink them by resizing instead.
    private static let losslessScale: [CompressionLevel: Double] = [.light: 1, .balanced: 0.75, .strong: 0.5]
    /// The strong preset also caps very large photos at this long edge.
    private static let strongMaximumEdge = 2560.0
    private static let lowestQuality = 0.05
    private static let highestQuality = 0.95
    private static let qualitySearchSteps = 7
    private static let maximumResizeSteps = 8
    /// File size grows roughly with pixel count, so a resize aims for the
    /// square root of the size ratio, with a little margin.
    private static let resizeMargin = 0.95
    private static let largestResizeStep = 0.8
    private static let smallestResizeStep = 0.25
    private static let smallestEdge = 64.0
    private static let lzwCompression = 5
    private static let lossyFormats: Set<FileFormat> = [.jpg, .heic, .avif, .webp]
    /// Resolutions outside this range are treated as missing (72 dpi).
    private static let plausibleDPI = 1.0...9_600.0
    /// PDF viewers struggle with pages larger than this (200 inches).
    private static let maximumPageEdgePoints = 14_400.0

    // MARK: Compress

    static func compress(_ input: URL, goal: CompressionGoal, output: URL) async throws(ConversionError) {
        guard let format = FileFormat(fileName: input.lastPathComponent) else { throw .unreadableInput(input.lastPathComponent) }
        try requireSingleFrame(input)
        let source = try ImageConverter.load(input)
        let originalBytes = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let session = EncodeSession()
        defer { session.cleanUp() }

        let data: Data
        if let target = goal.targetBytes(originalBytes: originalBytes) {
            data = try await fit(source, as: format, within: target, name: input.lastPathComponent, session: session)
        } else if case .level(let level) = goal {
            data = try await preset(level, source: source, format: format, session: session)
        } else {
            throw .unsupported(input: input.lastPathComponent, target: format)
        }
        do {
            try data.write(to: output)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    private static func preset(_ level: CompressionLevel, source: ImageConverter.LoadedImage, format: FileFormat,
                               session: EncodeSession) async throws(ConversionError) -> Data {
        if lossyFormats.contains(format) {
            let image = level == .strong ? try scaled(source.image, toFit: strongMaximumEdge) : source.image
            return try await encode(image, properties: source.properties, as: format,
                                    quality: presetQuality[level] ?? 0.6, session: session)
        }
        let image = try scaled(source.image, by: losslessScale[level] ?? 1)
        return try await encode(image, properties: source.properties, as: format, quality: nil, session: session)
    }

    /// One encode per size checks whether the target is reachable at all;
    /// only then is the quality searched. Each resize starts from the
    /// original pixels, so quality never degrades across steps.
    private static func fit(_ source: ImageConverter.LoadedImage, as format: FileFormat, within target: Int, name: String,
                            session: EncodeSession) async throws(ConversionError) -> Data {
        let isLossy = lossyFormats.contains(format)
        var scale = 1.0
        for _ in 0...maximumResizeSteps {
            try Task.checkCancellation(or: .cancelled)
            let image = try scaled(source.image, by: scale)
            let smallest = try await encode(image, properties: source.properties, as: format,
                                            quality: isLossy ? lowestQuality : nil, session: session)
            if smallest.count <= target {
                guard isLossy else { return smallest }
                return try await bestQuality(image, properties: source.properties, as: format, within: target,
                                             fallback: smallest, session: session)
            }
            let step = (Double(target) / Double(smallest.count)).squareRoot() * resizeMargin
            scale *= min(max(step, smallestResizeStep), largestResizeStep)
            guard Double(min(source.image.width, source.image.height)) * scale >= smallestEdge else { break }
        }
        throw .targetTooSmall(name)
    }

    /// Highest quality that fits, given that `fallback` (the lowest) already does.
    private static func bestQuality(_ image: CGImage, properties: [CFString: Any], as format: FileFormat, within target: Int,
                                    fallback: Data, session: EncodeSession) async throws(ConversionError) -> Data {
        var low = lowestQuality
        var high = highestQuality
        var best = fallback
        for _ in 0..<qualitySearchSteps {
            try Task.checkCancellation(or: .cancelled)
            let quality = (low + high) / 2
            let data = try await encode(image, properties: properties, as: format, quality: quality, session: session)
            if data.count <= target {
                best = data
                low = quality
            } else {
                high = quality
            }
        }
        return best
    }

    private static func encode(_ image: CGImage, properties: [CFString: Any], as format: FileFormat, quality: Double?,
                               session: EncodeSession) async throws(ConversionError) -> Data {
        if format == .webp {
            return try await session.webP(of: image, quality: quality ?? 0.85)
        }
        guard let type = ImageTypes.identifiers[format] else { throw .unsupported(input: "image", target: format) }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, type as CFString, 1, nil) else {
            throw .writeFailed("This Mac can’t write \(format.label) images.")
        }
        var options = ImageConverter.outputProperties(properties, target: format)
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        if format == .tiff {
            var tiff = options[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = lzwCompression
            options[kCGImagePropertyTIFFDictionary] = tiff
        }
        let encoded = format == .jpg ? try ImageConverter.flattened(image) : image
        CGImageDestinationAddImage(destination, encoded, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .writeFailed("The \(format.label) encoder failed.") }
        return buffer as Data
    }

    private static func scaled(_ image: CGImage, toFit maximumEdge: Double) throws(ConversionError) -> CGImage {
        let longEdge = Double(max(image.width, image.height))
        return longEdge > maximumEdge ? try scaled(image, by: maximumEdge / longEdge) : image
    }

    /// Resizes in the image's own colour space and bit depth, so wide-gamut
    /// and 16-bit photos keep them.
    private static func scaled(_ image: CGImage, by factor: Double) throws(ConversionError) -> CGImage {
        guard factor < 1 else { return image }
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitsPerComponent = image.bitsPerComponent == 16 ? 16 : 8
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ?? ImageConverter.makeContext(width: width, height: height, opaque: false)
        guard let context else { throw .writeFailed("Couldn’t resize the image.") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw .writeFailed("Couldn’t resize the image.") }
        return result
    }

    // MARK: Remove metadata

    /// JPEG is copied without re-encoding, keeping only the orientation.
    /// For other formats ImageIO's copy leaves EXIF, GPS or XMP behind, so
    /// they are re-encoded with no metadata at all (lossless for PNG and
    /// TIFF, high quality for HEIC, AVIF and WebP).
    static func stripMetadata(_ input: URL, output: URL) async throws(ConversionError) {
        guard let format = FileFormat(fileName: input.lastPathComponent) else { throw .unreadableInput(input.lastPathComponent) }
        try requireSingleFrame(input)
        if format == .jpg, copyWithoutMetadata(input, to: output), !hasPersonalMetadata(output) {
            return
        }
        try? FileManager.default.removeItem(at: output)
        let loaded = try ImageConverter.load(input)
        if format == .webp {
            // cwebp writes no metadata.
            try await ImageConverter.writeWebP(loaded, to: output, quality: "95")
            return
        }
        try ImageConverter.write(ImageConverter.LoadedImage(image: loaded.image, properties: [:], dpi: loaded.dpi),
                                 as: format, to: output)
    }

    private static func copyWithoutMetadata(_ input: URL, to output: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else { return false }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let metadata = CGImageMetadataCreateMutable()
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                         kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]
        return CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil)
    }

    /// Anything beyond the picture's own geometry counts as personal: GPS,
    /// IPTC, camera EXIF, or TIFF fields such as Artist, Make and Model.
    private static func hasPersonalMetadata(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return true }
        if properties[kCGImagePropertyGPSDictionary] != nil || properties[kCGImagePropertyIPTCDictionary] != nil { return true }
        let structuralEXIF: Set<String> = [kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
                                           kCGImagePropertyExifColorSpace].map { $0 as String }.reduce(into: []) { $0.insert($1) }
        let structuralTIFF: Set<String> = [kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFResolutionUnit,
                                           kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution]
            .map { $0 as String }.reduce(into: []) { $0.insert($1) }
        let exifKeys = (properties[kCGImagePropertyExifDictionary] as? [String: Any])?.keys ?? [:].keys
        let tiffKeys = (properties[kCGImagePropertyTIFFDictionary] as? [String: Any])?.keys ?? [:].keys
        return exifKeys.contains { !structuralEXIF.contains($0) } || tiffKeys.contains { !structuralTIFF.contains($0) }
    }

    // MARK: Create PDF

    /// One page per image, in selection order, each sized to its image.
    /// Upright JPEGs are embedded as they are rather than re-rasterised.
    static func createPDF(from inputs: [URL], output: URL, progress: @escaping ProgressHandler) throws(ConversionError) {
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw .writeFailed("Couldn’t create the PDF.")
        }
        defer { context.closePDF() }
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation(or: .cancelled)
            try requireSingleFrame(input)
            let page = try pageImage(input)
            var box = pageRect(width: page.image.width, height: page.image.height, dpi: page.dpi)
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData]
            context.beginPDFPage(pageInfo as CFDictionary)
            context.draw(page.image, in: box)
            context.endPDFPage()
            progress(Double(index + 1) / Double(inputs.count))
        }
    }

    private static func pageImage(_ input: URL) throws(ConversionError) -> ImageConverter.LoadedImage {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw .unreadableInput(input.lastPathComponent) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        // An image decoded straight from its source keeps its compressed data,
        // which CoreGraphics can embed in the PDF without re-encoding.
        if orientation == 1, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return ImageConverter.LoadedImage(image: image, properties: properties, dpi: dpi)
        }
        return try ImageConverter.load(input)
    }

    private static func pageRect(width: Int, height: Int, dpi: Double) -> CGRect {
        let pointsPerPixel = 72.0 / (plausibleDPI.contains(dpi) ? dpi : 72.0)
        var pageWidth = Double(width) * pointsPerPixel
        var pageHeight = Double(height) * pointsPerPixel
        let longEdge = max(pageWidth, pageHeight)
        if longEdge > maximumPageEdgePoints {
            pageWidth *= maximumPageEdgePoints / longEdge
            pageHeight *= maximumPageEdgePoints / longEdge
        }
        return CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
    }

    // MARK: Helpers

    /// Multi-page TIFFs and animated images would silently lose all but
    /// their first frame, so they are refused.
    private static func requireSingleFrame(_ input: URL) throws(ConversionError) {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw .unreadableInput(input.lastPathComponent) }
        if CGImageSourceGetCount(source) > 1 { throw .multiFrame(input.lastPathComponent) }
    }
}

/// Temporary files for one compress run: the PNG that cwebp reads is written
/// once per image size, not once per quality tried.
private final class EncodeSession: @unchecked Sendable {
    private let lock = NSLock()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dropwheel-encode-\(UUID().uuidString)", isDirectory: true)
    private var pngForImage: [ObjectIdentifier: URL] = [:]

    func webP(of image: CGImage, quality: Double) async throws(ConversionError) -> Data {
        let png = try intermediatePNG(for: image)
        let cwebp = try ToolLocator.require(.cwebp)
        let output = directory.appendingPathComponent("\(UUID().uuidString).webp")
        defer { try? FileManager.default.removeItem(at: output) }
        try await ProcessRunner.run(cwebp, arguments: ["-quiet", "-q", String(Int((quality * 100).rounded())),
                                                       png.path, "-o", output.path])
        guard let data = try? Data(contentsOf: output) else { throw .writeFailed("cwebp produced no file.") }
        return data
    }

    private func intermediatePNG(for image: CGImage) throws(ConversionError) -> URL {
        let key = ObjectIdentifier(image)
        if let existing = lock.withLock({ pngForImage[key] }) { return existing }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        let png = directory.appendingPathComponent("\(UUID().uuidString).png")
        try ImageConverter.write(ImageConverter.LoadedImage(image: image, properties: [:], dpi: 72), as: .png, to: png)
        lock.withLock { pngForImage[key] = png }
        return png
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
