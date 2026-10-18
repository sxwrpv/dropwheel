import Foundation

/// Runs command-line tools to completion.
///
/// Standard output is delivered line by line (ffmpeg writes progress there),
/// or redirected to a file. The last part of standard error is kept for
/// error messages. Both pipes are read until end of file before the result
/// is decided, so the final lines are never lost. Cancelling the calling
/// task terminates the tool.
public enum ProcessRunner {
    /// Bytes of stderr kept for error messages.
    static let stderrTailLimit = 2_000

    /// Groups the processes `run` starts; only tests use anything but `standardTag`.
    static let standardTag = "dropwheel"

    /// Stops every tool Dropwheel started. Child processes outlive their
    /// parent on macOS, so the app calls this when it quits.
    public static func terminateAll() {
        RunningProcesses.shared.all().forEach { $0.terminate() }
    }

    /// Stops only the tools started with `tag`.
    static func terminateAll(tagged tag: String) {
        RunningProcesses.shared.all().filter { $0.tag == tag }.forEach { $0.terminate() }
    }

    static func run(
        _ executable: URL,
        arguments: [String],
        standardOutputFile: URL? = nil,
        tag: String = standardTag,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws(ConversionError) {
        let process = RunningProcess(executable: executable, arguments: arguments, tag: tag,
                                     standardOutputFile: standardOutputFile, onLine: onLine)
        do {
            try await withTaskCancellationHandler {
                try await process.runToCompletion()
            } onCancel: {
                process.terminate()
            }
        } catch let error as ConversionError {
            throw error
        } catch {
            throw .toolFailed(tool: executable.lastPathComponent, message: error.localizedDescription)
        }
    }
}

/// Tools currently running, so they can all be stopped at quit.
private final class RunningProcesses: @unchecked Sendable {
    static let shared = RunningProcesses()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: RunningProcess] = [:]

    func add(_ process: RunningProcess) {
        lock.withLock { processes[ObjectIdentifier(process)] = process }
    }

    func remove(_ process: RunningProcess) {
        lock.withLock { processes[ObjectIdentifier(process)] = nil }
    }

    func all() -> [RunningProcess] {
        lock.withLock { Array(processes.values) }
    }
}

/// Owns one `Process`. Its pipes are drained on background threads, so all
/// shared state is behind `lock`.
private final class RunningProcess: @unchecked Sendable {
    private static let readChunkSize = 64 * 1024

    let tag: String
    private let process = Process()
    private let toolName: String
    private let standardOutputFile: URL?
    private let onLine: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrTail = Data()
    private var wasCancelled = false
    private var hasLaunched = false

    init(executable: URL, arguments: [String], tag: String, standardOutputFile: URL?, onLine: (@Sendable (String) -> Void)?) {
        process.executableURL = executable
        process.arguments = arguments
        self.tag = tag
        toolName = executable.lastPathComponent
        self.standardOutputFile = standardOutputFile
        self.onLine = onLine
    }

    /// Safe to call at any time: before launch it prevents the launch.
    func terminate() {
        let launched = lock.withLock {
            wasCancelled = true
            return hasLaunched
        }
        if launched { process.terminate() }
    }

    func runToCompletion() async throws(ConversionError) {
        process.standardInput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let (stdoutPipe, outputFile) = try prepareStandardOutput()
        defer { try? outputFile?.close() }

        let exit = ExitSignal()
        process.terminationHandler = { _ in exit.signal() }
        // Register before launching: a terminateAll() that arrives in between
        // then marks this process cancelled, and launch() refuses to start it.
        RunningProcesses.shared.add(self)
        defer { RunningProcesses.shared.remove(self) }
        try launch()

        async let stderrDrained: Void = Self.drain(stderrPipe.fileHandleForReading) { [self] in appendStderr($0) }
        async let stdoutDrained: Void = Self.drain(stdoutPipe?.fileHandleForReading) { [self] in appendStdout($0) }
        await exit.wait()
        _ = await (stderrDrained, stdoutDrained)
        flushLastLine()
        try outcome()
    }

    /// Launching under the same lock that `terminate()` takes means a cancel
    /// can never slip in between the check and the launch.
    private func launch() throws(ConversionError) {
        let failure: ConversionError? = lock.withLock {
            if wasCancelled { return .cancelled }
            do {
                try process.run()
                hasLaunched = true
                return nil
            } catch {
                return .toolFailed(tool: toolName, message: error.localizedDescription)
            }
        }
        if let failure { throw failure }
    }

    private func prepareStandardOutput() throws(ConversionError) -> (Pipe?, FileHandle?) {
        guard let standardOutputFile else {
            let pipe = Pipe()
            process.standardOutput = pipe
            return (pipe, nil)
        }
        guard FileManager.default.createFile(atPath: standardOutputFile.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: standardOutputFile) else {
            throw .writeFailed("Couldn’t create \(standardOutputFile.lastPathComponent).")
        }
        process.standardOutput = handle
        return (nil, handle)
    }

    /// Reads `handle` until end of file on a background thread, so blocking
    /// reads never occupy Swift's cooperative thread pool.
    private static func drain(_ handle: FileHandle?, onChunk: @escaping @Sendable (Data) -> Void) async {
        guard let handle else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                while let chunk = try? handle.read(upToCount: readChunkSize), !chunk.isEmpty {
                    onChunk(chunk)
                }
                continuation.resume()
            }
        }
    }

    private func outcome() throws(ConversionError) {
        let (cancelled, message) = lock.withLock {
            (wasCancelled, String(decoding: stderrTail, as: UTF8.self))
        }
        if cancelled { throw .cancelled }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let summary = Self.lastMeaningfulLine(of: message) ?? "exit status \(process.terminationStatus)"
            throw .toolFailed(tool: toolName, message: summary)
        }
    }

    private func appendStdout(_ data: Data) {
        guard let onLine else { return }
        let lines: [String] = lock.withLock {
            stdoutBuffer.append(data)
            var complete: [String] = []
            while let newline = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = stdoutBuffer[stdoutBuffer.startIndex..<newline]
                complete.append(String(decoding: line, as: UTF8.self))
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            }
            return complete
        }
        lines.forEach(onLine)
    }

    /// Delivers a final line that had no trailing newline.
    private func flushLastLine() {
        guard let onLine else { return }
        let remainder: String? = lock.withLock {
            guard !stdoutBuffer.isEmpty else { return nil }
            defer { stdoutBuffer.removeAll() }
            return String(decoding: stdoutBuffer, as: UTF8.self)
        }
        if let remainder { onLine(remainder) }
    }

    private func appendStderr(_ data: Data) {
        lock.withLock {
            stderrTail.append(data)
            if stderrTail.count > ProcessRunner.stderrTailLimit {
                stderrTail = stderrTail.suffix(ProcessRunner.stderrTailLimit)
            }
        }
    }

    private static func lastMeaningfulLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

/// A one-shot signal that can fire before or after someone starts waiting.
private final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            hasFired = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyFired = lock.withLock {
                if hasFired { return true }
                waiter = continuation
                return false
            }
            if alreadyFired { continuation.resume() }
        }
    }
}
