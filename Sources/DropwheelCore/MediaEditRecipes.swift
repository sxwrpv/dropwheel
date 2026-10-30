import Foundation

// MARK: Collage

public struct GridSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
}

/// Where each photo goes on the collage, in pixels (origin top left).
public struct CollageLayout: Equatable, Sendable {
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let cells: [PixelRect]
}

/// Photos in a grid, in selection order, each filling its cell.
public struct CollageRecipe: Equatable, Sendable {
    public static let maximumImages = 36
    public static let spacingRange = 0.0...0.1
    public static let cornerRange = 0.0...0.5
    public static let longEdgeChoices = [1600, 2400, 3200, 4800]

    /// Nil picks a near-square grid.
    public var columns: Int?
    /// Free or Original: the canvas fits square cells.
    public var aspect: AspectRatio
    /// Width or height of the result, whichever is longer, in pixels.
    public var longEdge: Int
    /// Gap between and around the photos, as a share of the canvas's short edge.
    public var spacing: Double
    /// Corner rounding, as a share of a cell's short edge.
    public var cornerRadius: Double
    public var background: RGBA

    public init(columns: Int?, aspect: AspectRatio, longEdge: Int, spacing: Double, cornerRadius: Double, background: RGBA) {
        self.columns = columns
        self.aspect = aspect
        self.longEdge = longEdge
        self.spacing = spacing
        self.cornerRadius = cornerRadius
        self.background = background
    }

    public static let standard = CollageRecipe(columns: nil, aspect: .free, longEdge: 2400, spacing: 0.015,
                                               cornerRadius: 0, background: .white)

    public func grid(count: Int) -> GridSize {
        let count = max(count, 1)
        let automatic = Int(Double(count).squareRoot().rounded(.up))
        let columns = min(max(self.columns ?? automatic, 1), count)
        return GridSize(columns: columns, rows: (count + columns - 1) / columns)
    }

    public func layout(count: Int) -> CollageLayout {
        let grid = grid(count: count)
        let ratio = aspect.ratio ?? Double(grid.columns) / Double(grid.rows)
        let edge = max(longEdge, 1)
        let width = ratio >= 1 ? edge : max(Int((Double(edge) * ratio).rounded()), 1)
        let height = ratio >= 1 ? max(Int((Double(edge) / ratio).rounded()), 1) : edge
        let requestedGap = Int((Self.fit(spacing, Self.spacingRange) * Double(min(width, height))).rounded())
        // At most a quarter of a cell's unspaced size, so many rows never squeeze cells to nothing.
        let gap = min(requestedGap, min(width / grid.columns, height / grid.rows) / 4)
        let cellWidth = max((width - (grid.columns + 1) * gap) / grid.columns, 1)
        let cellHeight = max((height - (grid.rows + 1) * gap) / grid.rows, 1)
        let gridHeight = grid.rows * cellHeight + (grid.rows - 1) * gap
        let top = (height - gridHeight) / 2

        var cells: [PixelRect] = []
        for index in 0..<max(count, 0) {
            let row = index / grid.columns
            let inRow = row == grid.rows - 1 ? count - grid.columns * (grid.rows - 1) : grid.columns
            let rowWidth = inRow * cellWidth + (inRow - 1) * gap
            let left = (width - rowWidth) / 2
            let column = index % grid.columns
            cells.append(PixelRect(x: left + column * (cellWidth + gap), y: top + row * (cellHeight + gap),
                                   width: cellWidth, height: cellHeight))
        }
        return CollageLayout(canvasWidth: width, canvasHeight: height, cells: cells)
    }

    public func cornerRadiusPixels(cell: PixelRect) -> Int {
        Int((Self.fit(cornerRadius, Self.cornerRange) * Double(min(cell.width, cell.height))).rounded())
    }

    private static func fit(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isNaN ? 0 : min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: Save Frames

public enum FrameImageFormat: String, CaseIterable, Sendable {
    case png
    case jpg

    public var title: String { self == .png ? "PNG" : "JPEG" }
    public var fileFormat: FileFormat { self == .png ? .png : .jpg }
}

public enum FramePlan: Equatable, Sendable {
    /// The one frame shown at this time.
    case single(seconds: Double)
    /// A frame every so many seconds, from the start, into a folder.
    case every(seconds: Double)
}

public struct FrameExport: Equatable, Sendable {
    public static let maximumFrames = 1000
    public static let shortestInterval = 0.1

    public let plan: FramePlan
    public let format: FrameImageFormat

    public init(plan: FramePlan, format: FrameImageFormat) {
        self.plan = plan
        self.format = format
    }

    public func frameCount(durationSeconds: Double) -> Int {
        switch plan {
        case .single:
            return 1
        case .every(let seconds):
            guard seconds > 0, seconds.isFinite, durationSeconds > 0, durationSeconds.isFinite else { return 0 }
            // Clamped, so an absurdly small interval can't overflow the count.
            return Int(min((durationSeconds / seconds).rounded(.up), Double(Self.maximumFrames + 1)))
        }
    }

    /// A single frame inside the video, or between two and `maximumFrames` frames.
    public func isValid(durationSeconds: Double) -> Bool {
        switch plan {
        case .single(let seconds):
            return seconds.isFinite && seconds >= 0 && seconds <= durationSeconds
        case .every(let seconds):
            guard seconds.isFinite, seconds >= Self.shortestInterval else { return false }
            return (2...Self.maximumFrames).contains(frameCount(durationSeconds: durationSeconds))
        }
    }

    /// "frame at 12.35s" for one frame, "frames" for a folder of them.
    public var suffix: String {
        switch plan {
        case .single(let seconds): "frame at \(MediaToolPlans.number((seconds * 100).rounded() / 100))s"
        case .every: "frames"
        }
    }
}

extension EditPlans {
    /// Widens frames stored with non-square pixels to the shape they play at.
    public static let squarePixels = "scale=iw*sar:ih,setsar=1"

    /// One picture every so many seconds, numbered "clip 0001.jpg" and up.
    public static func everyFrameArguments(input: String, folder: String, stem: String, export: FrameExport) -> [String] {
        guard case .every(let seconds) = export.plan else { return [] }
        // The image writer reads % anywhere in the path as a placeholder, so a literal one is doubled.
        let path = "\(folder)/\(stem) "
        let pattern = path.replacingOccurrences(of: "%", with: "%%") + "%04d.\(export.format.fileFormat.preferredExtension)"
        let quality = export.format == .jpg ? ["-q:v", "2"] : []
        // 1/interval rather than its decimal value: ffmpeg turns it back into an
        // exact rate (1/60, 2/5), so frames far into a long video don't drift.
        let filter = "fps=1/\(MediaToolPlans.number(seconds)),\(squarePixels)"
        return FFmpegArguments.command(input: input, options: ["-map", "0:V:0", "-vf", filter] + quality,
                                       output: pattern, keepMetadata: false)
    }
}

// MARK: Redact Video

extension RedactionRegion {
    /// Cell size in pixels for hiding an area: half its shorter side, so a
    /// line of text is at most two cells tall, with a floor for tiny areas.
    /// Both terms grow with the picture, so a preview hides exactly as much
    /// as the full-size result.
    public static func cellSize(areaWidth: Double, areaHeight: Double, imageShortEdge: Double) -> Double {
        max(min(areaWidth, areaHeight) / 2, imageShortEdge * 0.01)
    }
}

/// Static boxes hidden for the whole length of a video, as an ffmpeg filter.
///
/// Each box works on the result so far, as for photos. Boxes go into layers:
/// one layer above every earlier box they overlap, so the boxes in a layer
/// never overlap and can all be cut from that layer's input by one split.
public enum VideoRedaction {
    /// A layer with n blurred or pixelated boxes gives each frame n + 1 routes
    /// through it, and the routes multiply from layer to layer; ffmpeg's work
    /// per frame grows with that product (eight layers of five boxes would be
    /// 1.7 million). Soft boxes that would take it past this limit are drawn
    /// solid instead, which hides more, never less.
    public static let maximumFilterRoutes = 4096
    /// The largest blur ffmpeg's gblur accepts.
    static let largestBlurSigma = 1024.0

    private struct Box {
        let area: PixelRect
        let style: RedactionStyle
    }

    private struct Plan {
        let layers: [[Box]]
        /// Soft boxes drawn solid to stay within `maximumFilterRoutes`.
        let drawnSolid: Int
    }

    /// Nil when no box covers at least one pixel.
    public static func filter(_ regions: [RedactionRegion], width: Int, height: Int) -> String? {
        let layers = plan(regions, width: width, height: height).layers
        guard !layers.isEmpty else { return nil }
        let shortEdge = Double(min(width, height))
        return layers.enumerated()
            .map { index, layer in layerFilter(layer, index: index, shortEdge: shortEdge) }
            .joined(separator: ",")
    }

    /// How many blurred or pixelated boxes are drawn solid because of
    /// `maximumFilterRoutes`.
    public static func solidFallbackCount(_ regions: [RedactionRegion], width: Int, height: Int) -> Int {
        plan(regions, width: width, height: height).drawnSolid
    }

    /// Encoder options with the redaction placed before the format's own
    /// filter; the copy keeps every audio track untouched but none of the
    /// streams' tags, which can name people or places.
    public static func options(_ regions: [RedactionRegion], width: Int, height: Int, format: FileFormat) -> [String] {
        EditPlans.videoOptions(filter: filter(regions, width: width, height: height), keepingFormatFilter: true,
                               format: format, extra: ["-map_metadata:s:v", "-1", "-map_metadata:s:a", "-1"])
    }

    /// The boxes in layers, soft boxes past the route limit turned solid.
    private static func plan(_ regions: [RedactionRegion], width: Int, height: Int) -> Plan {
        guard width > 0, height > 0 else { return Plan(layers: [], drawnSolid: 0) }
        let boxes = regions.compactMap { region in
            area(region.rect, width: width, height: height).map { Box(area: $0, style: region.style) }
        }
        var levels: [Int] = []
        for (index, box) in boxes.enumerated() {
            let below = boxes.indices.prefix(index).filter { overlaps(boxes[$0].area, box.area) }.map { levels[$0] }
            levels.append((below.max() ?? -1) + 1)
        }
        let layers = (0..<((levels.max() ?? -1) + 1)).map { level in
            zip(boxes, levels).filter { $0.1 == level }.map(\.0)
        }
        var routes = 1
        var drawnSolid = 0
        var limited: [[Box]] = []
        for layer in layers {
            // As many of the layer's soft boxes as keep routes × (kept + 1) within the limit, in order.
            let soft = layer.filter { $0.style != .solid }.count
            let kept = min(soft, max(maximumFilterRoutes / routes - 1, 0))
            routes *= kept + 1
            drawnSolid += soft - kept
            var keptSoFar = 0
            limited.append(layer.map { box in
                guard box.style != .solid else { return box }
                keptSoFar += 1
                return keptSoFar <= kept ? box : Box(area: box.area, style: .solid)
            })
        }
        return Plan(layers: limited, drawnSolid: drawnSolid)
    }

    private static func overlaps(_ a: PixelRect, _ b: PixelRect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }

    /// One split feeds the layer's base picture and a copy for each soft box;
    /// the processed copies are laid back in place one after another, then
    /// the layer's solid boxes are drawn.
    private static func layerFilter(_ boxes: [Box], index: Int, shortEdge: Double) -> String {
        let soft = boxes.filter { $0.style != .solid }
        let drawn = boxes.filter { $0.style == .solid }.map { box in
            "drawbox=x=\(box.area.x):y=\(box.area.y):w=\(box.area.width):h=\(box.area.height):color=black:t=fill"
        }
        guard !soft.isEmpty else { return drawn.joined(separator: ",") }
        let label = "l\(index)"
        let split = "split=\(soft.count + 1)[\(label)b]" + soft.indices.map { "[\(label)p\($0)]" }.joined()
        let patches = soft.enumerated().map { number, box in
            "[\(label)p\(number)]\(patch(box, shortEdge: shortEdge))[\(label)q\(number)]"
        }
        let overlays = soft.enumerated().map { number, box in
            let below = number == 0 ? "\(label)b" : "\(label)o\(number - 1)"
            let output = number == soft.count - 1 ? "" : "[\(label)o\(number)]"
            return "[\(below)][\(label)q\(number)]overlay=\(box.area.x):\(box.area.y)\(output)"
        }
        return ([([split] + patches + overlays).joined(separator: ";")] + drawn).joined(separator: ",")
    }

    /// The area averaged into cells (and, for blur, softened). Pixelated
    /// first, so no detail survives for a deblur to bring back.
    private static func patch(_ box: Box, shortEdge: Double) -> String {
        let area = box.area
        let cell = RedactionRegion.cellSize(areaWidth: Double(area.width), areaHeight: Double(area.height), imageShortEdge: shortEdge)
        let across = max(Int((Double(area.width) / cell).rounded()), 1)
        let down = max(Int((Double(area.height) / cell).rounded()), 1)
        let blur = box.style == .blur ? ",gblur=sigma=\(MediaToolPlans.number(min(cell.rounded(), largestBlurSigma)))" : ""
        // exact=1: without it, crop rounds an odd width down, and a 1-pixel box becomes 0 wide.
        return "crop=\(area.width):\(area.height):\(area.x):\(area.y):exact=1,"
            + "scale=\(across):\(down):flags=area,scale=\(area.width):\(area.height):flags=neighbor\(blur)"
    }

    /// The box in frame pixels, rounded outwards; the corner is on even
    /// pixels, as 4:2:0 video stores colour for pairs of pixels.
    private static func area(_ rect: CropRecipe, width: Int, height: Int) -> PixelRect? {
        func clamp(_ value: Double) -> Double { min(max(value.isNaN ? 0 : value, 0), 1) }
        var left = Int((clamp(rect.x) * Double(width)).rounded(.down))
        var top = Int((clamp(rect.y) * Double(height)).rounded(.down))
        left -= left % 2
        top -= top % 2
        let right = min(Int((clamp(rect.x + rect.width) * Double(width)).rounded(.up)), width)
        let bottom = min(Int((clamp(rect.y + rect.height) * Double(height)).rounded(.up)), height)
        guard right > left, bottom > top else { return nil }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

// MARK: Frame stepping

public enum FrameStepping {
    /// The time `frames` frames away, on a whole number of steps from zero,
    /// so stepping back and forth never drifts (a leftover 1e-17 second is
    /// a time ffmpeg refuses).
    public static func time(after time: Double, frames: Int, frameStep: Double, duration: Double) -> Double {
        guard frameStep > 0, frameStep.isFinite, time.isFinite else { return time.isFinite ? time : 0 }
        let index = (time / frameStep).rounded() + Double(frames)
        return min(max(index * frameStep, 0), max(duration, 0))
    }
}
