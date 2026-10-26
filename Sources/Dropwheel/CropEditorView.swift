import DropwheelCore
import DropwheelEngines
import ImageIO
import SwiftUI

/// Crop for images and video: drag the box or its corners, pick an aspect
/// ratio, and (for images) optionally resize the result to exact pixels.
struct CropEditorView: View {
    private static let previewMaximumEdge = 2048
    private static let largestOutputEdge = 20_000
    /// 100 megapixels, matching the engine's limit.
    private static let largestOutputPixels = 100_000_000

    let url: URL
    let isVideo: Bool
    let onSave: (ToolOptions) -> Void
    let onCancel: () -> Void

    @State private var preview: CGImage?
    /// The picture's real size in pixels, as displayed (upright).
    @State private var pixelSize: (width: Int, height: Int)?
    @State private var loadError: String?
    @State private var crop = CropRecipe.whole
    @State private var aspect = AspectRatio.free
    @State private var exactSize = false
    @State private var widthText = ""
    @State private var heightText = ""

    var body: some View {
        VStack(spacing: 12) {
            canvas
            controls
            EditorFooter(canSave: canSave, onCancel: onCancel, onSave: save) {
                Text(selectionLabel).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .task { await loadPreview() }
        // Until the user takes over the size fields, they mirror the crop, so
        // ticking "Resize to" never stretches the picture by surprise.
        .onChange(of: crop) { _ in
            if !exactSize { syncSizeFields() }
        }
    }

    private func syncSizeFields() {
        guard let rect = croppedRect else { return }
        widthText = String(rect.width)
        heightText = String(rect.height)
    }

    private var croppedRect: PixelRect? {
        pixelSize.map { crop.pixelRect(imageWidth: $0.width, imageHeight: $0.height, even: isVideo) }
    }

    @ViewBuilder private var canvas: some View {
        if let preview, let pixelSize {
            GeometryReader { geometry in
                let fitted = fittedSize(image: CGSize(width: pixelSize.width, height: pixelSize.height), in: geometry.size)
                ZStack {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                    CropOverlay(crop: $crop, ratio: lockedRatio, canvas: fitted)
                        .frame(width: fitted.width, height: fitted.height)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        } else if let loadError {
            ContentUnavailableNote(text: loadError)
        } else {
            ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Aspect", selection: $aspect) {
                ForEach(AspectRatio.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(width: 160)
            .onChange(of: aspect) { newValue in
                guard let pixelSize else { return }
                crop = CropRecipe.largest(newValue, imageWidth: pixelSize.width, imageHeight: pixelSize.height)
            }
            if !isVideo {
                Toggle("Resize to", isOn: $exactSize)
                TextField("Width", text: $widthText).frame(width: 64).disabled(!exactSize)
                Text("×")
                TextField("Height", text: $heightText).frame(width: 64).disabled(!exactSize)
                Text("px").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset") {
                aspect = .free
                crop = .whole
            }
        }
    }

    /// Width ÷ height of the locked aspect in normalised crop units, or nil when free.
    private var lockedRatio: Double? {
        guard let pixelSize else { return nil }
        let wanted = aspect == .original ? Double(pixelSize.width) / Double(pixelSize.height) : aspect.ratio
        return wanted.map { $0 * Double(pixelSize.height) / Double(pixelSize.width) }
    }

    private var selectionLabel: String {
        guard let pixelSize else { return "" }
        let rect = crop.pixelRect(imageWidth: pixelSize.width, imageHeight: pixelSize.height, even: isVideo)
        return "\(rect.width) × \(rect.height) px"
    }

    private var outputSize: (Int, Int)? {
        guard exactSize, let width = Int(widthText), let height = Int(heightText),
              (1...Self.largestOutputEdge).contains(width), (1...Self.largestOutputEdge).contains(height),
              width * height <= Self.largestOutputPixels else { return nil }
        return (width, height)
    }

    /// Save needs a crop that removes something, or a valid exact size;
    /// an invalid size while "Resize to" is ticked blocks saving.
    private var canSave: Bool {
        guard let pixelSize, let rect = croppedRect else { return false }
        if exactSize { return outputSize != nil }
        return rect.width < pixelSize.width || rect.height < pixelSize.height
    }

    private func save() {
        let size = outputSize
        onSave(.crop(crop, outputWidth: size?.0, outputHeight: size?.1))
    }

    // MARK: Loading

    private func loadPreview() async {
        do {
            if isVideo {
                let info = try await MediaPreview.info(of: url)
                let middle = (info.durationSeconds ?? 0) / 2
                let frame = try await MediaPreview.frame(of: url, at: middle)
                pixelSize = info.rotatedSize ?? (frame.width, frame.height)
                preview = frame
            } else {
                let loaded = try Self.loadImage(url)
                pixelSize = loaded.size
                preview = loaded.image
            }
            syncSizeFields()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// An upright preview no larger than 2048 pixels, plus the real upright size.
    private static func loadImage(_ url: URL) throws(ConversionError) -> (image: CGImage, size: (Int, Int)) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw .unreadableInput(url.lastPathComponent)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), previewMaximumEdge),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw .unreadableInput(url.lastPathComponent)
        }
        // Orientations 5–8 turn the picture a quarter turn.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (image, orientation >= 5 ? (height, width) : (width, height))
    }

    private func fittedSize(image: CGSize, in space: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(space.width / image.width, space.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

/// The draggable crop box: drag inside to move, drag a corner to resize.
private struct CropOverlay: View {
    private static let handleSize: CGFloat = 14
    private static let smallestShare = 0.02

    @Binding var crop: CropRecipe
    /// Locked width ÷ height in normalised units, or nil for free-form.
    let ratio: Double?
    let canvas: CGSize

    @State private var dragStart: CropRecipe?

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        let frame = CGRect(x: crop.x * canvas.width, y: crop.y * canvas.height,
                           width: crop.width * canvas.width, height: crop.height * canvas.height)
        ZStack(alignment: .topLeading) {
            // Dim everything outside the crop.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: canvas))
                path.addRect(frame)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .gesture(moveGesture)

            ForEach(Corner.allCases, id: \.self) { corner in
                let point = position(of: corner, in: frame)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: Self.handleSize, height: Self.handleSize)
                    .offset(x: point.x - Self.handleSize / 2, y: point.y - Self.handleSize / 2)
                    .gesture(resizeGesture(corner))
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    private func position(of corner: Corner, in frame: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: frame.minX, y: frame.minY)
        case .topRight: CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeft: CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomRight: CGPoint(x: frame.maxX, y: frame.maxY)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? crop
                dragStart = start
                let x = min(max(start.x + value.translation.width / canvas.width, 0), 1 - start.width)
                let y = min(max(start.y + value.translation.height / canvas.height, 0), 1 - start.height)
                crop = CropRecipe(x: x, y: y, width: start.width, height: start.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Moves the dragged corner; the opposite corner stays put. With a locked
    /// ratio the height follows the width.
    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? crop
                dragStart = start
                let dx = value.translation.width / canvas.width
                let dy = value.translation.height / canvas.height
                let movesLeft = corner == .topLeft || corner == .bottomLeft
                let movesTop = corner == .topLeft || corner == .topRight

                var width = movesLeft ? start.width - dx : start.width + dx
                width = min(max(width, Self.smallestShare), movesLeft ? start.x + start.width : 1 - start.x)
                var height = movesTop ? start.height - dy : start.height + dy
                if let ratio {
                    height = width / ratio
                }
                height = min(max(height, Self.smallestShare), movesTop ? start.y + start.height : 1 - start.y)
                if let ratio {
                    width = height * ratio
                }
                let x = movesLeft ? start.x + start.width - width : start.x
                let y = movesTop ? start.y + start.height - height : start.y
                crop = CropRecipe(x: x, y: y, width: width, height: height)
            }
            .onEnded { _ in dragStart = nil }
    }
}

/// A centred message for when a preview can't be shown.
struct ContentUnavailableNote: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
