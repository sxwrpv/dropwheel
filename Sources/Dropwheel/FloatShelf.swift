import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where the shelf sits on screen.
enum ShelfEdge: String, CaseIterable, Identifiable {
    case free
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Don’t pin"
        case .left: "Pin to left edge"
        case .right: "Pin to right edge"
        }
    }
}

/// One file on the shelf. The icon is loaded once, not on every redraw.
struct ShelfEntry: Identifiable {
    /// Standardised path, so a folder dropped twice is recognised as one item.
    let id: String
    let url: URL
    let icon: NSImage
}

/// Files held on the shelf, in the order they were added.
@MainActor
final class ShelfModel: ObservableObject {
    @Published private(set) var entries: [ShelfEntry] = []
    @Published var edge: ShelfEdge = .free

    func adding(_ urls: [URL]) {
        var known = Set(entries.map(\.id))
        let fresh = urls.compactMap { url -> ShelfEntry? in
            let path = url.standardizedFileURL.path
            guard known.insert(path).inserted else { return nil }
            return ShelfEntry(id: path, url: URL(fileURLWithPath: path),
                              icon: NSWorkspace.shared.icon(forFile: path))
        }
        entries = entries + fresh
    }

    func removing(_ entry: ShelfEntry) {
        entries = entries.filter { $0.id != entry.id }
    }

    /// Drops entries whose files were moved or deleted since they were shelved.
    func pruningMissing() {
        let fileManager = FileManager.default
        let present = entries.filter { fileManager.fileExists(atPath: $0.id) }
        if present.count != entries.count { entries = present }
    }

    func clear() {
        entries = []
    }
}

/// A floating shelf that holds files so they can be dragged into another app later.
@MainActor
final class FloatShelf {
    private static let size = NSSize(width: 260, height: 380)
    private static let edgeMargin: CGFloat = 12

    private let model = ShelfModel()
    private lazy var panel = makePanel()

    func add(_ urls: [URL]) {
        model.adding(urls)
        show()
    }

    func show() {
        model.pruningMissing()
        if !panel.isVisible {
            position(for: model.edge)
        }
        panel.orderFrontRegardless()
    }

    private func position(for edge: ShelfEdge) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = Self.size
        let y = visible.midY - size.height / 2
        let origin: NSPoint
        switch edge {
        case .left: origin = NSPoint(x: visible.minX + Self.edgeMargin, y: y)
        case .right: origin = NSPoint(x: visible.maxX - size.width - Self.edgeMargin, y: y)
        case .free:
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(x: min(max(mouse.x + 40, visible.minX), visible.maxX - size.width),
                             y: min(max(mouse.y - size.height / 2, visible.minY), visible.maxY - size.height))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.title = "Float"
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        let view = ShelfView(model: model) { [weak self] edge in
            self?.model.edge = edge
            self?.position(for: edge)
        }
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }
}

private struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    let onPin: (ShelfEdge) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if model.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.entries) { entry in
                            ShelfTile(entry: entry) { model.removing(entry) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted, perform: acceptDrop)
    }

    private var header: some View {
        HStack {
            Text(model.entries.count == 1 ? "1 item" : "\(model.entries.count) items")
                .font(.headline)
            Spacer()
            Menu {
                ForEach(ShelfEdge.allCases) { edge in
                    Button {
                        onPin(edge)
                    } label: {
                        if edge == model.edge {
                            Label(edge.title, systemImage: "checkmark")
                        } else {
                            Text(edge.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "pin")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pin the shelf to a screen edge")
            Button("Clear", action: model.clear)
                .disabled(model.entries.isEmpty)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Drop files here, then drag them into any app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        let model = self.model
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in model.adding([url]) }
            }
        }
        return !fileProviders.isEmpty
    }
}

private struct ShelfTile: View {
    let entry: ShelfEntry
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: entry.icon)
                .resizable()
                .frame(width: 32, height: 32)
            Text(entry.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from shelf")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .onDrag { NSItemProvider(object: entry.url as NSURL) }
        .help(entry.id)
    }
}
