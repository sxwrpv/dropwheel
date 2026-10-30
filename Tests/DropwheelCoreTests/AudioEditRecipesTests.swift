import Foundation
import Testing
@testable import DropwheelCore

@Suite("BleepPlans")
struct BleepPlansTests {
    private func range(_ start: Double, _ end: Double) -> TrimRange {
        TrimRange(start: start, end: end)
    }

    @Test("Ranges come out in order, with overlapping and touching ones merged")
    func merged() {
        #expect(BleepPlans.merged([range(5, 6), range(2, 3), range(1, 2.5)]) == [range(1, 3), range(5, 6)])
        #expect(BleepPlans.merged([range(1, 2), range(2, 3)]) == [range(1, 3)])
        #expect(BleepPlans.merged([range(1, 2), range(2.0005, 3)]) == [range(1, 3)])
        #expect(BleepPlans.merged([range(1, 2), range(3, 4)]) == [range(1, 2), range(3, 4)])
    }

    @Test("Ranges with no length are dropped, and nothing starts before the recording")
    func cleaned() {
        #expect(BleepPlans.merged([range(-1, 1)]) == [range(0, 1)])
        #expect(BleepPlans.merged([range(-2, -1), range(3, 3), range(4, 2), range(.nan, 1), range(1, .infinity)]).isEmpty)
    }

    @Test("One range cuts the sound in three and replaces the middle with a tone")
    func toneFilter() {
        let filter = BleepPlans.filter(BleepRecipe(ranges: [range(1, 2)], sound: .tone))
        #expect(filter == "[0:a:0]asetpts=round(N/SR/TB),asegment=timestamps=1|2[s0][s1][s2]"
            + ";[s0]asetpts=PTS-STARTPTS[k0]"
            + ";[s1]asetpts=PTS-STARTPTS,aeval=0.25*sin(2*PI*1000*t):c=same[k1]"
            + ";[s2]asetpts=PTS-STARTPTS[k2]"
            + ";[k0][k1][k2]concat=n=3:v=0:a=1[bleeped]")
    }

    @Test("Silence mutes the range instead of playing a tone")
    func silenceFilter() throws {
        let filter = try #require(BleepPlans.filter(BleepRecipe(ranges: [range(1.5, 2.25)], sound: .silence)))
        #expect(filter.contains("timestamps=1.5|2.25"))
        #expect(filter.contains("[s1]asetpts=PTS-STARTPTS,volume=0[k1]"))
        #expect(!filter.contains("aeval"))
    }

    @Test("A range from the very start has no piece before it")
    func fromTheStart() {
        let filter = BleepPlans.filter(BleepRecipe(ranges: [range(0, 1)], sound: .silence))
        #expect(filter == "[0:a:0]asetpts=round(N/SR/TB),asegment=timestamps=1[s0][s1]"
            + ";[s0]asetpts=PTS-STARTPTS,volume=0[k0]"
            + ";[s1]asetpts=PTS-STARTPTS[k1]"
            + ";[k0][k1]concat=n=2:v=0:a=1[bleeped]")
    }

    @Test("Several ranges alternate kept and replaced pieces")
    func severalRanges() throws {
        let filter = try #require(BleepPlans.filter(BleepRecipe(ranges: [range(3, 4), range(1, 2)], sound: .tone)))
        #expect(filter.contains("timestamps=1|2|3|4[s0][s1][s2][s3][s4]"))
        #expect(filter.components(separatedBy: "aeval=").count - 1 == 2)
        #expect(filter.contains("[s1]asetpts=PTS-STARTPTS,aeval") && filter.contains("[s3]asetpts=PTS-STARTPTS,aeval"))
        #expect(filter.hasSuffix("[k0][k1][k2][k3][k4]concat=n=5:v=0:a=1[bleeped]"))
    }

    @Test("Nothing to bleep, no filter")
    func nothing() {
        #expect(BleepPlans.filter(BleepRecipe(ranges: [], sound: .tone)) == nil)
        #expect(BleepPlans.options(BleepRecipe(ranges: [range(4, 2)], sound: .tone), format: .wav) == nil)
    }

    @Test("Saving keeps the file's own audio format")
    func options() throws {
        let options = try #require(BleepPlans.options(BleepRecipe(ranges: [range(1, 2)], sound: .tone), format: .mp3))
        #expect(options.starts(with: ["-filter_complex"]))
        #expect(options.contains("[bleeped]") && options.contains("libmp3lame"))
        #expect(options.contains("-map_metadata:s:a"))
    }

    @Test("Listening copies are plain WAV, bleeped or not")
    func listeningOptions() {
        let original = BleepPlans.listeningOptions(nil)
        #expect(original.contains("0:a:0") && original.contains("pcm_s16le"))
        let bleeped = BleepPlans.listeningOptions(BleepRecipe(ranges: [range(1, 2)], sound: .tone))
        #expect(bleeped.contains("[bleeped]") && bleeped.contains("pcm_s16le"))
        // Plain WAV stops at 4 GiB, which a long recording can reach.
        #expect(original.contains("-rf64") && bleeped.contains("-rf64"))
    }
}

@Suite("VisualizerPlans")
struct VisualizerPlansTests {
    private var recipe: VisualizerRecipe {
        VisualizerRecipe(content: .waveform, shape: .landscape, waveColor: RGBA(red: 1, green: 0.54, blue: 0.24),
                         background: .black, picture: nil)
    }

    private func graph(_ arguments: [String]) -> String {
        arguments[(arguments.firstIndex(of: "-filter_complex") ?? 0) + 1]
    }

    @Test("Each shape has its own canvas")
    func shapes() {
        #expect(VisualizerShape.landscape.width == 1920 && VisualizerShape.landscape.height == 1080)
        #expect(VisualizerShape.portrait.width == 1080 && VisualizerShape.portrait.height == 1920)
        #expect(VisualizerShape.square.width == 1080 && VisualizerShape.square.height == 1080)
    }

    @Test("A waveform is drawn in its colour across the middle of the canvas")
    func waveform() {
        let arguments = VisualizerPlans.arguments(canvas: "/c.png", audio: "/in.mp3", output: "/o.mp4", recipe: recipe, seconds: 60)
        #expect(graph(arguments) == "[1:a:0]aformat=channel_layouts=mono,aresample=57600,showwaves=s=1920x400:mode=cline:scale=sqrt"
            + ":rate=30:colors=0xFF8A3D:draw=full[wave];[0:v][wave]overlay=x=0:y=340:shortest=1,format=yuv420p[video]")
        #expect(arguments.starts(with: ["-hide_banner", "-nostdin", "-n", "-loop", "1", "-framerate", "30", "-t", "61",
                                        "-i", "/c.png", "-i", "/in.mp3"]))
        #expect(arguments.contains("[video]") && arguments.contains("1:a:0") && arguments.contains("-shortest"))
        #expect(arguments.contains("libx264") && arguments.contains("aac") && arguments.last == "/o.mp4")
        // Shareable: stereo at a standard rate, whatever the recording is.
        #expect(arguments.contains("-ac") && arguments.contains("48000"))
        #expect(arguments.contains("-map_metadata:s:a"))
    }

    @Test("Over a picture the waveform sits near the bottom")
    func waveformOverPicture() {
        var withPicture = recipe
        withPicture.picture = URL(fileURLWithPath: "/cover.png")
        let arguments = VisualizerPlans.arguments(canvas: "/c.png", audio: "/in.mp3", output: "/o.mp4", recipe: withPicture, seconds: 60)
        #expect(graph(arguments).contains("overlay=x=0:y=626:"))
        withPicture.shape = .portrait
        let tall = VisualizerPlans.arguments(canvas: "/c.png", audio: "/in.mp3", output: "/o.mp4", recipe: withPicture, seconds: 60)
        #expect(graph(tall).contains("aresample=32400,showwaves=s=1080x400") && graph(tall).contains("overlay=x=0:y=1424:"))
    }

    @Test("A still image is the canvas held for the length of the audio")
    func stillImage() {
        var still = recipe
        still.content = .stillImage
        let arguments = VisualizerPlans.arguments(canvas: "/c.png", audio: "/in.wav", output: "/o.mp4", recipe: still, seconds: 60)
        #expect(!arguments.contains("-filter_complex"))
        #expect(arguments.contains("0:v") && arguments.contains("1:a:0"))
        #expect(arguments.contains("stillimage") && arguments.contains("-shortest") && arguments.contains("yuv420p"))
    }

    @Test("A preview draws a moment of the audio with the same filter")
    func preview() {
        let arguments = VisualizerPlans.previewArguments(canvas: "/c.png", audio: "/in.mp3", output: "/p.png", recipe: recipe, seconds: 12.5)
        #expect(graph(arguments) == graph(VisualizerPlans.arguments(canvas: "/c.png", audio: "/in.mp3", output: "/o.mp4", recipe: recipe, seconds: 60)))
        let seek = arguments.firstIndex(of: "-ss") ?? 0
        // The run's last frame is the one kept, so the run starts a little earlier.
        #expect(abs((Double(arguments[seek + 1]) ?? 0) - 12.333333) < 0.001 && seek > (arguments.firstIndex(of: "/c.png") ?? 0))
        #expect(arguments.contains("-update") && arguments.last == "/p.png")
        // The looping canvas always has an end, or ffmpeg would run forever where there is no sound.
        #expect(arguments.starts(with: ["-hide_banner", "-nostdin", "-n", "-loop", "1", "-framerate", "30", "-t", "0.2", "-i", "/c.png"]))
        // More sound than picture, so the last frame's waveform is complete.
        #expect(arguments[seek + 2] == "-t" && (Double(arguments[seek + 3]) ?? 0) > 0.2)
    }

    @Test("A still image needs a picture")
    func completeness() {
        #expect(recipe.isComplete)
        var still = recipe
        still.content = .stillImage
        #expect(!still.isComplete)
        still.picture = URL(fileURLWithPath: "/cover.png")
        #expect(still.isComplete)
    }

    @Test("Colours become ffmpeg hex values, rounded and kept in range")
    func hex() {
        #expect(VisualizerPlans.hex(RGBA(red: 0, green: 0.5, blue: 1)) == "0x0080FF")
        #expect(VisualizerPlans.hex(RGBA(red: 2, green: -1, blue: .nan)) == "0xFF0000")
    }
}

@Suite("BleepDrag")
struct BleepDragTests {
    private let id = UUID()
    private let duration = 100.0
    private var mark: BleepMark { BleepMark(id: id, start: 10, end: 20) }

    private func starting(at time: Double, marks: [BleepMark]? = nil, selection: UUID? = nil) -> BleepDrag {
        BleepDrag.starting(at: time, marks: marks ?? [mark], selection: selection, edgeReach: 0.5)
    }

    @Test("A press takes hold of an edge, a whole mark, or bare waveform")
    func whatAPressHolds() {
        #expect(starting(at: 5) == .pressing(at: 5))
        #expect(starting(at: 15) == .moving(mark, grabbedAt: 15))
        #expect(starting(at: 10.3) == .resizing(mark, edge: .start, grabbedAt: 10.3))
        #expect(starting(at: 19.7) == .resizing(mark, edge: .end, grabbedAt: 19.7))
        #expect(starting(at: 20.4) == .resizing(mark, edge: .end, grabbedAt: 20.4))
    }

    @Test("A mark too narrow on screen to have separate edges moves as a whole")
    func narrowMark() {
        let narrow = BleepMark(id: id, start: 10, end: 11)
        #expect(starting(at: 10.1, marks: [narrow]) == .moving(narrow, grabbedAt: 10.1))
        #expect(starting(at: 11.3, marks: [narrow]) == .moving(narrow, grabbedAt: 11.3))
    }

    @Test("Where marks overlap, the selected one comes first, then the newest")
    func overlapping() {
        let later = BleepMark(id: UUID(), start: 12, end: 18)
        #expect(starting(at: 15, marks: [mark, later]) == .moving(later, grabbedAt: 15))
        #expect(starting(at: 15, marks: [mark, later], selection: id) == .moving(mark, grabbedAt: 15))
    }

    @Test("Holding an edge without moving changes nothing")
    func pressAloneChangesNothing() {
        let drag = starting(at: 19.7)
        #expect(drag.applied(to: [mark], at: 19.7, duration: duration) == [mark])
    }

    @Test("An edge follows the pointer from where it was grabbed, without jumping to it")
    func edgeKeepsItsOffset() {
        let moved = starting(at: 19.7).applied(to: [mark], at: 20.7, duration: duration)
        #expect(moved == [BleepMark(id: id, start: 10, end: 21)])
        let earlier = starting(at: 10.3).applied(to: [mark], at: 9.3, duration: duration)
        #expect(earlier == [BleepMark(id: id, start: 9, end: 20)])
    }

    @Test("An edge stops short of the other edge and the ends of the recording")
    func edgeLimits() {
        let shortest = TrimRange.minimumLength
        #expect(starting(at: 20).applied(to: [mark], at: 2, duration: duration) == [BleepMark(id: id, start: 10, end: 10 + shortest)])
        #expect(starting(at: 10).applied(to: [mark], at: 50, duration: duration) == [BleepMark(id: id, start: 20 - shortest, end: 20)])
        #expect(starting(at: 20).applied(to: [mark], at: 500, duration: duration) == [BleepMark(id: id, start: 10, end: 100)])
        #expect(starting(at: 10).applied(to: [mark], at: -50, duration: duration) == [BleepMark(id: id, start: 0, end: 20)])
    }

    @Test("A moved mark keeps its length and stays inside the recording")
    func moving() {
        #expect(starting(at: 15).applied(to: [mark], at: 18, duration: duration) == [BleepMark(id: id, start: 13, end: 23)])
        #expect(starting(at: 15).applied(to: [mark], at: 500, duration: duration) == [BleepMark(id: id, start: 90, end: 100)])
        #expect(starting(at: 15).applied(to: [mark], at: -500, duration: duration) == [BleepMark(id: id, start: 0, end: 10)])
    }

    @Test("Drawing makes a mark in either direction from where it began")
    func drawing() {
        let newID = UUID()
        let drag = BleepDrag.drawing(id: newID, from: 40)
        #expect(drag.applied(to: [mark], at: 45, duration: duration) == [mark, BleepMark(id: newID, start: 40, end: 45)])
        let backwards = drag.applied(to: [mark, BleepMark(id: newID, start: 40, end: 45)], at: 30, duration: duration)
        #expect(backwards == [mark, BleepMark(id: newID, start: 30, end: 40)])
    }

    @Test("Only a mark drawn too short to hear is dropped at the end of a drag")
    func finishing() {
        let newID = UUID()
        let tiny = BleepMark(id: newID, start: 40, end: 40.01)
        #expect(BleepDrag.drawing(id: newID, from: 40).finished(with: [mark, tiny]) == [mark])
        let wide = BleepMark(id: newID, start: 40, end: 41)
        #expect(BleepDrag.drawing(id: newID, from: 40).finished(with: [mark, wide]) == [mark, wide])
        // An existing mark stays, whatever its length.
        let short = BleepMark(id: id, start: 10, end: 10.01)
        #expect(BleepDrag.resizing(short, edge: .end, grabbedAt: 10).finished(with: [short]) == [short])
    }

    @Test("Typed times stay inside the recording and keep the shortest length")
    func typedTimes() {
        let shortest = TrimRange.minimumLength
        #expect(mark.with(start: 12, end: 18, duration: duration) == BleepMark(id: id, start: 12, end: 18))
        #expect(mark.with(start: -5, end: 500, duration: duration) == BleepMark(id: id, start: 0, end: 100))
        #expect(mark.with(start: 30, end: 20, duration: duration) == BleepMark(id: id, start: 20 - shortest, end: 20))
    }
}

@Suite("Waveform peaks")
struct WaveformPeaksTests {
    @Test("Peaks work on part of a longer buffer, not only on a whole array")
    func slice() {
        let samples: [Float] = [9, 9, 0.1, -0.5, 0.2, -0.4, 9, 9]
        #expect(Waveform.peaks(of: samples[2..<6], buckets: 2) == [0.5, 0.4])
    }
}

@Suite("WaveformWindow")
struct WaveformWindowTests {
    @Test("A view stays inside the recording")
    func around() {
        #expect(WaveformWindow.around(5, length: 2, duration: 10) == WaveformWindow(start: 4, length: 2))
        #expect(WaveformWindow.around(0.5, length: 2, duration: 10) == WaveformWindow(start: 0, length: 2))
        #expect(WaveformWindow.around(9.5, length: 2, duration: 10) == WaveformWindow(start: 8, length: 2))
        #expect(WaveformWindow.around(5, length: 20, duration: 10).start == 0)
    }

    @Test("Zoom runs from all of the recording to the closest view, by equal steps")
    func zoom() {
        #expect(WaveformWindow.length(zoom: 0, duration: 800, closest: 2) == 800)
        #expect(abs(WaveformWindow.length(zoom: 1, duration: 800, closest: 2) - 2) < 1e-9)
        #expect(abs(WaveformWindow.length(zoom: 0.5, duration: 800, closest: 2) - 40) < 1e-9)
    }

    @Test("A recording shorter than the closest view just shows all of it")
    func shortRecording() {
        #expect(WaveformWindow.length(zoom: 1, duration: 1, closest: 2) == 1)
    }

    @Test("The end is the start plus the length")
    func end() {
        #expect(WaveformWindow(start: 3, length: 4).end == 7)
    }
}

@Suite("5d tools")
struct AudioEditToolTests {
    @Test("Audio offers Bleep and the visualizer, each with its own window")
    func catalog() {
        let audio = ToolCatalog.tools(for: [.input(.wav)])
        #expect(audio.contains(.bleep) && audio.contains(.visualizer))
        #expect(ToolKind.bleep.opensEditor && ToolKind.visualizer.opensEditor)
        #expect(!ToolCatalog.tools(for: [.input(.mp4)]).contains(.bleep))
        #expect(!ToolCatalog.tools(for: [.input(.mp4)]).contains(.visualizer))
        #expect(!ToolKind.bleep.usesWholeSelection && !ToolKind.visualizer.usesWholeSelection)
    }
}
