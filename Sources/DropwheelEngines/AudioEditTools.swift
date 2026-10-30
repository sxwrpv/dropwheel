import CoreGraphics
import DropwheelCore
import Foundation

/// One decode of a whole recording, for drawing it and placing marks on it.
public struct AudioTimeline: Equatable, Sendable {
    /// The real length, from the samples: a file's stated length can be an estimate.
    public let seconds: Double
    public let peaks: [Float]
}

extension MediaPreview {
    /// A temporary WAV to listen to: bleeped with `recipe`, or the original
    /// sound when it is nil. Give it to `discardListeningCopy` when finished;
    /// quitting removes any left behind.
    public static func listeningCopy(of url: URL, recipe: BleepRecipe?) async throws(ConversionError) -> URL {
        let ffmpeg = try ToolLocator.require(.ffmpeg)
        let copy = temporaryFile(extension: "wav")
        do {
            try await ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-v", "error", "-i", url.path]
                + BleepPlans.listeningOptions(recipe) + ["-y", copy.path])
        } catch {
            discardListeningCopy(copy)
            throw error
        }
        return copy
    }

    /// Removes a copy made by `listeningCopy`.
    public static func discardListeningCopy(_ copy: URL) {
        discardTemporaryFile(copy)
    }

    /// The visualizer's video as it looks at `seconds`, made with the same
    /// filter as the saved video. Where there is no sound to draw, past the
    /// end for example, it is just the canvas.
    public static func visualizerFrame(of url: URL, recipe: VisualizerRecipe,
                                       at seconds: Double) async throws(ConversionError) -> CGImage {
        let canvas = try AudioEditTools.canvas(for: recipe)
        guard recipe.content == .waveform else { return canvas }
        let ffmpeg = try ToolLocator.require(.ffmpeg)
        let canvasFile = temporaryFile(extension: "png")
        let frameFile = temporaryFile(extension: "png")
        defer {
            discardTemporaryFile(canvasFile)
            discardTemporaryFile(frameFile)
        }
        try AudioEditTools.write(canvas, to: canvasFile)
        try await ProcessRunner.run(ffmpeg, arguments: VisualizerPlans.previewArguments(
            canvas: canvasFile.path, audio: url.path, output: frameFile.path, recipe: recipe, seconds: seconds))
        return decodedImage(at: frameFile) ?? canvas
    }
}

/// Bleep Audio and the audio visualizer, as chosen in their editors.
enum AudioEditTools {
    static func bleep(_ input: URL, format: FileFormat, recipe: BleepRecipe, output: URL,
                      progress: @escaping ProgressHandler) async throws(ConversionError) {
        guard let options = BleepPlans.options(recipe, format: format) else { throw .nothingToBleep(input.lastPathComponent) }
        let info = try await FFmpegRunner.probe(input)
        guard info.hasAudio else { throw .unreadableInput(input.lastPathComponent) }
        let arguments = FFmpegArguments.command(input: input.path, options: options, output: output.path, keepMetadata: false)
        try await FFmpegRunner.run(arguments, expectedSeconds: info.durationSeconds, progress: progress)
    }

    static func visualize(_ input: URL, recipe: VisualizerRecipe, output: URL,
                          progress: @escaping ProgressHandler) async throws(ConversionError) {
        guard recipe.isComplete else { throw .needsPicture(input.lastPathComponent) }
        // Decoded for the real length: a stated length can be an estimate or
        // missing, and a file with no sound in it is refused here.
        let seconds = try await MediaPreview.decodedSeconds(of: input)
        guard seconds >= VisualizerPlans.shortestSeconds else { throw .tooShort(input.lastPathComponent) }
        let scratch = try ScratchSpace.make(near: input)
        defer { ScratchSpace.discard(scratch) }
        let canvasFile = scratch.appendingPathComponent("canvas.png")
        try write(try canvas(for: recipe), to: canvasFile)
        let arguments = VisualizerPlans.arguments(canvas: canvasFile.path, audio: input.path, output: output.path,
                                                  recipe: recipe, seconds: seconds)
        try await FFmpegRunner.run(arguments, expectedSeconds: seconds, progress: progress)
    }

    /// The background colour with the picture, if any, fitted inside it.
    /// Drawn here rather than by ffmpeg so that every picture format and
    /// rotation works the same as in the photo tools.
    static func canvas(for recipe: VisualizerRecipe) throws(ConversionError) -> CGImage {
        let width = recipe.shape.width
        let height = recipe.shape.height
        guard let context = ImageConverter.makeContext(width: width, height: height, opaque: true) else {
            throw .writeFailed("Couldn’t prepare the video’s background.")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(PhotoRendering.cgColor(recipe.background))
        context.fill(bounds)
        if let url = recipe.picture {
            let picture = try MediaEditTools.coveringThumbnail(url, cell: PixelRect(x: 0, y: 0, width: width, height: height))
            let scale = min(bounds.width / CGFloat(picture.width), bounds.height / CGFloat(picture.height))
            let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
            context.interpolationQuality = .high
            context.draw(picture, in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                             width: size.width, height: size.height))
        }
        guard let image = context.makeImage() else { throw .writeFailed("Couldn’t prepare the video’s background.") }
        return image
    }

    static func write(_ canvas: CGImage, to url: URL) throws(ConversionError) {
        try ImageConverter.write(ImageConverter.LoadedImage(image: canvas, properties: [:], dpi: ImageConverter.defaultDPI),
                                 as: .png, to: url)
    }
}
