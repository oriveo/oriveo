import Foundation

enum NoteSortKey: String, CaseIterable, Identifiable {
    case updatedAt
    case createdAt
    case sourceProviderKind

    var id: String { rawValue }
}

enum NoteFolderFilter: Hashable {
    case all
    case folder(UUID)
    case uncategorized
}

enum NoteTagChipVisualRole: Equatable, Sendable {
    case applied
    case suggestion
}

struct NoteTagChipPresentation: Equatable, Sendable {
    let visualRole: NoteTagChipVisualRole
    let showsRemoveAction: Bool

    static func applied(editable: Bool) -> Self {
        Self(visualRole: .applied, showsRemoveAction: editable)
    }

    static let suggestion = Self(visualRole: .suggestion, showsRemoveAction: false)
}

enum NoteListPresentation {

    static func sort(_ notes: [NoteSummary], by key: NoteSortKey) -> [NoteSummary] {
        notes.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            switch key {
            case .updatedAt:
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            case .createdAt:
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            case .sourceProviderKind:
                let pa = a.sourceProviderName ?? a.sourceProviderKind?.rawValue ?? ""
                let pb = b.sourceProviderName ?? b.sourceProviderKind?.rawValue ?? ""
                if pa != pb { return pa.localizedCaseInsensitiveCompare(pb) == .orderedAscending }
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    static func filterByFolder(_ notes: [NoteSummary], filter: NoteFolderFilter) -> [NoteSummary] {
        switch filter {
        case .all:
            return notes
        case .folder(let id):
            return notes.filter { $0.noteFolderID == id }
        case .uncategorized:
            return notes.filter { $0.noteFolderID == nil }
        }
    }

    static func filterByTags(_ notes: [NoteSummary], tags selected: Set<String>) -> [NoteSummary] {
        guard !selected.isEmpty else { return notes }
        return notes.filter { note in
            selected.allSatisfy { tag in note.tags.contains(tag) }
        }
    }

    static func allTags(in notes: [NoteSummary], limit: Int = 12) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for note in notes {
            for tag in note.tags where !seen.contains(tag) {
                seen.insert(tag)
                ordered.append(tag)
                if ordered.count >= limit { return ordered }
            }
        }
        return ordered
    }

    static func tagSuggestions(in notes: [NoteSummary], excluding existingTags: [String], limit: Int = 12) -> [String] {
        let existing = Set(existingTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        var seen = Set<String>()
        var ordered: [String] = []
        for note in notes {
            for rawTag in note.tags {
                let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = tag.lowercased()
                guard !tag.isEmpty, !existing.contains(key), !seen.contains(key) else { continue }
                seen.insert(key)
                ordered.append(tag)
                if ordered.count >= limit { return ordered }
            }
        }
        return ordered
    }

    static func uncategorizedCount(_ notes: [NoteSummary]) -> Int {
        notes.count { $0.noteFolderID == nil }
    }

    static func shouldShowUncategorizedFilter(uncategorizedCount: Int) -> Bool {
        true
    }
}
