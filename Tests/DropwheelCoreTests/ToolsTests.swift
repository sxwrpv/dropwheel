import Foundation
import Testing
@testable import DropwheelCore

@Suite("ToolCatalog")
struct ToolCatalogTests {
    @Test("A photo offers Compress and Remove Metadata")
    func singleImage() {
        #expect(ToolCatalog.tools(for: [.input(.jpg)]) == [.compress, .removeMetadata, .crop, .editPhoto, .annotate, .addBackground, .redactPhoto])
    }

    @Test("Several images can also become one PDF")
    func severalImages() {
        #expect(ToolCatalog.tools(for: [.input(.jpg), .input(.png)]) == [.compress, .removeMetadata, .crop, .editPhoto, .annotate, .addBackground, .redactPhoto, .createPDF])
    }

    @Test("Several PDFs can be merged; one PDF cannot")
    func pdfs() {
        #expect(ToolCatalog.tools(for: [.input(.pdf)]) == [.compress, .removeMetadata])
        #expect(ToolCatalog.tools(for: [.input(.pdf), .input(.pdf)]) == [.compress, .removeMetadata, .mergePDFs])
    }

    @Test("Audio offers loudness and channel tools")
    func audio() {
        #expect(ToolCatalog.tools(for: [.input(.wav)]) == [.compress, .removeMetadata, .trim, .normalizeVolume, .audioChannels])
    }

    @Test("Video offers speed and split; several clips can be joined")
    func video() {
        #expect(ToolCatalog.tools(for: [.input(.mov)]) == [.compress, .removeMetadata, .crop, .trim, .changeSpeed, .splitVideo])
        #expect(ToolCatalog.tools(for: [.input(.mov), .input(.mp4)]).last == .joinVideos)
    }

    @Test("Mixed selections offer only the shared single-file tools")
    func mixed() {
        #expect(ToolCatalog.tools(for: [.input(.jpg), .input(.mp3)]) == [.compress, .removeMetadata])
        #expect(ToolCatalog.tools(for: [.input(.jpg), .input(.pdf)]) == [.compress, .removeMetadata])
    }

    @Test("Formats without tools, folders and unknown files offer nothing",
          arguments: [[SelectionItem.input(.svg)], [.input(.gif)], [.folder], [.unknown], [.input(.docx)], []])
    func nothing(selection: [SelectionItem]) {
        #expect(ToolCatalog.tools(for: selection).isEmpty)
    }

    @Test("Image tools are left out when this Mac can't read or write the format")
    func capabilities() {
        let noAVIF = FormatCapabilities(canRead: { $0 != .avif }, canWrite: { $0 != .avif })
        #expect(ToolCatalog.tools(for: [.input(.avif)], capabilities: noAVIF).isEmpty)
        #expect(ToolCatalog.tools(for: [.input(.jpg)], capabilities: noAVIF) == [.compress, .removeMetadata, .crop, .editPhoto, .annotate, .addBackground, .redactPhoto])
    }

    @Test("Tools that need choices say so")
    func options() {
        #expect(ToolKind.compress.needsOptions)
        #expect(!ToolKind.removeMetadata.needsOptions)
        #expect(ToolKind.joinVideos.usesWholeSelection)
        #expect(!ToolKind.compress.usesWholeSelection)
    }

    @Test("Defaults are sensible presets")
    func defaults() {
        #expect(ToolOptions.default(for: .compress) == .compress(.level(.balanced)))
        #expect(ToolOptions.default(for: .changeSpeed) == .speed(2))
        #expect(ToolOptions.default(for: .splitVideo) == .split(.equalParts(2)))
        #expect(ToolOptions.default(for: .audioChannels) == .channels(.mono))
        #expect(ToolOptions.default(for: .normalizeVolume) == .loudness(.podcast))
        #expect(ToolOptions.default(for: .mergePDFs) == ToolOptions.none)
    }

    @Test("Tool outputs are named after the input and the tool")
    func naming() {
        let input = URL(fileURLWithPath: "/tmp/in/photo.heic")
        let output = OutputNaming.toolDestination(for: input, suffix: "compressed", fileExtension: "heic", exists: { _ in false })
        #expect(output.path == "/tmp/in/photo compressed.heic")
        let folder = OutputNaming.toolDestination(for: input, suffix: "parts", fileExtension: nil, exists: { _ in false })
        #expect(folder.lastPathComponent == "photo parts")
    }
}

@Suite("MediaToolPlans")
struct MediaToolPlansTests {
    @Test("Target size becomes a video bitrate after the audio share, with headroom")
    func videoBitrate() {
        // 10 MB over 100 s is 800 kbps; 5% headroom leaves 760, and 128 goes to audio.
        #expect(MediaToolPlans.videoBitrateKbps(targetBytes: 10_000_000, durationSeconds: 100, audioKbps: 128) == 632)
        #expect(MediaToolPlans.videoBitrateKbps(targetBytes: 10_000_000, durationSeconds: 100, audioKbps: 0) == 760)
    }

    @Test("Non-finite speeds give no filter chain")
    func badSpeed() {
        #expect(MediaToolPlans.atempoChain(for: .infinity).isEmpty)
        #expect(MediaToolPlans.atempoChain(for: .nan).isEmpty)
    }

    @Test("A sliver left over at the end joins the last part")
    func remainderFolds() {
        let ranges = MediaToolPlans.splitRanges(durationSeconds: 60.4, plan: .everySeconds(30))
        #expect(ranges.count == 2)
        #expect(abs((ranges.last?.length ?? 0) - 30.4) < 0.001)
    }

    @Test("Parts shorter than a second are refused")
    func tinyParts() {
        #expect(MediaToolPlans.splitRanges(durationSeconds: 1, plan: .equalParts(20)).isEmpty)
    }

    @Test("A target too small for a watchable video is refused")
    func tooSmall() {
        #expect(MediaToolPlans.videoBitrateKbps(targetBytes: 100_000, durationSeconds: 600, audioKbps: 128) == nil)
    }

    @Test("Audio bitrate stays within what encoders accept")
    func audioBitrate() {
        #expect(MediaToolPlans.audioBitrateKbps(targetBytes: 1_000_000_000, durationSeconds: 10) == 320)
        #expect(MediaToolPlans.audioBitrateKbps(targetBytes: 1_000, durationSeconds: 600) == nil)
        #expect(MediaToolPlans.audioBitrateKbps(targetBytes: 1_200_000, durationSeconds: 100) == 96)
    }

    @Test("Speed changes beyond atempo's range are chained",
          arguments: [(0.25, [0.5, 0.5]), (0.5, [0.5]), (1.5, [1.5]), (4.0, [2.0, 2.0]), (3.0, [2.0, 1.5])])
    func atempo(factor: Double, expected: [Double]) {
        #expect(MediaToolPlans.atempoChain(for: factor) == expected)
    }

    @Test("Equal parts split the whole duration")
    func equalParts() {
        let ranges = MediaToolPlans.splitRanges(durationSeconds: 90, plan: .equalParts(3))
        #expect(ranges == [SplitRange(start: 0, length: 30), SplitRange(start: 30, length: 30), SplitRange(start: 60, length: 30)])
    }

    @Test("Fixed-length parts end with the remainder")
    func fixedLength() {
        let ranges = MediaToolPlans.splitRanges(durationSeconds: 130, plan: .everySeconds(60))
        #expect(ranges == [SplitRange(start: 0, length: 60), SplitRange(start: 60, length: 60), SplitRange(start: 120, length: 10)])
    }

    @Test("Split plans that make no sense give no parts")
    func badSplits() {
        #expect(MediaToolPlans.splitRanges(durationSeconds: 0, plan: .equalParts(2)).isEmpty)
        #expect(MediaToolPlans.splitRanges(durationSeconds: 10, plan: .equalParts(1)).isEmpty)
        #expect(MediaToolPlans.splitRanges(durationSeconds: 10, plan: .everySeconds(0)).isEmpty)
    }

    @Test("Joining letterboxes every clip onto the first clip's canvas and fills missing audio")
    func joinGraph() {
        let clips = [
            JoinClip(path: "/a.mov", hasAudio: true, durationSeconds: 5),
            JoinClip(path: "/b.mp4", hasAudio: false, durationSeconds: 3),
        ]
        let arguments = MediaToolPlans.joinArguments(clips: clips, width: 1920, height: 1080, framesPerSecond: 30, output: "/out.mp4")
        let graph = arguments[(arguments.firstIndex(of: "-filter_complex") ?? 0) + 1]
        #expect(graph.contains("[0:v]scale=iw*sar:ih,setsar=1,scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080"))
        #expect(graph.contains("[1:v]scale=iw*sar:ih,setsar=1,scale=1920:1080"))
        // Clip 2 has no audio, so a silent source (input 2) of its length stands in.
        #expect(arguments.contains("anullsrc=r=48000:cl=stereo"))
        #expect(graph.contains("[2:a]"))
        #expect(graph.contains("concat=n=2:v=1:a=1[v][a]"))
        #expect(arguments.last == "/out.mp4")
    }

    @Test("Loudness measurements are read from ffmpeg's report")
    func loudnessReport() throws {
        let report = """
        [Parsed_loudnorm_0 @ 0x1] \n{
            "input_i" : "-21.75",
            "input_tp" : "-20.69",
            "input_lra" : "0.00",
            "input_thresh" : "-31.75",
            "output_i" : "-16.03",
            "target_offset" : "0.05"
        }
        """
        let measurement = try #require(LoudnessMeasurement.parse(report))
        #expect(measurement.integrated == "-21.75")
        #expect(measurement.offset == "0.05")
        #expect(LoudnessMeasurement.parse("no json here") == nil)
    }

    @Test("The second loudness pass applies the measurement linearly")
    func loudnessFilter() {
        let measurement = LoudnessMeasurement(integrated: "-21.75", truePeak: "-20.69", range: "0.00", threshold: "-31.75", offset: "0.05")
        let filter = MediaToolPlans.loudnormFilter(target: .podcast, measured: measurement)
        #expect(filter == "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=-21.75:measured_TP=-20.69:measured_LRA=0.00:measured_thresh=-31.75:offset=0.05:linear=true")
    }

    @Test("A loudness report with any non-finite value is unusable")
    func nonFiniteLoudness() {
        let report = """
        {"input_i" : "-30.0", "input_tp" : "-20.0", "input_lra" : "0.00", "input_thresh" : "-inf", "target_offset" : "0.0"}
        """
        #expect(LoudnessMeasurement.parse(report) == nil)
    }

    @Test("Portrait phone video reports its displayed size")
    func rotation() throws {
        let json = """
        {"streams":[{"codec_type":"video","width":1920,"height":1080,"avg_frame_rate":"30/1","r_frame_rate":"120/1",
                     "side_data_list":[{"side_data_type":"Display Matrix","rotation":-90}]}],
         "format":{"duration":"2.0"}}
        """
        let info = try #require(MediaInfo.parse(ffprobeJSON: Data(json.utf8)))
        #expect(info.displayWidth == 1080 && info.displayHeight == 1920)
        #expect(info.framesPerSecond == 30)
    }

    @Test("Anamorphic video reports its displayed width")
    func sampleAspectRatio() throws {
        let json = """
        {"streams":[{"codec_type":"video","width":480,"height":360,"sample_aspect_ratio":"4:3"}],"format":{"duration":"1"}}
        """
        let info = try #require(MediaInfo.parse(ffprobeJSON: Data(json.utf8)))
        #expect(info.displayWidth == 640 && info.displayHeight == 360)
    }

    @Test("Without a container duration, the longest stream's is used")
    func streamDuration() throws {
        let json = """
        {"streams":[{"codec_type":"audio","duration":"7.5","channels":2},{"codec_type":"video","duration":"7.2","width":2,"height":2}],
         "format":{}}
        """
        let info = try #require(MediaInfo.parse(ffprobeJSON: Data(json.utf8)))
        #expect(info.durationSeconds == 7.5)
        #expect(info.channels == 2)
    }

    @Test("Joining first squares any anamorphic pixels")
    func joinSquaresPixels() {
        let arguments = MediaToolPlans.joinArguments(
            clips: [JoinClip(path: "/a.mp4", hasAudio: true, durationSeconds: 1)],
            width: 640, height: 360, framesPerSecond: 30, output: "/o.mp4")
        let graph = arguments[(arguments.firstIndex(of: "-filter_complex") ?? 0) + 1]
        #expect(graph.hasPrefix("[0:v]scale=iw*sar:ih,setsar=1,scale=640:360"))
    }

    @Test("ffprobe output gives duration, size, frame rate and streams")
    func probe() throws {
        let json = """
        {"streams":[{"codec_type":"video","width":1280,"height":720,"r_frame_rate":"30000/1001"},
                    {"codec_type":"audio","sample_rate":"44100"}],
         "format":{"duration":"12.500000"}}
        """
        let info = try #require(MediaInfo.parse(ffprobeJSON: Data(json.utf8)))
        #expect(info.durationSeconds == 12.5)
        #expect(info.width == 1280 && info.height == 720)
        #expect(abs((info.framesPerSecond ?? 0) - 29.97) < 0.01)
        #expect(info.hasAudio && info.hasVideo)
        #expect(info.sampleRate == 44100)
    }
}
