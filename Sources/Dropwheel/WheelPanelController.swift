import AppKit
import DropwheelCore

/// Shows the wheel in a borderless floating panel centred on the cursor.
@MainActor
final class WheelPanelController {
    /// Delay before hiding after the drag ends, so a drop on the wheel is
    /// delivered before the panel goes away.
    private static let hideDelay: Duration = .milliseconds(300)
    private static let fadeDuration: TimeInterval = 0.12

    var onDrop: ((WheelItem, [URL]) -> Void)? {
        didSet { wheelView.onDrop = onDrop }
    }

    private let wheelView = WheelView(frame: NSRect(x: 0, y: 0, width: WheelView.diameter, height: WheelView.diameter))
    private lazy var panel = makePanel()
    private var pendingHide: Task<Void, Never>?
    /// True from the first wheel of a drag until that drag ends. A new drag
    /// always re-centres the wheel, even if the last one is still fading out.
    private var isInDragSession = false

    func show(_ kind: WheelKind, keySymbol: String, items: [WheelItem], emptyMessage: String) {
        pendingHide?.cancel()
        pendingHide = nil
        wheelView.configure(kind: kind, keySymbol: keySymbol, items: items, emptyMessage: emptyMessage)
        guard !isInDragSession else { return }
        isInDragSession = true

        panel.setFrame(frameCentered(on: NSEvent.mouseLocation), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
    }

    func hideSoon() {
        isInDragSession = false
        pendingHide?.cancel()
        pendingHide = Task { [weak self] in
            try? await Task.sleep(for: Self.hideDelay)
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }

    private func frameCentered(on point: NSPoint) -> NSRect {
        let size = NSSize(width: WheelView.diameter, height: WheelView.diameter)
        var frame = NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                           width: size.width, height: size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        }
        return frame
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: wheelView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // A circular blurred backdrop behind the slices.
        let backdrop = NSVisualEffectView(frame: wheelView.frame)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.maskImage = Self.circleMask(diameter: WheelView.diameter)
        backdrop.addSubview(wheelView)
        panel.contentView = backdrop
        return panel
    }

    private static func circleMask(diameter: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}
