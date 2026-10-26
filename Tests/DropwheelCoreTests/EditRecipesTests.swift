import Testing
@testable import DropwheelCore

@Suite("CropRecipe")
struct CropRecipeTests {
    @Test("A normalised rectangle maps to whole pixels")
    func pixels() {
        let recipe = CropRecipe(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        #expect(recipe.pixelRect(imageWidth: 800, imageHeight: 600) == PixelRect(x: 200, y: 300, width: 400, height: 150))
    }

    @Test("Rectangles are clamped inside the picture")
    func clamped() {
        let recipe = CropRecipe(x: 0.9, y: -0.2, width: 0.5, height: 0.5)
        let rect = recipe.pixelRect(imageWidth: 100, imageHeight: 100)
        #expect(rect == PixelRect(x: 90, y: 0, width: 10, height: 50))
    }

    @Test("Video crops use even sizes and positions")
    func evenForVideo() {
        let recipe = CropRecipe(x: 0.1, y: 0.1, width: 0.333, height: 0.333)
        let rect = recipe.pixelRect(imageWidth: 1001, imageHeight: 601, even: true)
        #expect(rect.x % 2 == 0 && rect.y % 2 == 0 && rect.width % 2 == 0 && rect.height % 2 == 0)
    }

    @Test("A crop never collapses below one pixel")
    func minimumSize() {
        let rect = CropRecipe(x: 0.5, y: 0.5, width: 0, height: 0).pixelRect(imageWidth: 10, imageHeight: 10)
        #expect(rect.width >= 1 && rect.height >= 1)
    }

    @Test("The largest rectangle of an aspect ratio is centred in the picture",
          arguments: [(AspectRatio.square, 600, 600), (.widescreen, 800, 450), (.portrait4x5, 480, 600)])
    func largestFit(ratio: AspectRatio, expectedWidth: Int, expectedHeight: Int) {
        let recipe = CropRecipe.largest(ratio, imageWidth: 800, imageHeight: 600)
        let rect = recipe.pixelRect(imageWidth: 800, imageHeight: 600)
        #expect(rect.width == expectedWidth && rect.height == expectedHeight)
        #expect(rect.x == (800 - expectedWidth) / 2 && rect.y == (600 - expectedHeight) / 2)
    }

    @Test("Free and original ratios keep the whole picture")
    func freeAndOriginal() {
        #expect(CropRecipe.largest(.free, imageWidth: 800, imageHeight: 600) == .whole)
        #expect(CropRecipe.largest(.original, imageWidth: 800, imageHeight: 600) == .whole)
    }
}

@Suite("TrimRange")
struct TrimRangeTests {
    @Test("A range inside the media is valid")
    func valid() {
        #expect(TrimRange(start: 1, end: 3).isValid(durationSeconds: 10))
        #expect(TrimRange(start: 1, end: 3).length == 2)
    }

    @Test("Ranges that are empty, reversed or outside the media are not", arguments: [
        TrimRange(start: 3, end: 3), TrimRange(start: 4, end: 2), TrimRange(start: -1, end: 2), TrimRange(start: 1, end: 11),
    ])
    func invalid(range: TrimRange) {
        #expect(!range.isValid(durationSeconds: 10))
    }

    @Test("Keeping everything is not a trim")
    func wholeIsNotATrim() {
        #expect(TrimRange(start: 0, end: 10).coversWhole(durationSeconds: 10))
        #expect(!TrimRange(start: 0.5, end: 10).coversWhole(durationSeconds: 10))
    }

    @Test("Timecodes read and write as h:mm:ss.mmm")
    func timecodes() {
        #expect(Timecode.string(from: 3723.4) == "1:02:03.400")
        #expect(Timecode.string(from: 5.25) == "0:05.250")
        #expect(Timecode.seconds(from: "1:02:03.4") == 3723.4)
        #expect(Timecode.seconds(from: "05.25") == 5.25)
        #expect(Timecode.seconds(from: "abc") == nil)
    }

    @Test("Overflowing, non-decimal and out-of-range timecodes are refused",
          arguments: ["9223372036854775807:00", "inf", "0x10", "1e3", "+5", "-0:05", "1:60", "1:60:00", "99999999"])
    func badTimecodes(text: String) {
        #expect(Timecode.seconds(from: text) == nil)
    }

    @Test("Non-finite times format safely")
    func nonFiniteFormatting() {
        #expect(Timecode.string(from: .infinity) == "0:00.000")
        #expect(Timecode.string(from: .nan) == "0:00.000")
    }
}

@Suite("EditPlans")
struct EditPlansTests {
    @Test("Video crop keeps the sound untouched")
    func cropVideo() {
        let options = EditPlans.cropVideoOptions(PixelRect(x: 10, y: 20, width: 640, height: 360), format: .mp4)
        #expect(options.contains("crop=640:360:10:20"))
        #expect(options.contains("copy"))
    }

    @Test("Trim seeks before the input and limits the length")
    func trim() {
        let arguments = EditPlans.trimArguments(input: "/in.mov", output: "/out.mov", range: TrimRange(start: 1.5, end: 4), format: .mov)
        #expect(arguments.starts(with: ["-hide_banner", "-nostdin", "-n", "-ss", "1.5", "-i", "/in.mov"]))
        #expect(arguments.contains("-t") && arguments.contains("2.5"))
    }

    @Test("Silence trimming works from both ends")
    func silence() {
        let filter = EditPlans.trimSilenceFilter
        #expect(filter.contains("silenceremove=start_periods=1"))
        #expect(filter.contains("areverse"))
    }
}

@Suite("Waveform")
struct WaveformTests {
    @Test("Samples reduce to one peak per bucket")
    func peaks() {
        let samples: [Float] = [0.1, -0.5, 0.2, 0.9, -0.3, 0.0]
        #expect(Waveform.peaks(of: samples, buckets: 3) == [0.5, 0.9, 0.3])
    }

    @Test("More buckets than samples gives one peak per sample")
    func fewSamples() {
        #expect(Waveform.peaks(of: [0.2, -0.4], buckets: 5) == [0.2, 0.4])
    }

    @Test("Silence or no samples gives zeros or nothing")
    func empty() {
        #expect(Waveform.peaks(of: [], buckets: 4).isEmpty)
        #expect(Waveform.peaks(of: [0, 0, 0, 0], buckets: 2) == [0, 0])
    }
}
