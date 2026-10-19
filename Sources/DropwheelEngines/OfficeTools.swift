import AppKit
import DropwheelCore
import Foundation

/// pandoc, for conversions between text-based document formats.
enum Pandoc {
    private static let timeout: Duration = .seconds(5 * 60)

    /// Converts `input` (read with pandoc's `reader`) to `target` at `output`.
    /// `--sandbox` stops pandoc reading anything but the input or touching the
    /// network, so a document can't make a conversion go online.
    static func convert(_ input: URL, reader: String, to target: FileFormat, output: URL, title: String) async throws(ConversionError) {
        let pandoc = try ToolLocator.require(.pandoc)
        let arguments = ["--sandbox", "-f", reader] + writerArguments(for: target, title: title)
            + ["-o", output.path, input.path]
        try await ProcessRunner.run(pandoc, arguments: arguments, timeout: timeout)
    }

    static func writerArguments(for target: FileFormat, title: String) -> [String] {
        switch target {
        // Markdown can't hold images, so pictures from DOCX or EPUB are left out.
        case .md: ["-t", "gfm", "--wrap=none"]
        case .txt: ["-t", "plain", "--wrap=none"]
        case .epub: ["-t", "epub3", "-M", "title=\(title)"]
        // Embedding keeps pictures from DOCX and EPUB inside the single HTML file.
        case .html: ["-t", "html5", "-s", "--embed-resources", "-M", "pagetitle=\(title)"]
        default: ["-t", "docx"]
        }
    }
}

/// LibreOffice in headless mode, for Office formats, spreadsheets and PDF export.
enum LibreOffice {
    private static let timeout: Duration = .seconds(10 * 60)
    /// Bump the version when the profile settings change, so existing
    /// installs start from a fresh profile that has them.
    private static let profileFolderName = "LibreOfficeProfile-v2"

    /// Settings for the private profile. They stop documents from loading
    /// linked images or other content from the network, and from running
    /// macros or active content.
    private static let profileSettings = """
    <?xml version="1.0" encoding="UTF-8"?>
    <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableActiveContent" oor:op="fuse"><value>true</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
    </oor:items>
    """
    private static let requiredSettingNames = ["BlockUntrustedRefererLinks", "DisableMacrosExecution", "DisableActiveContent"]

    /// Two LibreOffice processes sharing one profile interfere with each
    /// other, so conversions take turns.
    private static let gate = SerialGate()

    /// Converts with `--convert-to filter`. LibreOffice names its output
    /// itself, so it writes into a scratch folder and the result is moved to `output`.
    static func convert(_ input: URL, filter: String, inputFilter: String? = nil, to output: URL) async throws(ConversionError) {
        try await gate.acquire()
        do {
            try await convertNow(input, filter: filter, inputFilter: inputFilter, to: output)
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
    }

    private static func convertNow(_ input: URL, filter: String, inputFilter: String?, to output: URL) async throws(ConversionError) {
        let soffice = try ToolLocator.require(.soffice)
        let outputDirectory = try ScratchSpace.make(near: output)
        defer { ScratchSpace.discard(outputDirectory) }

        let arguments = ["--headless", "--invisible", "--norestore", "--nolockcheck", "--nodefault", "--nologo",
                         "-env:UserInstallation=\(try preparedProfile().absoluteString)"]
            + (inputFilter.map { ["--infilter=\($0)"] } ?? [])
            + ["--convert-to", filter, "--outdir", outputDirectory.path, input.path]
        try await ProcessRunner.run(soffice, arguments: arguments, timeout: timeout)

        // LibreOffice can exit successfully without writing anything.
        let produced = (try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []
        guard let result = produced.first, produced.count == 1 else {
            throw .toolFailed(tool: "LibreOffice", message: "It couldn’t convert \(input.lastPathComponent).")
        }
        do {
            try FileManager.default.moveItem(at: result, to: output)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    /// A profile of its own, so a LibreOffice window the user has open is
    /// never disturbed. It persists, which makes later conversions start
    /// faster. The security settings are rewritten if they've gone missing.
    private static func preparedProfile() throws(ConversionError) -> URL {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            let profile = support.appendingPathComponent("Dropwheel/\(profileFolderName)", isDirectory: true)
            let user = profile.appendingPathComponent("user", isDirectory: true)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            let settings = user.appendingPathComponent("registrymodifications.xcu")
            let current = (try? String(contentsOf: settings, encoding: .utf8)) ?? ""
            if !requiredSettingNames.allSatisfy(current.contains) {
                try profileSettings.write(to: settings, atomically: true, encoding: .utf8)
            }
            return profile
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }
}

/// Lets one task at a time through, in arrival order. A task cancelled
/// while it waits leaves the queue at once instead of waiting its turn.
actor SerialGate {
    private var isBusy = false
    /// `true` hands the gate over; `false` means the wait was cancelled.
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    func acquire() async throws(ConversionError) {
        guard isBusy else {
            isBusy = true
            return
        }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
        guard granted else { throw .cancelled }
        if Task.isCancelled {
            release()
            throw .cancelled
        }
    }

    func release() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().continuation.resume(returning: true)
        }
    }

    private func abandon(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}

/// Pages, driven through AppleScript, for reading and writing .pages files.
/// macOS asks the user once to allow Dropwheel to control Pages.
enum PagesBridge {
    private static let bundleIdentifier = "com.apple.iWork.Pages"
    private static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    private static let timeout: Duration = .seconds(3 * 60)

    // Paths arrive as script arguments, never inside the script text.
    private static func script(action: String) -> [String] {
        [
            "on run argv",
            "set inputFile to POSIX file (item 1 of argv)",
            "set outputFile to POSIX file (item 2 of argv)",
            "tell application id \"\(bundleIdentifier)\"",
            "set theDocument to open inputFile",
            "try",
            action,
            "on error message",
            "close theDocument saving no",
            "error message",
            "end try",
            "close theDocument saving no",
            "end tell",
            "end run",
        ]
    }

    static func exportToWord(_ input: URL, output: URL) async throws(ConversionError) {
        try await run(script(action: "export theDocument to outputFile as Microsoft Word"), input: input, output: output)
    }

    static func saveAsPages(_ input: URL, output: URL) async throws(ConversionError) {
        try await run(script(action: "save theDocument in outputFile"), input: input, output: output)
    }

    /// Pages works on a private copy: if the original were already open in
    /// Pages, "open" would return that window and closing it would discard
    /// the user's unsaved edits.
    private static func run(_ script: [String], input: URL, output: URL) async throws(ConversionError) {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil else {
            throw .missingApp("Pages")
        }
        let scratch = try ScratchSpace.make(near: output)
        defer { ScratchSpace.discard(scratch) }
        let copy = scratch.appendingPathComponent(input.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: input, to: copy)
        } catch {
            throw .unreadableInput(input.lastPathComponent)
        }

        let arguments = script.flatMap { ["-e", $0] } + [copy.path, output.path]
        do {
            try await ProcessRunner.run(osascript, arguments: arguments, timeout: timeout)
        } catch .toolFailed(_, let message) {
            throw .toolFailed(tool: "Pages", message: message)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw .toolFailed(tool: "Pages", message: "It didn’t save the converted document.")
        }
    }
}
