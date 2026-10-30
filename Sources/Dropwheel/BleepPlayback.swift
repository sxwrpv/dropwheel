import AVFoundation
import DropwheelCore
import DropwheelEngines
import SwiftUI

/// The playhead, apart from `BleepPlayback` so that only the views showing
/// it redraw as it moves, and the waveform doesn't.
@MainActor
final class PlayheadClock: ObservableObject {
    @Published var time = 0.0
}

/// Plays a recording or its bleeped version from the playhead.
///
/// Both versions are WAV listening copies made by ffmpeg, so every format
/// plays, including those AVFoundation can't read, and both line up exactly
/// with each other and with the saved file. They are made when first needed.
@MainActor
final class BleepPlayback: ObservableObject {
    enum Version: String, CaseIterable {
        case original
        case bleeped

        var title: String { rawValue.capitalized }
    }

    private static let clockInterval = CMTime(value: 1, timescale: 30)
    private static let seekTimescale: CMTimeScale = 44_100

    let url: URL
    let clock = PlayheadClock()
    @Published private(set) var isPlaying = false
    /// True while a listening copy is being made.
    @Published private(set) var isPreparing = false
    @Published private(set) var errorText: String?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var originalCopy: URL?
    private var bleepedCopy: (recipe: BleepRecipe, file: URL)?
    private var loadedFile: URL?
    private var statusObservation: NSKeyValueObservation?
    private var preparation: Task<Void, Never>?
    /// What was last asked for, while it is playing or being prepared.
    private var requested: (version: Version, recipe: BleepRecipe)?
    /// Changes with every play and pause, so work that finishes late can
    /// tell it has been overtaken.
    private var request = 0
    /// Seeks still landing. Times reported meanwhile are out of date: a newly
    /// loaded file reports 0, which would flash the playhead back to the start.
    private var pendingSeeks = 0
    private var isStopped = false

    init(url: URL) {
        self.url = url
        timeObserver = player.addPeriodicTimeObserver(forInterval: Self.clockInterval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    /// Plays `version` from the playhead, replacing whatever is playing.
    func play(_ version: Version, recipe: BleepRecipe) {
        preparation?.cancel()
        request += 1
        requested = (version, recipe)
        errorText = nil
        isPreparing = true
        let current = request
        preparation = Task { [weak self] in
            await self?.start(version, recipe: recipe, request: current)
        }
    }

    /// Stops the bleeped version when the marks change, as it no longer
    /// matches them; Play makes a new copy. The recipe Play itself just asked
    /// for changes nothing, even if the view hears about it afterwards.
    func recipeChanged(to recipe: BleepRecipe) {
        guard let requested, requested.version == .bleeped, requested.recipe != recipe else { return }
        pause()
    }

    func pause() {
        preparation?.cancel()
        request += 1
        requested = nil
        isPreparing = false
        player.pause()
        isPlaying = false
    }

    func seek(to time: Double) {
        seek(to: time) {}
    }

    private func seek(to time: Double, then finished: @escaping @MainActor () -> Void) {
        clock.time = time
        guard loadedFile != nil else { return }
        pendingSeeks += 1
        player.seek(to: Self.cmTime(time), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.pendingSeeks -= 1
                finished()
            }
        }
    }

    /// Stops playing, and removes the listening copies. Call when the editor closes.
    func stop() {
        isStopped = true
        pause()
        player.replaceCurrentItem(with: nil)
        loadedFile = nil
        statusObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        removeEndObserver()
        originalCopy.map(MediaPreview.discardListeningCopy)
        originalCopy = nil
        bleepedCopy.map { MediaPreview.discardListeningCopy($0.file) }
        bleepedCopy = nil
    }

    private func start(_ version: Version, recipe: BleepRecipe, request: Int) async {
        do {
            let file = try await copy(of: version, recipe: recipe)
            guard request == self.request else { return }
            load(file)
            seek(to: clock.time) { [weak self] in
                guard let self, request == self.request else { return }
                if let error = player.currentItem?.error {
                    playbackFailed(error.localizedDescription)
                    return
                }
                player.play()
                isPlaying = true
                isPreparing = false
            }
        } catch {
            // A newer play or a pause overtook this one; only real failures show.
            guard request == self.request else { return }
            errorText = error.localizedDescription
            isPreparing = false
        }
    }

    /// The listening copy for `version`, reused until the recipe changes.
    /// With nothing marked, the bleeped version is the original.
    private func copy(of version: Version, recipe: BleepRecipe) async throws(ConversionError) -> URL {
        if version == .bleeped, !BleepPlans.merged(recipe.ranges).isEmpty {
            if let bleepedCopy, bleepedCopy.recipe == recipe { return bleepedCopy.file }
            let file = try await MediaPreview.listeningCopy(of: url, recipe: recipe)
            try discardIfStopped(file)
            bleepedCopy.map { MediaPreview.discardListeningCopy($0.file) }
            bleepedCopy = (recipe, file)
            return file
        }
        if let originalCopy { return originalCopy }
        let file = try await MediaPreview.listeningCopy(of: url, recipe: nil)
        try discardIfStopped(file)
        originalCopy = file
        return file
    }

    /// A copy that finishes after the editor closed has nobody left to remove it.
    private func discardIfStopped(_ file: URL) throws(ConversionError) {
        guard isStopped else { return }
        MediaPreview.discardListeningCopy(file)
        throw .cancelled
    }

    private func load(_ file: URL) {
        guard file != loadedFile else { return }
        loadedFile = file
        // Paused first, or the new file would sound from its start until the seek lands.
        player.pause()
        let item = AVPlayerItem(url: file)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "This version couldn’t be played."
            Task { @MainActor in self?.playbackFailed(message) }
        }
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
        player.replaceCurrentItem(with: item)
    }

    private func removeEndObserver() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    private func playbackFailed(_ message: String) {
        requested = nil
        errorText = message
        isPlaying = false
        isPreparing = false
    }

    private func tick(_ seconds: Double) {
        guard isPlaying, pendingSeeks == 0, seconds.isFinite else { return }
        clock.time = seconds
    }

    /// Back to the start, ready to play again.
    private func reachedEnd() {
        requested = nil
        isPlaying = false
        seek(to: 0)
    }

    private static func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: seekTimescale)
    }
}
