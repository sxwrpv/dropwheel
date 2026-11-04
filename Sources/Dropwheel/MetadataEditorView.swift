import DropwheelCore
import DropwheelEngines
import SwiftUI

/// Edit Metadata: every field in a file, grouped by file, track and chapter.
/// Search them, change or remove any, or take out what the camera and
/// software recorded.
struct MetadataEditorView: View {
    private static let labelWidth: CGFloat = 170
    private static let searchWidth: CGFloat = 260
    private static let longestField = 5
    /// More than a row could show. A packet can hold whole pictures as text.
    private static let longestShownValue = 2_000

    let url: URL
    let onSave: (ToolOptions) -> Void
    let onCancel: () -> Void

    @State private var draft: MetadataDraft?
    @State private var problem: String?
    @State private var warning: String?
    @State private var search = ""

    private var format: FileFormat? { FileFormat(fileName: url.lastPathComponent) }

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            if let warning { EditorNote(text: warning) }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            // Return finishes typing in a field.
            EditorFooter(canSave: draft?.hasChanges == true, savesOnReturn: false, onCancel: onCancel, onSave: save) {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .task { await load() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search fields", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.searchWidth)
            Spacer()
            Button("Remove Camera and Processing Data") { draft = draft?.removingCameraData() }
                .help("Takes out the device, software, dates and location the file recorded by itself")
                .disabled(draft?.hasCameraData != true)
        }
    }

    @ViewBuilder private var content: some View {
        if let draft {
            let groups = format.map { draft.shownGroups(matching: search, format: $0) } ?? []
            if groups.isEmpty {
                Text("No fields match “\(search)”").foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            if group.fields.isEmpty {
                                Text("No fields").foregroundStyle(.tertiary)
                            }
                            ForEach(group.fields) { row(for: $0, in: draft) }
                        } header: {
                            header(for: group, in: draft)
                        }
                    }
                }
                .listStyle(.inset)
            }
        } else if let problem {
            ContentUnavailableNote(text: problem)
        } else {
            ProgressView("Reading \(url.lastPathComponent)…")
        }
    }

    private func header(for group: MetadataGroup, in draft: MetadataDraft) -> some View {
        HStack {
            Text(group.title)
            Spacer()
            let keys = format.map { draft.addableKeys(to: group.scope, format: $0) } ?? []
            if !keys.isEmpty {
                Menu("Add Field") {
                    ForEach(keys, id: \.self) { key in
                        Button(MetadataRules.label(for: key)) { self.draft = self.draft?.adding(key: key, to: group.scope) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func row(for field: MetadataField, in draft: MetadataDraft) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(field.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.labelWidth, alignment: .trailing)
                .help(field.key)
            if draft.isRemoved(field) {
                Text(field.value.prefix(Self.longestShownValue)).strikethrough().foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                Button("Restore") { self.draft = self.draft?.restoring(field) }
                    .buttonStyle(.link)
            } else if draft.canEdit(field) {
                TextField(field.label, text: binding(for: field), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...Self.longestField)
                removeButton(for: field)
            } else {
                Text(field.value.prefix(Self.longestShownValue))
                    .foregroundStyle(field.isKept ? .primary : .tertiary)
                    .lineLimit(Self.longestField)
                    .textSelection(.enabled)
                Spacer()
                if !field.isKept {
                    Text("Not kept in a copy").font(.callout).foregroundStyle(.tertiary)
                } else if draft.canRemove(field) {
                    removeButton(for: field)
                }
            }
        }
    }

    private func removeButton(for field: MetadataField) -> some View {
        Button { draft = draft?.removing(field) } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove \(field.label)")
        .accessibilityLabel("Remove \(field.label)")
    }

    private func binding(for field: MetadataField) -> Binding<String> {
        Binding {
            draft?.value(of: field) ?? field.value
        } set: { value in
            draft = draft?.setting(value, for: field)
        }
    }

    private var summary: String {
        guard let draft else { return "" }
        var parts: [String] = []
        if draft.changedCount > 0 { parts.append("\(draft.changedCount) changed") }
        if draft.removedCount > 0 { parts.append("\(draft.removedCount) removed") }
        if format == .avif { parts.append("saving re-encodes the picture at high quality") }
        return parts.joined(separator: " · ")
    }

    private func save() {
        guard let draft else { return }
        onSave(.metadata(draft.recipe))
    }

    private func load() async {
        do {
            draft = MetadataDraft(report: try await MediaPreview.metadata(of: url))
            warning = await MediaPreview.copyWarning(for: url)
        } catch {
            problem = error.localizedDescription
        }
    }
}
