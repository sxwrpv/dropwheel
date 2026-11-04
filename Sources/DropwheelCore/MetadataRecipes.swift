import Foundation

/// Where a field lives in a file.
public enum MetadataScope: Hashable, Sendable {
    case file
    case track(Int)
    case chapter(Int)
}

/// What can be done to a field.
public enum MetadataAccess: Sendable {
    case editable
    /// Can be taken out, but its value isn't plain text to retype.
    case removable
    /// Part of the file's structure, shown for information.
    case locked
}

public struct MetadataField: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        public let scope: MetadataScope
        public let key: String
    }

    public let scope: MetadataScope
    /// The name stored in the file.
    public let key: String
    public let value: String
    public let access: MetadataAccess
    /// False when no copy of this file can hold the field.
    public let isKept: Bool

    public init(scope: MetadataScope, key: String, value: String, access: MetadataAccess = .editable, isKept: Bool = true) {
        self.scope = scope
        self.key = key
        self.value = value
        self.access = access
        self.isKept = isKept
    }

    public var id: ID { ID(scope: scope, key: key) }
    public var label: String { MetadataRules.label(for: key) }
    public var isCameraOrProcessing: Bool { MetadataRules.isCameraOrProcessing(key) }

    /// Fields sorted for showing: what can be edited first, then by name.
    public static func sorted(_ fields: [MetadataField]) -> [MetadataField] {
        fields.sorted {
            let first = ($0.access == .locked ? 1 : 0, $0.label, $0.key)
            let second = ($1.access == .locked ? 1 : 0, $1.label, $1.key)
            return first < second
        }
    }
}

public struct MetadataGroup: Identifiable, Hashable, Sendable {
    public let scope: MetadataScope
    public let title: String
    public let fields: [MetadataField]
    /// False for a track no copy can carry.
    public let isKept: Bool

    public init(scope: MetadataScope, title: String, fields: [MetadataField], isKept: Bool = true) {
        self.scope = scope
        self.title = title
        self.fields = fields
        self.isKept = isKept
    }

    public var id: MetadataScope { scope }

    func replacing(fields: [MetadataField]) -> MetadataGroup {
        MetadataGroup(scope: scope, title: title, fields: fields, isKept: isKept)
    }
}

/// What a file holds.
public struct MetadataReport: Equatable, Sendable {
    public let groups: [MetadataGroup]
    /// The tracks a copy keeps, in order; a track's place here is its number in the copy.
    public let keptTracks: [Int]
    /// True for a file whose fields can't be changed at all.
    public let isReadOnly: Bool

    public init(groups: [MetadataGroup], keptTracks: [Int] = [], isReadOnly: Bool = false) {
        self.groups = groups
        self.keptTracks = keptTracks
        self.isReadOnly = isReadOnly
    }

    public var fields: [MetadataField] { groups.flatMap(\.fields) }

    /// The same place in a copy of the file, whose tracks are renumbered.
    func copyScope(of scope: MetadataScope) -> MetadataScope {
        guard case .track(let index) = scope, let number = keptTracks.firstIndex(of: index) else { return scope }
        return .track(number)
    }

    /// This report with every field that `copy` doesn't have marked as not
    /// kept. Chapters aren't compared, as a trial copy is too short to reach
    /// them, nor QuickTime keys, which are written back afterwards, nor what
    /// a format fills in by itself: a default left unsaid isn't a loss.
    public func markingLostFields(comparedTo copy: MetadataReport) -> MetadataReport {
        let marked = groups.map { group in
            group.replacing(fields: group.fields.map { field in
                if case .chapter = field.scope { return field }
                guard !MetadataRules.isQuickTimeKey(field.key), !MetadataRules.isRegenerated(field.key) else { return field }
                let isKept = field.isKept && copy.hasField(field.key, in: copyScope(of: field.scope))
                return MetadataField(scope: field.scope, key: field.key, value: field.value, access: field.access, isKept: isKept)
            })
        }
        return MetadataReport(groups: marked, keptTracks: keptTracks, isReadOnly: isReadOnly)
    }

    func field(_ key: String, in scope: MetadataScope) -> MetadataField? {
        fields.first { $0.scope == scope && $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    private func hasField(_ key: String, in scope: MetadataScope) -> Bool {
        field(key, in: scope) != nil
    }
}

/// One change to a field. A nil value removes it.
public struct MetadataChange: Hashable, Sendable {
    public let scope: MetadataScope
    public let key: String
    public let value: String?
    /// Nil for a new field.
    public let original: String?

    public init(scope: MetadataScope, key: String, value: String?, original: String?) {
        self.scope = scope
        self.key = key
        self.value = value
        self.original = original
    }
}

public struct MetadataRecipe: Equatable, Sendable {
    public let changes: [MetadataChange]

    public init(changes: [MetadataChange]) {
        self.changes = changes
    }
}

/// The edits made so far to a file's fields.
public struct MetadataDraft: Equatable, Sendable {
    public let report: MetadataReport
    private var typed: [MetadataField.ID: String] = [:]
    private var removed: Set<MetadataField.ID> = []
    private var added: [MetadataField] = []

    public init(report: MetadataReport) {
        self.report = report
    }

    public func value(of field: MetadataField) -> String {
        typed[field.id] ?? field.value
    }

    public func isRemoved(_ field: MetadataField) -> Bool {
        removed.contains(field.id)
    }

    public func canEdit(_ field: MetadataField) -> Bool {
        field.access == .editable && field.isKept
    }

    public func canRemove(_ field: MetadataField) -> Bool {
        field.access != .locked && field.isKept
    }

    /// Typing the original value back undoes the change.
    public func setting(_ value: String, for field: MetadataField) -> MetadataDraft {
        guard canEdit(field) else { return self }
        var copy = self
        copy.typed[field.id] = value == field.value ? nil : value
        return copy
    }

    /// A field added in this draft is simply forgotten.
    public func removing(_ field: MetadataField) -> MetadataDraft {
        var copy = self
        if added.contains(field) {
            copy.added = added.filter { $0 != field }
            copy.typed[field.id] = nil
        } else if canRemove(field) {
            copy.removed.insert(field.id)
        }
        return copy
    }

    public func restoring(_ field: MetadataField) -> MetadataDraft {
        var copy = self
        copy.removed.remove(field.id)
        return copy
    }

    /// A blank new field, unless the group has one by that name.
    public func adding(key: String, to scope: MetadataScope) -> MetadataDraft {
        guard !report.isReadOnly, !hasField(key, in: scope) else { return self }
        var copy = self
        copy.added = added + [MetadataField(scope: scope, key: key, value: "")]
        return copy
    }

    /// The fields a group could still be given.
    public func addableKeys(to scope: MetadataScope, format: FileFormat) -> [String] {
        report.isReadOnly ? [] : MetadataRules.addableKeys(for: format, scope: scope).filter { !hasField($0, in: scope) }
    }

    public var hasCameraData: Bool {
        report.fields.contains { $0.isCameraOrProcessing && canRemove($0) && !isRemoved($0) }
    }

    public func removingCameraData() -> MetadataDraft {
        var copy = self
        copy.removed.formUnion(report.fields.filter { $0.isCameraOrProcessing && canRemove($0) }.map(\.id))
        return copy
    }

    /// Groups with the fields matching `query` in a name, a value or the
    /// group's title. An empty query shows everything. The original value
    /// counts too, or a field found by it would vanish as it is retyped.
    public func groups(matching query: String) -> [MetadataGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return report.groups.compactMap { group in
            let fields = group.fields + added.filter { $0.scope == group.scope }
            if needle.isEmpty || group.title.localizedCaseInsensitiveContains(needle) {
                return group.replacing(fields: fields)
            }
            let matches = fields.filter { field in
                [field.label, field.key, field.value, value(of: field)].contains { $0.localizedCaseInsensitiveContains(needle) }
            }
            return matches.isEmpty ? nil : group.replacing(fields: matches)
        }
    }

    /// The groups worth showing. A track with no fields is only there to be
    /// added to, or as a warning that it won't reach a copy.
    public func shownGroups(matching query: String, format: FileFormat) -> [MetadataGroup] {
        groups(matching: query).filter { group in
            group.scope == .file || !group.fields.isEmpty || !group.isKept || !addableKeys(to: group.scope, format: format).isEmpty
        }
    }

    /// A field cleared of text counts as removed; a new one left blank doesn't count.
    public var recipe: MetadataRecipe {
        let existing = report.fields.compactMap { field -> MetadataChange? in
            if isRemoved(field) { return change(of: field, to: nil) }
            guard let value = typed[field.id] else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return change(of: field, to: text.isEmpty ? nil : text)
        }
        let new = added.compactMap { field -> MetadataChange? in
            let text = (typed[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : MetadataChange(scope: field.scope, key: field.key, value: text, original: nil)
        }
        return MetadataRecipe(changes: existing + new)
    }

    public var hasChanges: Bool { !recipe.changes.isEmpty }
    public var changedCount: Int { recipe.changes.filter { $0.value != nil }.count }
    public var removedCount: Int { recipe.changes.filter { $0.value == nil }.count }

    private func change(of field: MetadataField, to value: String?) -> MetadataChange {
        MetadataChange(scope: field.scope, key: field.key, value: value, original: field.value)
    }

    private func hasField(_ key: String, in scope: MetadataScope) -> Bool {
        report.field(key, in: scope) != nil
            || added.contains { $0.scope == scope && $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }
}
