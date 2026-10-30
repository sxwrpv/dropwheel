import CoreGraphics
import DropwheelCore
import Foundation
import ImageIO

extension PhotoRendering {
    /// The photos laid out in the recipe's grid, each filling its cell
    /// (cropped evenly from the centre), in the order given.
    public static func collage(_ images: [CGImage], recipe: CollageRecipe) throws(ConversionError) -> CGImage {
        let layout = recipe.layout(count: images.count)
        guard !images.isEmpty, layout.canvasWidth * layout.canvasHeight <= maximumPixels,
              let canvas = ImageConverter.makeContext(width: layout.canvasWidth, height: layout.canvasHeight, opaque: true,
                                                      like: images.first) else {
            throw .writeFailed("The collage would be too large.")
        }
        canvas.setFillColor(cgColor(recipe.background))
        canvas.fill(CGRect(x: 0, y: 0, width: layout.canvasWidth, height: layout.canvasHeight))
        canvas.interpolationQuality = .high
        for (image, cell) in zip(images, layout.cells) {
            // Core Graphics counts up from the bottom; the layout counts down from the top.
            let target = CGRect(x: cell.x, y: layout.canvasHeight - cell.y - cell.height, width: cell.width, height: cell.height)
            let radius = CGFloat(recipe.cornerRadiusPixels(cell: cell))
            canvas.saveGState()
            canvas.addPath(CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil))
            canvas.clip()
            canvas.draw(filling(image, cell: target.size), in: target)
            canvas.restoreGState()
        }
        guard let result = canvas.makeImage() else { throw .writeFailed("Couldn’t draw the collage.") }
        return result
    }

    /// The centre part of `image` with the cell's shape.
    private static func filling(_ image: CGImage, cell: CGSize) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = max(cell.width / width, cell.height / height)
        let crop = CGRect(x: (width - cell.width / scale) / 2, y: (height - cell.height / scale) / 2,
                          width: cell.width / scale, height: cell.height / scale).integral
        return image.cropping(to: crop) ?? image
    }
}

/// Collage, Save Frames and Redact Video, as chosen in their editors.
enum MediaEditTools {
    static func collage(_ inputs: [URL], format: FileFormat, recipe: CollageRecipe, output: URL,
                        progress: @escaping ProgressHandler) async throws(ConversionError) {
        let layout = recipe.layout(count: inputs.count)
        var images: [CGImage] = []
        for (index, (input, cell)) in zip(inputs, layout.cells).enumerated() {
            if Task.isCancelled { throw .cancelled }
            images.append(try coveringThumbnail(input, cell: cell))
            progress(Double(index + 1) / Double(inputs.count + 1))
        }
        let result = ImageConverter.LoadedImage(image: try PhotoRendering.collage(images, recipe: recipe),
                                                properties: [:], dpi: ImageConverter.defaultDPI)
        if format == .webp {
            try await ImageConverter.writeWebP(result, to: output)
        } else {
            try ImageConverter.write(result, as: format, to: output)
        }
    }

    /// An upright copy just large enough to cover `cell`, so 36 large photos
    /// don't all have to be decoded at full size.
    static func coveringThumbnail(_ url: URL, cell: PixelRect) throws(ConversionError) -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw .unreadableInput(url.lastPathComponent)
        }
        // Orientations 5–8 turn the picture a quarter turn.
        if (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5 { swap(&width, &height) }
        let scale = max(Double(cell.width) / Double(width), Double(cell.height) / Double(height))
        let longEdge = Double(max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(min((longEdge * scale).rounded(.up), longEdge)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw .unreadableInput(url.lastPathComponent)
        }
        return image
    }

    static func saveFrames(_ input: URL, export: FrameExport, output: URL,
                           progress: @escaping ProgressHandler) async throws(ConversionError) {
        let info = try await FFmpegRunner.probe(input)
        guard info.hasVideo else { throw .unreadableInput(input.lastPathComponent) }
        guard let duration = info.durationSeconds else { throw .unknownLength(input.lastPathComponent) }
        guard export.isValid(durationSeconds: duration) else { throw .invalidFrames(input.lastPathComponent) }
        switch export.plan {
        case .single(let seconds):
            // As it plays: video stored with non-square pixels is widened.
            let frame = try await MediaPreview.displayFrame(of: input, at: seconds)
            try ImageConverter.write(ImageConverter.LoadedImage(image: frame, properties: [:], dpi: ImageConverter.defaultDPI),
                                     as: export.format.fileFormat, to: output)
        case .every:
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            } catch {
                throw .writeFailed(error.localizedDescription)
            }
            let arguments = EditPlans.everyFrameArguments(input: input.path, folder: output.path, stem: input.formatStem,
                                                          export: export)
            try await FFmpegRunner.run(arguments, expectedSeconds: duration, progress: progress)
            let written = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
            guard !written.isEmpty else { throw .unreadableInput(input.lastPathComponent) }
        }
    }

    /// Measured on frames as ffmpeg sees them, already rotated, like Crop.
    /// The copy drops the file's and the streams' tags, which can name
    /// people or places.
    static func redactVideo(_ input: URL, format: FileFormat, regions: [RedactionRegion], output: URL,
                            progress: @escaping ProgressHandler) async throws(ConversionError) {
        guard !regions.isEmpty else { throw .nothingToHide(input.lastPathComponent) }
        let info = try await FFmpegRunner.probe(input)
        guard let size = info.rotatedSize else { throw .unreadableInput(input.lastPathComponent) }
        // Boxes with no area hide nothing, and a copy named "redacted" must hide something.
        guard VideoRedaction.filter(regions, width: size.width, height: size.height) != nil else {
            throw .nothingToHide(input.lastPathComponent)
        }
        let options = VideoRedaction.options(regions, width: size.width, height: size.height, format: format)
        let arguments = FFmpegArguments.command(input: input.path, options: options, output: output.path, keepMetadata: false)
        try await FFmpegRunner.run(arguments, expectedSeconds: info.durationSeconds, progress: progress)
    }
}
