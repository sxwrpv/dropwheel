import AppKit
import DropwheelCore
import os

/// Carries out the File actions wheel: AirDrop, Float, Copy, Move, Copy Path and Terminal.
@MainActor
final class FileActionPerformer: NSObject, NSSharingServiceDelegate {
    /// Opening more Terminal windows than this from one drop is almost certainly a mistake.
    private static let maxTerminalWindows = 5
    /// Longest list of problems shown in one alert.
    private static let maxListedProblems = 10

    private let shelf: FloatShelf
    private let preferences: Preferences
    private let logger = Logger(subsystem: "dev.dropwheel", category: "FileActions")
    private let moveQueue = DispatchQueue(label: "dev.dropwheel.move", qos: .userInitiated)
    /// Kept alive until the AirDrop picker finishes.
    private var airDropService: NSSharingService?
    private var activeMoveCount = 0

    /// True while files are being moved; quitting then could leave a partial copy.
    var isBusy: Bool { activeMoveCount > 0 }

    init(shelf: FloatShelf, preferences: Preferences) {
        self.shelf = shelf
        self.preferences = preferences
    }

    func perform(_ action: FileActionKind, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch action {
        case .airDrop: airDrop(urls)
        case .float: shelf.add(urls)
        case .copy: copyFiles(urls)
        case .move: move(urls)
        case .copyPath: copyPaths(urls)
        case .terminal: openInTerminal(urls)
        }
    }

    // MARK: AirDrop

    private func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            showAlert("AirDrop isn’t available", detail: "Check that Wi-Fi and Bluetooth are on.")
            return
        }
        airDropService = service
        service.delegate = self
        activateApp()
        service.perform(withItems: urls)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        airDropService = nil
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        airDropService = nil
        let nsError = error as NSError
        guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else { return }
        showAlert("AirDrop didn’t finish", detail: error.localizedDescription)
    }

    // MARK: Clipboard

    private func copyFiles(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.writeObjects(urls.map { $0 as NSURL }) {
            showAlert("Couldn’t copy the files", detail: "The clipboard didn’t accept them.")
        }
    }

    private func copyPaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(FilePaths.copyPathText(for: urls), forType: .string)
    }

    // MARK: Move

    private func move(_ urls: [URL]) {
        activateApp()
        let picker = NSOpenPanel()
        picker.title = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to…" : "Move \(urls.count) items to…"
        picker.prompt = "Move"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let destination = picker.url else { return }

        let plan = Self.planMove(urls, to: destination)
        guard !plan.movable.isEmpty else {
            showProblems(plan.skipped)
            return
        }

        activeMoveCount += 1
        Task {
            let failures = await Self.moveItems(plan.movable, to: destination, on: moveQueue)
            activeMoveCount -= 1
            showProblems(plan.skipped + failures)
        }
    }

    /// Splits a selection into items that can move and reasons for skipping the rest.
    private static func planMove(_ urls: [URL], to destination: URL) -> (movable: [URL], skipped: [String]) {
        var movable: [URL] = []
        var skipped: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            if FilePaths.isSameOrInside(destination, url) {
                skipped.append("\(name): a folder can’t be moved into itself.")
            } else if isSameDirectory(url.deletingLastPathComponent(), destination) {
                skipped.append("\(name): it’s already in that folder.")
            } else {
                movable.append(url)
            }
        }
        return (movable, skipped)
    }

    /// Compares folders by file-system identity, so symlinks and letter case
    /// don't make one folder look like two.
    private static func isSameDirectory(_ first: URL, _ second: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        if let firstID = try? first.resourceValues(forKeys: key).fileResourceIdentifier,
           let secondID = try? second.resourceValues(forKeys: key).fileResourceIdentifier {
            return firstID.isEqual(secondID)
        }
        return FilePaths.isSameOrInside(first, second) && FilePaths.isSameOrInside(second, first)
    }

    /// Moves items on a background queue, because moves across volumes copy
    /// data. Returns one message per failure. Never overwrites: clashes get a
    /// numbered name, and `moveItem` refuses to replace an existing item.
    private nonisolated static func moveItems(_ urls: [URL], to destination: URL, on queue: DispatchQueue) async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async {
                let info = ProcessInfo.processInfo
                let activity = info.beginActivity(options: [.userInitiated, .suddenTerminationDisabled],
                                                  reason: "Moving files")
                defer { info.endActivity(activity) }
                continuation.resume(returning: moveSynchronously(urls, to: destination))
            }
        }
    }

    private nonisolated static func moveSynchronously(_ urls: [URL], to destination: URL) -> [String] {
        let fileManager = FileManager.default
        var failures: [String] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let target = FilePaths.uniqueDestination(for: url.lastPathComponent, in: destination,
                                                     isDirectory: isDirectory) {
                fileManager.fileExists(atPath: $0.path)
            }
            do {
                try fileManager.moveItem(at: url, to: target)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures
    }

    // MARK: Terminal

    private func openInTerminal(_ urls: [URL]) {
        let app = preferences.terminalApp
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue) else {
            showAlert("\(app.title) isn’t installed", detail: "Choose another terminal app from the Dropwheel menu.")
            return
        }
        let directories = urls.map {
            FilePaths.terminalDirectory(for: $0) { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            }
        }
        let unique = directories.reduce(into: [URL]()) { result, url in
            if !result.contains(url) { result.append(url) }
        }
        for directory in unique.prefix(Self.maxTerminalWindows) {
            NSWorkspace.shared.open([directory], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { [logger] _, error in
                if let error {
                    logger.error("Opening \(app.title) failed: \(error.localizedDescription)")
                }
            }
        }
        if unique.count > Self.maxTerminalWindows {
            showAlert("Opened the first \(Self.maxTerminalWindows) folders",
                      detail: "The selection spans \(unique.count) folders. Drop fewer items to open the rest.",
                      style: .informational)
        }
    }

    // MARK: Alerts

    private func showProblems(_ problems: [String]) {
        guard !problems.isEmpty else { return }
        let listed = problems.prefix(Self.maxListedProblems).joined(separator: "\n")
        let remainder = problems.count - Self.maxListedProblems
        let detail = remainder > 0 ? "\(listed)\n…and \(remainder) more." : listed
        showAlert(problems.count == 1 ? "An item wasn’t moved" : "Some items weren’t moved", detail: detail)
    }

    private func showAlert(_ message: String, detail: String, style: NSAlert.Style = .warning) {
        logger.error("\(message): \(detail)")
        activateApp()
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    private func activateApp() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
