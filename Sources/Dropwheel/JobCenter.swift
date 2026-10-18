import DropwheelCore
import DropwheelEngines
import Foundation
import os

/// One conversion the user asked for.
struct ConversionJob: Identifiable, Equatable {
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
    let input: URL
    let target: FileFormat
    let state: State

    func with(_ state: State) -> ConversionJob {
        ConversionJob(id: id, input: input, target: target, state: state)
    }
}

/// Runs conversions one at a time, in the order they were dropped. Video
/// encodes use every core, so running several at once would only slow each down.
@MainActor
final class JobCenter: ObservableObject {
    @Published private(set) var jobs: [ConversionJob] = []

    private let service = ConversionService()
    private let logger = Logger(subsystem: "dev.dropwheel", category: "Jobs")
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// The most recently queued job; the next one waits for it.
    private var tail: Task<Void, Never>?

    var isBusy: Bool { jobs.contains { $0.state.isActive } }

    func convert(_ urls: [URL], to target: FileFormat) {
        let queued = urls.map { ConversionJob(id: UUID(), input: $0, target: target, state: .waiting) }
        jobs = jobs + queued
        for job in queued {
            let previous = tail
            let task = Task { [weak self] in
                await previous?.value
                await self?.run(job)
            }
            tasks[job.id] = task
            tail = task
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

    private func run(_ job: ConversionJob) async {
        defer { tasks[job.id] = nil }
        guard !Task.isCancelled else {
            update(job.id, to: .cancelled)
            return
        }
        update(job.id, to: .running(fraction: 0))
        do {
            let output = try await service.convert(job.input, to: job.target) { [weak self] fraction in
                Task { @MainActor in self?.reportProgress(job.id, fraction) }
            }
            update(job.id, to: .finished(output))
        } catch .cancelled {
            update(job.id, to: .cancelled)
        } catch {
            logger.error("Converting \(job.input.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            update(job.id, to: .failed(error.localizedDescription))
        }
    }

    /// Progress can arrive after the job finished, and out of order, so only
    /// running jobs move and the bar never goes backwards.
    private func reportProgress(_ id: UUID, _ fraction: Double) {
        guard case .running(let current) = jobs.first(where: { $0.id == id })?.state, fraction > current else { return }
        update(id, to: .running(fraction: fraction))
    }

    private func update(_ id: UUID, to state: ConversionJob.State) {
        jobs = jobs.map { $0.id == id ? $0.with(state) : $0 }
    }
}
