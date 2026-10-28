import CoreGraphics
import CoreText
import DropwheelCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DropwheelEngines

/// End-to-end tests for Edit Photo, Add a Background, Annotate and Redact.
final class PhotoToolsTests {
    private let folder: URL
    private let tools = ToolService()

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropwheel-photo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Edit Photo

    @Test("More exposure brightens the photo and keeps its size")
    func exposure() async throws {
        let input = try write(solid(gray: 0.3, width: 120, height: 80), as: "photo.png")
        var brighter = PhotoAdjustments.neutral
        brighter.exposure = 1
        let output = try await tools.run(.editPhoto, on: [input], options: .photoEdit(brighter))
        #expect(output.lastPathComponent == "photo edited.png")
        let image = try load(output)
        #expect(image.width == 120 && image.height == 80)
        #expect(pixel(image, x: 60, y: 40).red > pixel(try load(input), x: 60, y: 40).red + 30)
    }

    @Test("Warmth shifts colour towards orange, coolness towards blue")
    func warmth() throws {
        let gray = solid(gray: 0.5, width: 40, height: 40)
        var warm = PhotoAdjustments.neutral
        warm.warmth = 0.8
        var cool = PhotoAdjustments.neutral
        cool.warmth = -0.8
        let warmPixel = pixel(try PhotoRendering.adjusted(gray, warm), x: 20, y: 20)
        let coolPixel = pixel(try PhotoRendering.adjusted(gray, cool), x: 20, y: 20)
        #expect(warmPixel.red > warmPixel.blue)
        #expect(coolPixel.blue > coolPixel.red)
    }

    @Test("Neutral adjustments return the picture untouched")
    func neutral() throws {
        let gray = solid(gray: 0.5, width: 10, height: 10)
        #expect(try PhotoRendering.adjusted(gray, .neutral) === gray)
    }

    @Test("Grain adds texture without changing overall brightness")
    func grain() throws {
        let gray = solid(gray: 0.5, width: 200, height: 200)
        var grainy = PhotoAdjustments.neutral
        grainy.grain = 1
        let image = try PhotoRendering.adjusted(gray, grainy)
        let region = CGRect(x: 0, y: 0, width: 200, height: 200)
        #expect(contrast(image, in: region) > 20)
        #expect(abs(mean(image, in: region) - mean(gray, in: region)) < 12)
    }

    @Test("Every adjustment renders, and full desaturation turns colour grey")
    func allAdjustments() throws {
        let red = draw(width: 120, height: 120) { context in
            context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }
        var everything = PhotoAdjustments.neutral
        everything.exposure = 0.2
        everything.contrast = 0.3
        everything.highlights = -0.5
        everything.shadows = 0.4
        everything.warmth = 0.2
        everything.sharpness = 0.7
        everything.noiseReduction = 0.5
        everything.vignette = 0.5
        everything.grain = 0.2
        #expect(try PhotoRendering.adjusted(red, everything).width == 120)
        var gray = PhotoAdjustments.neutral
        gray.saturation = -1
        let centre = pixel(try PhotoRendering.adjusted(red, gray), x: 60, y: 60)
        #expect(abs(centre.red - centre.green) < 12 && abs(centre.green - centre.blue) < 12)
    }

    // MARK: Add a Background

    @Test("The photo sits on a larger canvas filled with the chosen colour")
    func background() async throws {
        let input = try write(solid(gray: 0, width: 200, height: 100), as: "shot.jpg")
        let recipe = BackgroundRecipe(aspect: .free, padding: 0.1, cornerRadius: 0, shadow: 0,
                                      fill: .color(RGBA(red: 1, green: 0, blue: 0)))
        let output = try await tools.run(.addBackground, on: [input], options: .background(recipe))
        #expect(output.lastPathComponent == "shot framed.jpg")
        let image = try load(output)
        #expect(image.width == 240 && image.height == 140)
        let corner = pixel(image, x: 3, y: 3)
        #expect(corner.red > 200 && corner.green < 60)
        #expect(pixel(image, x: 120, y: 70).red < 40)
    }

    @Test("Rounded corners show the background at the photo's corners")
    func roundedCorners() throws {
        let photo = solid(gray: 0, width: 200, height: 200)
        let recipe = BackgroundRecipe(aspect: .free, padding: 0.1, cornerRadius: 0.2, shadow: 0, fill: .color(.white))
        let image = try PhotoRendering.framed(photo, recipe)
        // The photo spans 20…220; just inside its top-left corner is now rounded away.
        #expect(pixel(image, x: 22, y: 22).red > 200)
        #expect(pixel(image, x: 120, y: 120).red < 40)
    }

    @Test("A gradient runs from the first colour to the second")
    func gradient() throws {
        let photo = solid(gray: 0.5, width: 100, height: 100)
        let recipe = BackgroundRecipe(aspect: .widescreen, padding: 0, cornerRadius: 0, shadow: 0,
                                      fill: .gradient(RGBA(red: 1, green: 0, blue: 0), RGBA(red: 0, green: 0, blue: 1), angleDegrees: 0))
        let image = try PhotoRendering.framed(photo, recipe)
        let left = pixel(image, x: 2, y: 50)
        let right = pixel(image, x: image.width - 3, y: 50)
        #expect(left.red > left.blue && right.blue > right.red)
    }

    @Test("A shadow follows the photo's own shape, so transparent areas show the background")
    func transparentPhotoShadow() throws {
        let clear = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let recipe = BackgroundRecipe(aspect: .free, padding: 0.2, cornerRadius: 0.05, shadow: 1, fill: .color(.white))
        let image = try PhotoRendering.framed(clear, recipe)
        #expect(pixel(image, x: image.width / 2, y: image.height / 2).red > 240)
    }

    @Test("Wide-gamut photos keep their colour space")
    func keepsColourSpace() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let photo = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        let recipe = BackgroundRecipe(aspect: .free, padding: 0.1, cornerRadius: 0, shadow: 0, fill: .color(.white))
        #expect(try PhotoRendering.framed(photo, recipe).colorSpace?.name == CGColorSpace.displayP3)
        #expect(try PhotoRendering.annotated(photo, []).colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test("A blurred-photo background renders at any size")
    func blurredPhotoBackground() throws {
        let photo = checkerboard(size: 300, square: 30)
        let recipe = BackgroundRecipe(aspect: .widescreen, padding: 0.1, cornerRadius: 0, shadow: 0, fill: .blurredPhoto)
        let image = try PhotoRendering.framed(photo, recipe)
        #expect(contrast(image, in: CGRect(x: 2, y: 2, width: 20, height: 20)) < 40)
    }

    // MARK: Annotate

    @Test("A rectangle is drawn as an outline in its colour")
    func rectangle() async throws {
        let input = try write(solid(gray: 1, width: 200, height: 200), as: "screen.png")
        let box = Annotation(shape: .rectangle(from: NormalizedPoint(x: 0.25, y: 0.25), to: NormalizedPoint(x: 0.75, y: 0.75)),
                             color: RGBA(red: 1, green: 0, blue: 0), lineWidth: 0.02)
        let output = try await tools.run(.annotate, on: [input], options: .annotations([box]))
        #expect(output.lastPathComponent == "screen annotated.png")
        let image = try load(output)
        let edge = pixel(image, x: 50, y: 100)
        #expect(edge.red > 200 && edge.green < 60)
        #expect(pixel(image, x: 100, y: 100).green > 200)
    }

    @Test("Annotations are placed from the top left, as in the editor")
    func topLeftOrigin() throws {
        let photo = solid(gray: 1, width: 100, height: 100)
        let dot = Annotation(shape: .callout(at: NormalizedPoint(x: 0.2, y: 0.2), number: 1), color: RGBA(red: 0, green: 0, blue: 1))
        let image = try PhotoRendering.annotated(photo, [dot])
        // Beside the white number, inside the circle.
        #expect(pixel(image, x: 14, y: 20).blue > 200 && pixel(image, x: 14, y: 20).red < 100)
        #expect(pixel(image, x: 20, y: 80).red > 200)
    }

    @Test("Text, arrows and freehand lines all draw")
    func otherShapes() throws {
        let photo = solid(gray: 1, width: 300, height: 300)
        let red = RGBA(red: 1, green: 0, blue: 0)
        let shapes: [AnnotationShape] = [
            .arrow(from: NormalizedPoint(x: 0.1, y: 0.9), to: NormalizedPoint(x: 0.5, y: 0.9)),
            .text(at: NormalizedPoint(x: 0.1, y: 0.1), "Hello"),
            .freehand([NormalizedPoint(x: 0.6, y: 0.5), NormalizedPoint(x: 0.9, y: 0.5)]),
            .ellipse(from: NormalizedPoint(x: 0.6, y: 0.1), to: NormalizedPoint(x: 0.9, y: 0.3)),
            .highlight(from: NormalizedPoint(x: 0.1, y: 0.5), to: NormalizedPoint(x: 0.4, y: 0.6)),
        ]
        let image = try PhotoRendering.annotated(photo, shapes.map { Annotation(shape: $0, color: red, lineWidth: 0.02) })
        #expect(pixel(image, x: 90, y: 270).green < 80, "arrow shaft")
        #expect(pixel(image, x: 225, y: 150).green < 80, "freehand line")
        #expect(redPixels(image, in: CGRect(x: 30, y: 30, width: 120, height: 40)) > 20, "text")
        #expect(pixel(image, x: 75, y: 165).red > 200 && pixel(image, x: 75, y: 165).green < 230, "highlight tints")
    }

    // MARK: Redact

    @Test("A solid box covers its area and nothing else, and metadata is removed")
    func solidRedaction() async throws {
        let input = try write(solid(gray: 1, width: 200, height: 100), as: "id.jpg", gps: true)
        let region = RedactionRegion(rect: CropRecipe(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let output = try await tools.run(.redactPhoto, on: [input], options: .redactions([region]))
        #expect(output.lastPathComponent == "id redacted.jpg")
        let image = try load(output)
        // Rows 20…60 are covered; a vertical flip would cover 40…80 instead.
        #expect(pixel(image, x: 50, y: 25).red < 30)
        #expect(pixel(image, x: 50, y: 70).red > 220)
        #expect(pixel(image, x: 150, y: 40).red > 220)
        #expect(try properties(input)[kCGImagePropertyGPSDictionary] != nil)
        #expect(try properties(output)[kCGImagePropertyGPSDictionary] == nil)
        let tiff = try properties(output)[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        let exif = try properties(output)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
    }

    @Test("Redaction cells scale with the picture, so the preview hides as much as the saved copy")
    func redactionScalesWithPicture() {
        let face = CGRect(x: 0, y: 0, width: 100, height: 100)
        let small = PhotoRendering.redactionCell(for: face, imageShortEdge: 4000)
        let large = PhotoRendering.redactionCell(for: face.applying(CGAffineTransform(scaleX: 4, y: 4)), imageShortEdge: 16000)
        #expect(abs(large - small * 4) < 0.001)
        let tiny = CGRect(x: 0, y: 0, width: 6, height: 3)
        let tinyLarge = PhotoRendering.redactionCell(for: tiny.applying(CGAffineTransform(scaleX: 4, y: 4)), imageShortEdge: 16000)
        #expect(abs(tinyLarge - PhotoRendering.redactionCell(for: tiny, imageShortEdge: 4000) * 4) < 0.001)
    }

    @Test("A line of text is at most two cells tall")
    func textCellsCoverLetters() {
        let word = CGRect(x: 0, y: 0, width: 300, height: 30)
        #expect(PhotoRendering.redactionCell(for: word, imageShortEdge: 1000) >= 15)
    }

    @Test("Area edges round outwards, so no edge pixel stays visible")
    func pixelBoundsRoundOutwards() {
        let bounds = PhotoRendering.pixelBounds(CropRecipe(x: 0.101, y: 0.199, width: 0.3, height: 0.302), width: 100, height: 100)
        // Top-left origin rows 19…51 become Core Image rows 49…81.
        #expect(bounds == CGRect(x: 10, y: 49, width: 31, height: 32))
    }

    @Test("Pictures with several frames are refused")
    func multiFrame() async throws {
        let url = folder.appendingPathComponent("pages.tiff")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, solid(gray: 0.2, width: 10, height: 10), nil)
        CGImageDestinationAddImage(destination, solid(gray: 0.8, width: 10, height: 10), nil)
        #expect(CGImageDestinationFinalize(destination))
        await #expect(throws: ConversionError.multiFrame("pages.tiff")) {
            try await self.tools.run(.annotate, on: [url], options: .annotations([
                Annotation(shape: .callout(at: NormalizedPoint(x: 0.5, y: 0.5), number: 1), color: .red),
            ]))
        }
    }

    @Test("Pictures over 100 megapixels are refused before decoding")
    func pixelLimit() {
        #expect(PhotoTools.fitsInMemory(width: 10_000, height: 10_000))
        #expect(!PhotoTools.fitsInMemory(width: 12_000, height: 9_000))
    }

    @Test("Blur and pixelate wipe out fine detail inside the area", arguments: [RedactionStyle.blur, .pixelate])
    func softRedaction(style: RedactionStyle) throws {
        let photo = checkerboard(size: 200, square: 2)
        let region = RedactionRegion(rect: CropRecipe(x: 0.25, y: 0.25, width: 0.5, height: 0.5), style: style)
        let image = try PhotoRendering.redacted(photo, [region])
        #expect(contrast(image, in: CGRect(x: 80, y: 80, width: 40, height: 40)) < 60)
        #expect(contrast(image, in: CGRect(x: 0, y: 0, width: 30, height: 30)) > 200)
    }

    @Test("Covered areas never leak into a later blur over them")
    func overlappingRedactions() throws {
        let photo = checkerboard(size: 100, square: 2)
        let regions = [
            RedactionRegion(rect: CropRecipe(x: 0, y: 0, width: 1, height: 1), style: .solid),
            RedactionRegion(rect: CropRecipe(x: 0.2, y: 0.2, width: 0.6, height: 0.6), style: .blur),
        ]
        let image = try PhotoRendering.redacted(photo, regions)
        #expect(pixel(image, x: 50, y: 50).red < 20)
    }

    @Test("Text in a picture is found for redaction")
    func detectsText() throws {
        let photo = try textImage("CONFIDENTIAL 2026", width: 800, height: 200)
        let regions = try PhotoRendering.detect([.text], in: photo, style: .solid)
        #expect(!regions.isEmpty)
        // The words sit across the middle of the picture.
        #expect(regions.contains { $0.rect.y < 0.5 && $0.rect.y + $0.rect.height > 0.5 })
    }

    @Test("A picture with no faces gives no face regions")
    func noFaces() throws {
        #expect(try PhotoRendering.detect([.faces], in: solid(gray: 0.5, width: 200, height: 200), style: .blur).isEmpty)
    }

    @Test("Photo editors refuse other kinds of options")
    func wrongOptions() async throws {
        let input = try write(solid(gray: 0.5, width: 20, height: 20), as: "x.png")
        await #expect(throws: ConversionError.self) {
            try await self.tools.run(.redactPhoto, on: [input], options: .photoEdit(.neutral))
        }
    }

    // MARK: Helpers

    private struct RGB {
        let red: Int
        let green: Int
        let blue: Int
    }

    private func solid(gray: Double, width: Int, height: Int) -> CGImage {
        draw(width: width, height: height) { context in
            context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func checkerboard(size: Int, square: Int) -> CGImage {
        draw(width: size, height: size) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            for row in stride(from: 0, to: size, by: square) {
                for column in stride(from: 0, to: size, by: square) where (row / square + column / square).isMultiple(of: 2) {
                    context.fill(CGRect(x: column, y: row, width: square, height: square))
                }
            }
        }
    }

    private func textImage(_ text: String, width: Int, height: Int) throws -> CGImage {
        draw(width: width, height: height) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                              NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 40, y: Double(height) / 2 - 22)
            CTLineDraw(line, context)
        }
    }

    private func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        body(context)
        return context.makeImage()!
    }

    private func write(_ image: CGImage, as name: String, gps: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let type = name.hasSuffix(".jpg") ? UTType.jpeg : UTType.png
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = gps
            ? [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 53.35, kCGImagePropertyGPSLatitudeRef: "N"],
               kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam"],
               kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"]]
            : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func load(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    /// Pixels as RGBA bytes, row 0 at the top.
    private func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> RGB {
        let data = bytes(image)
        let index = (y * image.width + x) * 4
        return RGB(red: Int(data[index]), green: Int(data[index + 1]), blue: Int(data[index + 2]))
    }

    /// Largest minus smallest brightness inside `rect` (top-left origin).
    private func contrast(_ image: CGImage, in rect: CGRect) -> Int {
        let data = bytes(image)
        var values: [Int] = []
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                values.append(Int(data[(y * image.width + x) * 4]))
            }
        }
        return (values.max() ?? 0) - (values.min() ?? 0)
    }

    private func mean(_ image: CGImage, in rect: CGRect) -> Double {
        let data = bytes(image)
        var total = 0
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                total += Int(data[(y * image.width + x) * 4])
                count += 1
            }
        }
        return Double(total) / Double(max(count, 1))
    }

    private func redPixels(_ image: CGImage, in rect: CGRect) -> Int {
        let data = bytes(image)
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let index = (y * image.width + x) * 4
                if data[index] > 180, data[index + 1] < 90 { count += 1 }
            }
        }
        return count
    }
}
