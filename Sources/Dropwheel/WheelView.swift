import AppKit
import DropwheelCore

/// Draws a wheel of slices and accepts file drops on them.
@MainActor
final class WheelView: NSView {
    static let diameter: CGFloat = 320
    private static let hubRadius: CGFloat = 62
    /// Slices start a little outside the hub, leaving a visible gap.
    private static let sliceInnerRadius: CGFloat = hubRadius + 4
    private static let outerRadius: CGFloat = 156
    private static let accent = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.96, alpha: 1)

    var onDrop: ((WheelItem, [URL]) -> Void)?

    private(set) var kind: WheelKind = .actions
    private var keySymbol = ""
    private var items: [WheelItem] = []
    private var hoveredIndex: Int? {
        didSet { if hoveredIndex != oldValue { needsDisplay = true } }
    }

    private var geometry: WheelGeometry {
        WheelGeometry(sliceCount: items.count, hubRadius: Self.sliceInnerRadius, outerRadius: Self.outerRadius)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(kind: WheelKind, keySymbol: String, items: [WheelItem]) {
        self.kind = kind
        self.keySymbol = keySymbol
        self.items = items
        hoveredIndex = nil
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        for index in items.indices {
            drawSlice(index, center: center)
        }
        drawHub(center: center)
    }

    private func drawSlice(_ index: Int, center: NSPoint) {
        let arc = geometry.appKitArcDegrees(of: index)
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: Self.outerRadius,
                       startAngle: arc.start, endAngle: arc.end, clockwise: true)
        path.appendArc(withCenter: center, radius: Self.sliceInnerRadius,
                       startAngle: arc.end, endAngle: arc.start, clockwise: false)
        path.close()

        let isHovered = index == hoveredIndex
        (isHovered ? Self.accent : NSColor.labelColor.withAlphaComponent(0.04)).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        drawLabel(for: items[index], index: index, center: center, isHovered: isHovered)
    }

    private func drawLabel(for item: WheelItem, index: Int, center: NSPoint, isHovered: Bool) {
        let radius = (Self.hubRadius + Self.outerRadius) / 2 + 4
        let offset = geometry.labelOffset(of: index, radius: radius)
        let labelCenter = NSPoint(x: center.x + offset.dx, y: center.y + offset.dy)
        let tint: NSColor = isHovered ? .white : .labelColor

        if let symbol = symbolImage(item.symbolName, tint: tint) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: labelCenter.x - size.width / 2, y: labelCenter.y + 2,
                                   width: size.width, height: size.height))
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: tint,
            .kern: 0.6,
        ]
        let text = NSAttributedString(string: item.label, attributes: attributes)
        let textSize = text.size()
        text.draw(at: NSPoint(x: labelCenter.x - textSize.width / 2, y: labelCenter.y - textSize.height - 2))
    }

    private func drawHub(center: NSPoint) {
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - Self.hubRadius, y: center.y - Self.hubRadius,
                                              width: Self.hubRadius * 2, height: Self.hubRadius * 2))
        NSColor.controlBackgroundColor.withAlphaComponent(0.85).setFill()
        hub.fill()
        NSColor.separatorColor.setStroke()
        hub.stroke()

        let heading = "\(keySymbol)  \(kind.title)"
        let detail: String
        if items.isEmpty {
            detail = "Coming soon"
        } else if let hoveredIndex {
            detail = items[hoveredIndex].title
        } else {
            detail = "Drop on a slice"
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let headingText = NSAttributedString(string: heading, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        let detailText = NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        let width = Self.hubRadius * 2 - 16
        headingText.draw(in: NSRect(x: center.x - width / 2, y: center.y + 4, width: width, height: 14))
        detailText.draw(in: NSRect(x: center.x - width / 2, y: center.y - 20, width: width, height: 34))
    }

    private func symbolImage(_ name: String, tint: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    // MARK: Dropping

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHover(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHover(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hoveredIndex = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hoveredIndex = nil }
        guard let index = sliceIndex(at: sender.draggingLocation) else { return false }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        // Act after the drag session has finished. Running modal UI (the
        // Move folder picker, alerts) inside this callback keeps the drag
        // source waiting.
        let item = items[index]
        let handler = onDrop
        Task { @MainActor in handler?(item, urls) }
        return true
    }

    private func updateHover(_ sender: NSDraggingInfo) -> NSDragOperation {
        hoveredIndex = sliceIndex(at: sender.draggingLocation)
        return hoveredIndex == nil ? [] : Self.acceptedOperation(for: sender.draggingSourceOperationMask)
    }

    /// Picks an operation the source allows. Holding a modifier changes
    /// Finder's mask, so `.copy` may be missing. Never `.move`: a source told
    /// the files moved may delete the originals.
    private static func acceptedOperation(for mask: NSDragOperation) -> NSDragOperation {
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        if mask.contains(.link) { return .link }
        return []
    }

    private func sliceIndex(at windowPoint: NSPoint) -> Int? {
        let point = convert(windowPoint, from: nil)
        let hit = geometry.hitTest(dx: point.x - bounds.midX, dy: point.y - bounds.midY)
        if case .slice(let index) = hit { return index }
        return nil
    }
}
