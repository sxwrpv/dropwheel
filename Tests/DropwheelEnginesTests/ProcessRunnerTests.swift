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

    @Test("A tool that ignores the request to stop is killed")
    func killsStubbornTool() async {
        let started = ContinuousClock.now
        let task = Task {
            try await ProcessRunner.run(Self.shell, arguments: ["-c", "trap '' TERM; while :; do sleep 0.1; done"])
        }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: ConversionError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(6))
    }

    @Test("Stopping everything waits briefly, then kills what is still running")
    func terminateAllKills() async {
        let tag = "test-\(UUID().uuidString)"
        let task = Task {
            try await ProcessRunner.run(Self.shell, arguments: ["-c", "trap '' TERM; while :; do sleep 0.1; done"], tag: tag)
        }
        try? await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        ProcessRunner.terminateAll(tagged: tag)
        await #expect(throws: ConversionError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(6))
    }

    @Test("A tool that runs past its time limit is stopped and reported")
    func timeout() async {
        let started = ContinuousClock.now
        await #expect(throws: ConversionError.toolFailed(tool: "sh", message: "It didn’t finish within 0 minutes.")) {
            try await ProcessRunner.run(Self.shell, arguments: ["-c", "sleep 5"], timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("A task cancelled while waiting at the gate leaves promptly")
    func gateCancellation() async throws {
        let gate = SerialGate()
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        await #expect(throws: ConversionError.cancelled) { try await waiter.value }
        await gate.release()
        // The gate is free again for the next caller.
        try await gate.acquire()
        await gate.release()
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
