import AppKit
import Combine
import SwiftUI

/// A small floating panel in the bottom-right corner listing conversions.
/// It appears when a job is queued and hides a few seconds after the last one ends.
@MainActor
final class JobPanel {
    private static let size = NSSize(width: 320, height: 220)
    private static let margin: CGFloat = 16
    private static let hideDelay: Duration = .seconds(5)

    private let center: JobCenter
    private lazy var panel = makePanel()
    private var subscription: AnyCancellable?
    private var pendingHide: Task<Void, Never>?

    init(center: JobCenter) {
        self.center = center
        subscription = center.$jobs
            .receive(on: RunLoop.main)
            .sink { [weak self] jobs in
                MainActor.assumeIsolated { self?.jobsChanged(jobs) }
            }
    }

    private func jobsChanged(_ jobs: [Job]) {
        guard !jobs.isEmpty else {
            panel.orderOut(nil)
            return
        }
        if jobs.contains(where: \.state.isActive) {
            pendingHide?.cancel()
            pendingHide = nil
            show()
        } else if pendingHide == nil {
            pendingHide = Task { [weak self] in
                try? await Task.sleep(for: Self.hideDelay)
                guard !Task.isCancelled else { return }
                self?.panel.orderOut(nil)
                self?.pendingHide = nil
            }
        }
    }

    private func show() {
        guard !panel.isVisible else { return }
        if let visible = NSScreen.main?.visibleFrame {
            let origin = NSPoint(x: visible.maxX - Self.size.width - Self.margin, y: visible.minY + Self.margin)
            panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.title = "Conversions"
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: JobListView(center: center))
        return panel
    }
}

private struct JobListView: View {
    @ObservedObject var center: JobCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Conversions").font(.headline)
                Spacer()
                Button("Clear", action: center.clearFinished)
                    .disabled(!center.jobs.contains { !$0.state.isActive })
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(center.jobs.reversed()) { job in
                        JobRow(job: job) { center.cancel(job.id) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct JobRow: View {
    let job: Job
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusIcon
                Text(job.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                trailingControl
            }
            detail
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trailingControl: some View {
        switch job.state {
        case .waiting, .running:
            Button(action: onCancel) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Cancel")
        case .finished(let output):
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                .controlSize(.small)
        case .failed, .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .waiting:
            Text("Waiting…").font(.caption).foregroundStyle(.secondary)
        case .running(let fraction):
            ProgressView(value: fraction).progressViewStyle(.linear)
        case .finished(let output):
            Text(output.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        }
    }
}
