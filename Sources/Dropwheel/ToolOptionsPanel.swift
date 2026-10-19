import AppKit
import DropwheelCore
import os
import SwiftUI

/// A small panel for tools that need a choice before they run. It opens
/// with sensible presets already selected, so Return runs the tool at once.
@MainActor
final class ToolOptionsPanel {
    private static let width: CGFloat = 340
    /// Each new panel opens a little lower and to the right of the last.
    private static let cascadeOffset: CGFloat = 24
    /// Every open panel stays until it is run or cancelled, so a second
    /// drop never discards the choice waiting in the first.
    private var panels: [UUID: NSPanel] = [:]
    private let logger = Logger(subsystem: "dev.dropwheel", category: "ToolOptions")

    /// `allowsSizeGoals` is false for selections, such as PDFs, that can
    /// only be compressed with presets.
    func present(tool: ToolKind, fileCount: Int, allowsSizeGoals: Bool, onRun: @escaping (ToolOptions) -> Void) {
        let id = UUID()
        let view = ToolOptionsView(
            tool: tool,
            fileCount: fileCount,
            allowsSizeGoals: allowsSizeGoals,
            onRun: { [weak self] options in
                self?.close(id)
                onRun(options)
            },
            onCancel: { [weak self] in self?.close(id) }
        )
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: hosting.fittingSize.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = tool.title
        panel.level = .floating
        // After a drop the frontmost app is still Finder, and since macOS 14
        // an app can't force itself active, so the panel must stay visible
        // while Dropwheel is in the background.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        let offset = Self.cascadeOffset * CGFloat(panels.count)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + offset, y: panel.frame.minY - offset))
        panels[id] = panel
        activateApp()
        panel.makeKeyAndOrderFront(nil)
        logger.debug("Options for \(tool.rawValue, privacy: .public) shown, \(self.panels.count) open")
    }

    private func close(_ id: UUID) {
        panels.removeValue(forKey: id)?.orderOut(nil)
    }

    private func activateApp() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct ToolOptionsView: View {
    private enum CompressMode: String, CaseIterable, Identifiable {
        case preset = "Preset"
        case size = "Target size"
        case percent = "Reduce by"

        var id: String { rawValue }
    }

    private enum SplitMode: String, CaseIterable, Identifiable {
        case parts = "Equal parts"
        case interval = "Every"

        var id: String { rawValue }
    }

    private static let bytesPerMegabyte = 1_000_000.0
    /// Anything larger is a typo; it also keeps the byte count well inside Int.
    private static let largestTargetMegabytes = 100_000.0

    let tool: ToolKind
    let fileCount: Int
    let allowsSizeGoals: Bool
    let onRun: (ToolOptions) -> Void
    let onCancel: () -> Void

    @State private var compressMode = CompressMode.preset
    @State private var level = CompressionLevel.balanced
    /// Kept as text and parsed on Run: a number-formatted field only commits
    /// on Return or loss of focus, so Run could otherwise see a stale value.
    @State private var targetText = "5"
    @State private var reducePercent = 50.0
    @State private var speed = 2.0
    @State private var splitMode = SplitMode.parts
    @State private var parts = 2
    @State private var minutes = 5
    @State private var layout = ChannelLayout.mono
    @State private var loudness = LoudnessTarget.podcast

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if fileCount > 1 {
                Text("Applies to each of the \(fileCount) files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            controls
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: { onRun(options) })
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    @ViewBuilder private var controls: some View {
        switch tool {
        case .compress: compressControls
        case .changeSpeed: speedControls
        case .splitVideo: splitControls
        case .audioChannels:
            Picker("Channels", selection: $layout) {
                ForEach(ChannelLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        case .normalizeVolume:
            Picker("Target", selection: $loudness) {
                ForEach(LoudnessTarget.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var compressControls: some View {
        if allowsSizeGoals {
            Picker("Compress by", selection: $compressMode) {
                ForEach(CompressMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        switch allowsSizeGoals ? compressMode : .preset {
        case .preset:
            Picker("Strength", selection: $level) {
                ForEach(CompressionLevel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        case .size:
            HStack {
                TextField("Size", text: $targetText)
                    .frame(width: 80)
                Text("MB or smaller")
            }
        case .percent:
            HStack {
                Slider(value: $reducePercent, in: 10...90, step: 5)
                Text("\(Int(reducePercent))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var speedControls: some View {
        Picker("Speed", selection: $speed) {
            ForEach(ToolOptions.speedChoices, id: \.self) { Text(MediaToolPlans.number($0) + "×").tag($0) }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private var splitControls: some View {
        Picker("Split", selection: $splitMode) {
            ForEach(SplitMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if splitMode == .parts {
            Stepper("\(parts) parts", value: $parts, in: 2...20)
        } else {
            Stepper("Every \(minutes) minute\(minutes == 1 ? "" : "s")", value: $minutes, in: 1...120)
        }
    }

    private var isValid: Bool {
        tool != .compress || !allowsSizeGoals || compressMode != .size || targetMegabytes != nil
    }

    /// The typed size, if it is a sensible positive number. Accepts a comma as the decimal mark.
    private var targetMegabytes: Double? {
        guard let value = Double(targetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0, value <= Self.largestTargetMegabytes else { return nil }
        return value
    }

    private var options: ToolOptions {
        switch tool {
        case .compress:
            switch allowsSizeGoals ? compressMode : .preset {
            case .preset: .compress(.level(level))
            case .size: .compress(.targetBytes(Int((targetMegabytes ?? 0) * Self.bytesPerMegabyte)))
            case .percent: .compress(.reducePercent(Int(reducePercent)))
            }
        case .changeSpeed: .speed(speed)
        case .splitVideo: splitMode == .parts ? .split(.equalParts(parts)) : .split(.everySeconds(minutes * 60))
        case .audioChannels: .channels(layout)
        case .normalizeVolume: .loudness(loudness)
        default: ToolOptions.default(for: tool)
        }
    }
}
