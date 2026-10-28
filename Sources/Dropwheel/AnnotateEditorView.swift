import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Annotate: draw arrows, boxes, circles, highlights, text, numbered
/// callouts and freehand lines on a picture.
struct AnnotateEditorView: View {
    private static let previewEdge = 1400
    /// Drags shorter than this (as a share of the picture) are treated as clicks.
    private static let smallestDrag = 0.005
    private static let lineWidthRange = 0.002...0.03

    private enum Tool: String, CaseIterable {
        case arrow, rectangle, ellipse, highlight, text, callout, pen

        var title: String {
            switch self {
            case .arrow: "Arrow"
            case .rectangle: "Box"
            case .ellipse: "Circle"
            case .highlight: "Highlight"
            case .text: "Text"
            case .callout: "Number"
            case .pen: "Pen"
            }
        }

        var symbolName: String {
            switch self {
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .highlight: "highlighter"
            case .text: "textformat"
            case .callout: "1.circle.fill"
            case .pen: "scribble"
            }
        }
    }

    let url: URL
    let onSave: (ToolOptions) -> Void
    let onCancel: () -> Void

    @State private var original: CGImage?
    @State private var rendered: CGImage?
    @State private var loadError: String?
    @State private var annotations: [Annotation] = []
    @State private var draft: Annotation?
    @State private var penPoints: [NormalizedPoint] = []
    @State private var tool = Tool.arrow
    @State private var color = RGBA.red.cgColor
    @State private var lineWidth = Annotation.defaultLineWidth
    @State private var text = "Text"

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            canvas
            EditorFooter(canSave: original != nil && !annotations.isEmpty, savesOnReturn: false, onCancel: onCancel,
                         onSave: { onSave(.annotations(annotations)) }) {
                HStack(spacing: 8) {
                    Button("Undo") { annotations = Array(annotations.dropLast()) }
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(annotations.isEmpty)
                    Button("Clear") { annotations = [] }
                        .disabled(annotations.isEmpty)
                }
            }
        }
        .padding(16)
        .task { await load() }
        .onChange(of: annotations) { _ in redraw() }
        .onChange(of: draft) { _ in redraw() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Tool", selection: $tool) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    Label(tool.title, systemImage: tool.symbolName).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ColorPicker("Colour", selection: $color, supportsOpacity: false).labelsHidden()
            Slider(value: $lineWidth, in: Self.lineWidthRange) { Text("Size") }
                .frame(width: 140)
            if tool == .text {
                TextField("Text to place", text: $text).frame(width: 160)
            }
        }
    }

    @ViewBuilder private var canvas: some View {
        if let image = rendered ?? original {
            PhotoCanvas(image: image, onDrag: dragged, onDragEnd: dragEnded) { _ in EmptyView() }
        } else if let loadError {
            ContentUnavailableNote(text: loadError)
        } else {
            ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Drawing

    private func dragged(from start: NormalizedPoint, to current: NormalizedPoint) {
        switch tool {
        case .arrow: draft = annotation(.arrow(from: start, to: current))
        case .rectangle: draft = annotation(.rectangle(from: start, to: current))
        case .ellipse: draft = annotation(.ellipse(from: start, to: current))
        case .highlight: draft = annotation(.highlight(from: start, to: current))
        case .pen:
            penPoints = (penPoints.isEmpty ? [start] : penPoints) + [current]
            draft = annotation(.freehand(penPoints))
        case .text, .callout:
            break
        }
    }

    private func dragEnded(from start: NormalizedPoint, to end: NormalizedPoint) {
        let moved = hypot(end.x - start.x, end.y - start.y) >= Self.smallestDrag
        let finished: Annotation? = switch tool {
        case .text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : annotation(.text(at: end, text))
        case .callout: annotation(.callout(at: end, number: nextCalloutNumber))
        case .pen: penPoints.count > 1 ? annotation(.freehand(penPoints + [end])) : nil
        case .arrow, .rectangle, .ellipse, .highlight: moved ? draft : nil
        }
        draft = nil
        penPoints = []
        if let finished { annotations = annotations + [finished] }
    }

    private var nextCalloutNumber: Int {
        annotations.filter { if case .callout = $0.shape { true } else { false } }.count + 1
    }

    private func annotation(_ shape: AnnotationShape) -> Annotation {
        Annotation(shape: shape, color: RGBA(color), lineWidth: lineWidth)
    }

    /// Annotations are simple to draw, so the preview redraws in step with the pointer.
    private func redraw() {
        guard let original else { return }
        rendered = try? PhotoRendering.annotated(original, annotations + (draft.map { [$0] } ?? []))
    }

    private func load() async {
        switch await PreviewImage.loadInBackground(url, maximumEdge: Self.previewEdge) {
        case .success(let loaded): original = loaded.image
        case .failure(let error): loadError = error.localizedDescription
        }
    }
}
