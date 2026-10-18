import Foundation
import Testing
@testable import DropwheelEngines

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    @Test("The last stderr line reaches the error message, even after heavy output")
    func finalStderrLine() async {
        let script = "i=0; while [ $i -lt 2000 ]; do echo noise $i >&2; i=$((i+1)); done; echo FINAL-ERROR >&2; exit 3"
        for _ in 0..<20 {
            await #expect(throws: ConversionError.toolFailed(tool: "sh", message: "FINAL-ERROR")) {
                try await ProcessRunner.run(Self.shell, arguments: ["-c", script])
            }
        }
    }

    @Test("Every stdout line arrives, including a last line without a newline")
    func allStdoutLines() async throws {
        let collector = Collector()
        try await ProcessRunner.run(Self.shell, arguments: ["-c", "seq 1 3000; printf tail"]) { collector.append($0) }
        let lines = collector.lines
        #expect(lines.count == 3001)
        #expect(lines.last == "tail")
    }

    @Test("Cancelling stops a long-running tool promptly")
    func cancelStops() async {
        let started = ContinuousClock.now
        let task = Task { try await ProcessRunner.run(Self.shell, arguments: ["-c", "sleep 5"]) }
        task.cancel()
        await #expect(throws: ConversionError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    // Uses its own tag: tests run in parallel, and stopping every process
    // would also stop other tests' tools.
    @Test("terminateAll stops the running tools it is given")
    func terminateAll() async {
        let tag = "test-\(UUID().uuidString)"
        let started = ContinuousClock.now
        let task = Task { try await ProcessRunner.run(Self.shell, arguments: ["-c", "sleep 5"], tag: tag) }
        try? await Task.sleep(for: .milliseconds(200))
        ProcessRunner.terminateAll(tagged: tag)
        await #expect(throws: ConversionError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] { lock.withLock { storage } }

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }
}
