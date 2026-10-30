import Foundation
import Testing
@testable import DropwheelCore

@Suite("CollageRecipe")
struct CollageRecipeTests {
    private func recipe(columns: Int? = nil, aspect: AspectRatio = .free, spacing: Double = 0) -> CollageRecipe {
        CollageRecipe(columns: columns, aspect: aspect, longEdge: 2400, spacing: spacing, cornerRadius: 0, background: .white)
    }

    @Test("Four photos make a square two-by-two grid")
    func fourPhotos() {
        let layout = recipe().layout(count: 4)
        #expect(layout.canvasWidth == 2400 && layout.canvasHeight == 2400)
        #expect(layout.cells == [
            PixelRect(x: 0, y: 0, width: 1200, height: 1200), PixelRect(x: 1200, y: 0, width: 1200, height: 1200),
            PixelRect(x: 0, y: 1200, width: 1200, height: 1200), PixelRect(x: 1200, y: 1200, width: 1200, height: 1200),
        ])
    }

    @Test("A short last row is centred")
    func shortLastRow() {
        let layout = recipe().layout(count: 3)
        #expect(layout.cells.count == 3)
        #expect(layout.cells[2] == PixelRect(x: 600, y: 1200, width: 1200, height: 1200))
    }

    @Test("Spacing surrounds and separates the photos")
    func spacing() {
        let layout = recipe(columns: 2, spacing: 0.1).layout(count: 2)
        #expect(layout.canvasWidth == 2400 && layout.canvasHeight == 1200)
        #expect(layout.cells[0] == PixelRect(x: 120, y: 120, width: 1020, height: 960))
        #expect(layout.cells[1] == PixelRect(x: 1260, y: 120, width: 1020, height: 960))
    }

    @Test("A chosen shape sets the canvas; columns never exceed the photo count")
    func shapeAndColumns() {
        let tall = recipe(columns: 9, aspect: .portrait9x16).layout(count: 3)
        #expect(tall.canvasHeight == 2400 && tall.canvasWidth == 1350)
        #expect(recipe(columns: 9).grid(count: 3) == GridSize(columns: 3, rows: 1))
        #expect(recipe().grid(count: 5) == GridSize(columns: 3, rows: 2))
    }

    @Test("Spacing never squeezes cells to nothing or pushes them off the canvas", arguments: [11, 36])
    func spacingLimit(count: Int) {
        let recipe = CollageRecipe(columns: 1, aspect: .square, longEdge: 2400, spacing: 0.1, cornerRadius: 0, background: .white)
        let layout = recipe.layout(count: count)
        for cell in layout.cells {
            #expect(cell.width > 20 && cell.height > 20)
            #expect(cell.x + cell.width <= layout.canvasWidth && cell.y + cell.height <= layout.canvasHeight)
        }
    }

    @Test("Corner radius is a share of a cell's short edge")
    func corners() {
        var rounded = recipe()
        rounded.cornerRadius = 0.1
        #expect(rounded.cornerRadiusPixels(cell: PixelRect(x: 0, y: 0, width: 400, height: 300)) == 30)
    }
}

@Suite("FrameExport")
struct FrameExportTests {
    @Test("A single frame must lie inside the video")
    func single() {
        #expect(FrameExport(plan: .single(seconds: 3), format: .png).isValid(durationSeconds: 10))
        #expect(!FrameExport(plan: .single(seconds: 12), format: .png).isValid(durationSeconds: 10))
        #expect(FrameExport(plan: .single(seconds: 3), format: .png).frameCount(durationSeconds: 10) == 1)
    }

    @Test("Frames every few seconds need at least two and at most the limit")
    func every() {
        let everyTwo = FrameExport(plan: .every(seconds: 2), format: .jpg)
        #expect(everyTwo.frameCount(durationSeconds: 10) == 5)
        #expect(everyTwo.isValid(durationSeconds: 10))
        #expect(!everyTwo.isValid(durationSeconds: 1.5))
        #expect(!FrameExport(plan: .every(seconds: 0.01), format: .jpg).isValid(durationSeconds: 10))
        #expect(!FrameExport(plan: .every(seconds: 0.1), format: .jpg).isValid(durationSeconds: 3600))
    }

    @Test("Absurd intervals and times are refused without overflowing")
    func extremes() {
        let tiny = FrameExport(plan: .every(seconds: 1e-19), format: .png)
        #expect(tiny.frameCount(durationSeconds: 10) > FrameExport.maximumFrames)
        #expect(!tiny.isValid(durationSeconds: 10))
        #expect(!FrameExport(plan: .single(seconds: .infinity), format: .png).suffix.isEmpty)
        #expect(!FrameExport(plan: .single(seconds: .nan), format: .png).isValid(durationSeconds: 10))
    }

    @Test("Names say which frame was saved")
    func names() {
        #expect(FrameExport(plan: .single(seconds: 12.346), format: .png).suffix == "frame at 12.35s")
        #expect(FrameExport(plan: .single(seconds: 4), format: .png).suffix == "frame at 4s")
        #expect(FrameExport(plan: .every(seconds: 2), format: .jpg).suffix == "frames")
    }

    @Test("Frame files are numbered, with percent signs anywhere in the path escaped")
    func arguments() {
        let arguments = EditPlans.everyFrameArguments(input: "/in.mov", folder: "/Holiday 50% off/out", stem: "100% clip",
                                                      export: FrameExport(plan: .every(seconds: 2.5), format: .jpg))
        #expect(arguments.last == "/Holiday 50%% off/out/100%% clip %04d.jpg")
        #expect(arguments.contains("-q:v"))
    }

    @Test("A frame a minute is an exact rate, so later frames don't drift")
    func exactInterval() {
        let arguments = EditPlans.everyFrameArguments(input: "/in.mov", folder: "/out", stem: "clip",
                                                      export: FrameExport(plan: .every(seconds: 60), format: .png))
        #expect(arguments.contains { $0.hasPrefix("fps=1/60,") })
    }

    @Test("Frames come from the real picture track, with square pixels")
    func squarePixels() {
        let arguments = EditPlans.everyFrameArguments(input: "/in.mov", folder: "/out", stem: "clip",
                                                      export: FrameExport(plan: .every(seconds: 2.5), format: .png))
        #expect(arguments.contains("fps=1/2.5,scale=iw*sar:ih,setsar=1"))
        #expect(arguments.contains("0:V:0"))
    }
}

@Suite("VideoRedaction")
struct VideoRedactionTests {
    private func region(_ style: RedactionStyle) -> RedactionRegion {
        RedactionRegion(rect: CropRecipe(x: 0.1, y: 0.2, width: 0.25, height: 0.25), style: style)
    }

    @Test("Solid boxes are drawn filled, rounded outwards")
    func solid() {
        let filter = VideoRedaction.filter([region(.solid)], width: 1001, height: 600)
        #expect(filter == "drawbox=x=100:y=120:w=251:h=150:color=black:t=fill")
    }

    @Test("A box starting on an odd pixel moves out to the even one before it")
    func oddLeftEdge() {
        let box = RedactionRegion(rect: CropRecipe(x: 0.125, y: 0.25, width: 0.25, height: 0.25))
        #expect(VideoRedaction.filter([box], width: 1000, height: 600) == "drawbox=x=124:y=150:w=251:h=150:color=black:t=fill")
    }

    @Test("A box over an earlier one is cut from the result so far, one layer up")
    func overlapLayers() {
        let filter = VideoRedaction.filter([region(.pixelate), region(.blur)], width: 1000, height: 600)
        #expect(filter == "split=2[l0b][l0p0];[l0p0]crop=250:150:100:120:exact=1,scale=3:2:flags=area,"
            + "scale=250:150:flags=neighbor[l0q0];[l0b][l0q0]overlay=100:120"
            + ",split=2[l1b][l1p0];[l1p0]crop=250:150:100:120:exact=1,scale=3:2:flags=area,"
            + "scale=250:150:flags=neighbor,gblur=sigma=75[l1q0];[l1b][l1q0]overlay=100:120")
    }

    @Test("Boxes that don't overlap share one split, however many there are")
    func oneLayer() throws {
        let boxes = (0..<30).map { index in
            RedactionRegion(rect: CropRecipe(x: Double(index % 6) / 6, y: Double(index / 6) / 5, width: 0.1, height: 0.1),
                            style: index.isMultiple(of: 5) ? .solid : .pixelate)
        }
        let filter = try #require(VideoRedaction.filter(boxes, width: 1920, height: 1080))
        #expect(filter.components(separatedBy: "split=").count == 2)
        #expect(filter.hasPrefix("split=25[l0b]"))
        #expect(filter.components(separatedBy: "overlay=").count == 25)
        #expect(filter.components(separatedBy: "drawbox=").count == 7)
    }

    /// Five columns of eight boxes, each box overlapping the one below it:
    /// eight layers of five soft boxes, 6^8 routes through the filter if none were capped.
    private var stackedColumns: [RedactionRegion] {
        (0..<8).flatMap { layer in
            (0..<5).map { column in
                RedactionRegion(rect: CropRecipe(x: Double(column) * 0.2 + Double(layer) * 0.005, y: 0.1 + Double(layer) * 0.005,
                                                 width: 0.15, height: 0.3), style: .pixelate)
            }
        }
    }

    @Test("Soft boxes that would multiply ffmpeg's work past the limit are drawn solid")
    func routeLimit() throws {
        let boxes = stackedColumns
        let filter = try #require(VideoRedaction.filter(boxes, width: 1000, height: 1000))
        let splits = filter.components(separatedBy: "split=").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
        #expect(splits.reduce(1, *) <= VideoRedaction.maximumFilterRoutes)
        let overlays = filter.components(separatedBy: "overlay=").count - 1
        let solid = filter.components(separatedBy: "drawbox=").count - 1
        #expect(overlays + solid == boxes.count)
        #expect(solid > 0 && solid == VideoRedaction.solidFallbackCount(boxes, width: 1000, height: 1000))
        // The first layers keep every soft box.
        #expect(splits.first == 6)
    }

    @Test("A single stack of a dozen soft boxes stays soft")
    func narrowStack() throws {
        let stack = (0..<12).map { index in
            RedactionRegion(rect: CropRecipe(x: 0.1 + Double(index) * 0.01, y: 0.1, width: 0.3, height: 0.3), style: .blur)
        }
        let filter = try #require(VideoRedaction.filter(stack, width: 1000, height: 1000))
        #expect(filter.components(separatedBy: "split=").count - 1 == 12)
        #expect(!filter.contains("drawbox="))
    }

    @Test("Boxes with no area aren't counted as drawn solid")
    func fallbackIgnoresEmptyBoxes() {
        let flat = RedactionRegion(rect: CropRecipe(x: 0.2, y: 1, width: 0.5, height: 0), style: .blur)
        #expect(VideoRedaction.solidFallbackCount([flat], width: 320, height: 240) == 0)
    }

    @Test("Thin boxes are cut exactly, and a huge blur stays within ffmpeg's limit")
    func thinAndHuge() throws {
        let thin = RedactionRegion(rect: CropRecipe(x: 0.5, y: 0, width: 0.0005, height: 1), style: .pixelate)
        #expect(try #require(VideoRedaction.filter([thin], width: 1920, height: 1080)).contains("crop=1:1080:960:0:exact=1"))
        let whole = RedactionRegion(rect: .whole, style: .blur)
        #expect(try #require(VideoRedaction.filter([whole], width: 7680, height: 4320)).contains("gblur=sigma=1024["))
    }

    @Test("No boxes, or only boxes with no area, give no filter")
    func empty() {
        #expect(VideoRedaction.filter([], width: 100, height: 100) == nil)
        let flat = RedactionRegion(rect: CropRecipe(x: 0.2, y: 1, width: 0.5, height: 0))
        #expect(VideoRedaction.filter([flat], width: 320, height: 240) == nil)
    }

    @Test("Options keep the picture and every audio track, drop stream tags, and keep the even-size rule")
    func options() {
        let options = VideoRedaction.options([region(.solid)], width: 1000, height: 600, format: .mp4)
        #expect(options.starts(with: ["-map", "0:V:0", "-map", "0:a?"]))
        let filter = options[options.firstIndex(of: "-vf")! + 1]
        #expect(filter.hasPrefix("drawbox=") && filter.hasSuffix(",scale=trunc(iw/2)*2:trunc(ih/2)*2"))
        #expect(options.contains("-map_metadata:s:v") && options.contains("-map_metadata:s:a"))
        #expect(Array(options.suffix(2)) == ["-c:a", "copy"])
    }

    @Test("Cells are half an area's shorter side, with a floor that grows with the picture")
    func cellSize() {
        #expect(RedactionRegion.cellSize(areaWidth: 300, areaHeight: 30, imageShortEdge: 1000) == 15)
        #expect(RedactionRegion.cellSize(areaWidth: 6, areaHeight: 3, imageShortEdge: 1000) == 10)
    }
}

@Suite("FrameStepping")
struct FrameSteppingTests {
    @Test("Stepping forward and back by the same count lands exactly on the start",
          arguments: [24.0, 23.976, 25, 29.97, 30, 59.94, 60])
    func roundTrip(rate: Double) {
        let step = 1 / rate
        for count in 1...400 {
            let forward = (0..<count).reduce(0.0) { time, _ in FrameStepping.time(after: time, frames: 1, frameStep: step, duration: 1000) }
            let back = (0..<count).reduce(forward) { time, _ in FrameStepping.time(after: time, frames: -1, frameStep: step, duration: 1000) }
            #expect(back == 0)
        }
    }

    @Test("Steps stay inside the video")
    func bounds() {
        #expect(FrameStepping.time(after: 0, frames: -1, frameStep: 0.04, duration: 10) == 0)
        #expect(FrameStepping.time(after: 10, frames: 1, frameStep: 0.04, duration: 10) == 10)
        #expect(FrameStepping.time(after: 1, frames: 1, frameStep: 0, duration: 10) == 1)
    }
}

@Suite("Numbers in ffmpeg arguments")
struct NumberFormattingTests {
    @Test("Plain decimals to the microsecond, never exponent notation")
    func plain() {
        #expect(MediaToolPlans.number(2) == "2")
        #expect(MediaToolPlans.number(0.4) == "0.4")
        #expect(MediaToolPlans.number(12.35) == "12.35")
        #expect(MediaToolPlans.number(1.0 / 3) == "0.333333")
        #expect(MediaToolPlans.number(1.3877787807814457e-17) == "0")
        #expect(MediaToolPlans.number(-1e-12) == "0")
        #expect(!MediaToolPlans.number(1e20).contains("e"))
        #expect(MediaToolPlans.number(.nan) == "0" && MediaToolPlans.number(.infinity) == "0")
    }

    @Test("Frame rates keep every digit, so ffmpeg recovers exact rates such as 30000/1001")
    func rates() {
        let ntsc = 30000.0 / 1001
        #expect(MediaToolPlans.rate(ntsc) == "\(ntsc)")
        #expect(MediaToolPlans.rate(25) == "25")
        #expect(!MediaToolPlans.rate(1e-9).contains("e"))
        let arguments = MediaToolPlans.joinArguments(clips: [JoinClip(path: "/a.mp4", hasAudio: true, durationSeconds: 1)],
                                                     width: 640, height: 360, framesPerSecond: ntsc, output: "/o.mp4")
        #expect(arguments.contains { $0.contains("fps=\(ntsc)") })
    }
}

@Suite("5c tools")
struct MediaEditToolTests {
    @Test("Several photos offer a collage; videos offer frames and redaction")
    func catalog() {
        #expect(ToolCatalog.tools(for: [.input(.jpg), .input(.png)]).contains(.collage))
        #expect(!ToolCatalog.tools(for: [.input(.jpg)]).contains(.collage))
        let tooMany = Array(repeating: SelectionItem.input(.jpg), count: CollageRecipe.maximumImages + 1)
        #expect(!ToolCatalog.tools(for: tooMany).contains(.collage))
        let video = ToolCatalog.tools(for: [.input(.mp4)])
        #expect(video.contains(.saveFrames) && video.contains(.redactVideo))
        #expect(ToolKind.collage.usesWholeSelection && ToolKind.collage.opensEditor)
        #expect(ToolKind.saveFrames.opensEditor && ToolKind.redactVideo.opensEditor)
    }
}
