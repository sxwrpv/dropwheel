import DropwheelCore
import DropwheelEngines
import Foundation
import os

/// One conversion or tool run the user asked for.
struct Job: Identifiable, Equatable {
    enum State: Equatable {
        case waiting
        case running(fraction: Double)
        case finished(URL)
        case failed(String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .waiting, .running: true
            case .finished, .failed, .cancelled: false
            }
        }
    }

    let id: UUID
    /// What the panel shows, e.g. "photo.heic → JPG" or "clip.mov · Compress".
    let title: String
    let state: State

    func with(_ state: State) -> Job {
        Job(id: id, title: title, state: state)
    }
}

/// The work behind a job: given a progress callback, produce the result's location.
typealias JobWork = @Sendable (@escaping ProgressHandler) async throws(ConversionError) -> URL

/// Runs jobs one at a time, in the order they were dropped. Video encodes
/// use every core, so running several at once would only slow each down.
@MainActor
final class JobCenter: ObservableObject {
    @Published private(set) var jobs: [Job] = []

    private let conversions = ConversionService()
    private let tools = ToolService()
    private let logger = Logger(subsystem: "dev.dropwheel", category: "Jobs")
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// The most recently queued job; the next one waits for it.
    private var tail: Task<Void, Never>?

    var isBusy: Bool { jobs.contains { $0.state.isActive } }

    func convert(_ urls: [URL], to target: FileFormat) {
        let conversions = self.conversions
        for url in urls {
            enqueue(title: "\(url.lastPathComponent) → \(target.label)") { progress throws(ConversionError) in
                try await conversions.convert(url, to: target, progress: progress)
            }
        }
    }

    /// Whole-selection tools make one job; the others make one job per file.
    func runTool(_ tool: ToolKind, on urls: [URL], options: ToolOptions) {
        let tools = self.tools
        if tool.usesWholeSelection {
            enqueue(title: "\(urls.count) files · \(tool.title)") { progress throws(ConversionError) in
                try await tools.run(tool, on: urls, options: options, progress: progress)
            }
            return
        }
        for url in urls {
            enqueue(title: "\(url.lastPathComponent) · \(tool.title)") { progress throws(ConversionError) in
                try await tools.run(tool, on: [url], options: options, progress: progress)
            }
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        if jobs.first(where: { $0.id == id })?.state == .waiting {
            update(id, to: .cancelled)
        }
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        jobs = jobs.map { $0.state == .waiting ? $0.with(.cancelled) : $0 }
    }

    func clearFinished() {
        jobs = jobs.filter(\.state.isActive)
    }

    private func enqueue(title: String, work: @escaping JobWork) {
        let job = Job(id: UUID(), title: title, state: .waiting)
        jobs = jobs + [job]
        let previous = tail
        let task = Task { [weak self] in
            await previous?.value
            await self?.run(job, work: work)
        }
        tasks[job.id] = task
        tail = task
    }

    private func run(_ job: Job, work: JobWork) async {
        defer { tasks[job.id] = nil }
        guard !Task.isCancelled else {
            update(job.id, to: .cancelled)
            return
        }
        update(job.id, to: .running(fraction: 0))
        do {
            let output = try await work { [weak self] fraction in
                Task { @MainActor in self?.reportProgress(job.id, fraction) }
            }
            update(job.id, to: .finished(output))
        } catch .cancelled {
            update(job.id, to: .cancelled)
        } catch {
            logger.error("\(job.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            update(job.id, to: .failed(error.localizedDescription))
        }
    }

    /// Progress can arrive after the job finished, and out of order, so only
    /// running jobs move and the bar never goes backwards.
    private func reportProgress(_ id: UUID, _ fraction: Double) {
        guard case .running(let current) = jobs.first(where: { $0.id == id })?.state, fraction > current else { return }
        update(id, to: .running(fraction: fraction))
    }

    private func update(_ id: UUID, to state: Job.State) {
        jobs = jobs.map { $0.id == id ? $0.with(state) : $0 }
    }
}
