import AppKit
import DropwheelCore
import SwiftUI

/// Opens one editing window per file for tools such as Crop and Trim.
/// Saving hands the chosen edit back, and the window closes.
@MainActor
final class EditorWindows {
    private static let defaultSize = NSSize(width: 760, height: 560)
    /// Photo editors have a side panel or toolbar, so they open larger.
    private static let photoEditorSize = NSSize(width: 960, height: 640)
    private static let minimumSize = NSSize(width: 520, height: 400)
    private static let cascadeOffset: CGFloat = 28

    private var windows: [UUID: NSWindow] = [:]
    private var closeObservers: [UUID: NSObjectProtocol] = [:]

    func open(tool: ToolKind, url: URL, onSave: @escaping (ToolOptions) -> Void) {
        let id = UUID()
        let isVideo = FileFormat(fileName: url.lastPathComponent)?.family == .video
        let save: (ToolOptions) -> Void = { [weak self] options in
            self?.close(id)
            onSave(options)
        }
        let cancel: () -> Void = { [weak self] in self?.close(id) }

        let content: AnyView
        switch tool {
        case .crop:
            content = AnyView(CropEditorView(url: url, isVideo: isVideo, onSave: save, onCancel: cancel))
        case .trim:
            content = AnyView(TrimEditorView(url: url, isVideo: isVideo, onSave: save, onCancel: cancel))
        case .editPhoto:
            content = AnyView(PhotoAdjustEditorView(url: url, onSave: save, onCancel: cancel))
        case .addBackground:
            content = AnyView(BackgroundEditorView(url: url, onSave: save, onCancel: cancel))
        case .annotate:
            content = AnyView(AnnotateEditorView(url: url, onSave: save, onCancel: cancel))
        case .redactPhoto:
            content = AnyView(RedactEditorView(url: url, onSave: save, onCancel: cancel))
        default:
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: tool == .crop || tool == .trim ? Self.defaultSize : Self.photoEditorSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(tool.title) — \(url.lastPathComponent)"
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        // After a drop Finder is still frontmost; the window must stay visible regardless.
        window.hidesOnDeactivate = false
        window.contentView = FirstClickHostingView(rootView: content)
        window.center()
        let offset = Self.cascadeOffset * CGFloat(windows.count)
        window.setFrameOrigin(NSPoint(x: window.frame.minX + offset, y: window.frame.minY - offset))
        windows[id] = window
        // The red close button must tear the editor down too, not just hide it.
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(id) }
        }
        activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    /// Removing the SwiftUI content ends its tasks and fires onDisappear,
    /// which stops playback and any preview work still running.
    private func close(_ id: UUID) {
        if let observer = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        guard let window = windows.removeValue(forKey: id) else { return }
        window.contentView = nil
        window.orderOut(nil)
    }

    private func activateApp() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Finder usually stays frontmost after a drop, so the editor may not be
/// the key window; the first click on a canvas should still draw or drag.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A small shared footer: what is being changed, plus Cancel and Save.
struct EditorFooter<Leading: View>: View {
    let canSave: Bool
    /// Off when the editor has a text field, where Return should finish typing, not save.
    var savesOnReturn = true
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(spacing: 12) {
            leading()
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save Copy", action: onSave)
                .keyboardShortcut(savesOnReturn ? .defaultAction : nil)
                .disabled(!canSave)
        }
    }
}
