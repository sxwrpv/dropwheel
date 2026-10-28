import DropwheelCore
import DropwheelEngines
import ImageIO
import SwiftUI

/// Upright, size-limited previews for the picture editors.
enum PreviewImage {
    static let maximumEdge = 2048

    /// A preview no larger than `maximumEdge`, plus the picture's real upright size.
    static func load(_ url: URL, maximumEdge: Int = maximumEdge) throws(ConversionError) -> (image: CGImage, size: (width: Int, height: Int)) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw .unreadableInput(url.lastPathComponent) }
        // Multi-page TIFFs and burst photos can't be saved back as one picture,
        // so say so now rather than after the editing is done.
        if CGImageSourceGetCount(source) > 1 { throw .multiFrame(url.lastPathComponent) }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw .unreadableInput(url.lastPathComponent)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maximumEdge),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw .unreadableInput(url.lastPathComponent)
        }
        // Orientations 5–8 turn the picture a quarter turn.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (image, orientation >= 5 ? (height, width) : (width, height))
    }

    typealias Loaded = (image: CGImage, size: (width: Int, height: Int))

    /// Decodes off the main thread, so a large photo doesn't stall the window as it opens.
    static func loadInBackground(_ url: URL, maximumEdge: Int = maximumEdge) async -> Result<Loaded, ConversionError> {
        await Task.detached(priority: .userInitiated) {
            Result { () throws(ConversionError) in try load(url, maximumEdge: maximumEdge) }
        }.value
    }

    /// The largest size with the picture's shape that fits in `space`.
    static func fittedSize(image: CGSize, in space: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(space.width / image.width, space.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

/// A picture fitted into the available space, with an overlay drawn in the
/// same frame. Drags report points as shares of the picture, origin top left.
struct PhotoCanvas<Overlay: View>: View {
    let image: CGImage
    var onDrag: ((_ start: NormalizedPoint, _ current: NormalizedPoint) -> Void)?
    var onDragEnd: ((_ start: NormalizedPoint, _ end: NormalizedPoint) -> Void)?
    @ViewBuilder var overlay: (CGSize) -> Overlay

    var body: some View {
        GeometryReader { geometry in
            let fitted = PreviewImage.fittedSize(image: CGSize(width: image.width, height: image.height), in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                overlay(fitted)
                    .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
            }
            .frame(width: fitted.width, height: fitted.height)
            .contentShape(Rectangle())
            .gesture(drag(in: fitted), including: onDrag == nil && onDragEnd == nil ? .subviews : .all)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onDrag?(normalized(value.startLocation, in: size), normalized(value.location, in: size))
            }
            .onEnded { value in
                onDragEnd?(normalized(value.startLocation, in: size), normalized(value.location, in: size))
            }
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> NormalizedPoint {
        guard size.width > 0, size.height > 0 else { return NormalizedPoint(x: 0, y: 0) }
        return NormalizedPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
    }
}

extension PhotoCanvas where Overlay == EmptyView {
    init(image: CGImage) {
        self.init(image: image, onDrag: nil, onDragEnd: nil) { _ in EmptyView() }
    }
}

extension RGBA {
    /// The colour in sRGB, as a colour picker reports it.
    init(_ color: CGColor) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB).flatMap {
            color.converted(to: $0, intent: .defaultIntent, options: nil)
        }
        let parts = srgb?.components ?? [0, 0, 0, 1]
        let gray = parts.count < 4
        self.init(red: Double(parts[0]), green: Double(gray ? parts[0] : parts[1]),
                  blue: Double(gray ? parts[0] : parts[2]), alpha: Double(parts.last ?? 1))
    }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// A labelled slider with its value shown. Double-click returns it to rest.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = min(max(0, range.lowerBound), range.upperBound) }
            Slider(value: $value, in: range)
        }
    }
}
