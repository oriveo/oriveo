import Foundation


extension RecordMappers {

    // MARK: Record → Domain

    nonisolated static func note(from record: NoteRecord) -> Note? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        return Note(
            id: id,
            title: record.title,
            titleSource: NoteTitleSource(rawValue: record.titleSource) ?? .placeholder,
            body: record.body,
            bodySnapshot: record.bodySnapshot,
            userNote: record.userNote,
            tags: decodeTags(record.tagsJSON),
            noteFolderID: record.noteFolderID.flatMap(UUID.init(uuidString:)),
            sourceConversationId: record.sourceConversationId.flatMap(UUID.init(uuidString:)),
            sourceMessageId: record.sourceMessageId.flatMap(UUID.init(uuidString:)),
            sourceModelID: record.sourceModelID,
            sourceModelName: record.sourceModelName,
            sourceProviderKind: record.sourceProviderKind.flatMap(ProviderKind.init(rawValue:)),
            sourceProviderName: record.sourceProviderName,
            sourcePrompt: record.sourcePrompt,
            captureKind: NoteCaptureKind.decoded(record.captureKind),
            provenance: decodeProvenance(record.provenanceJSON),
            isPinned: record.isPinned,
            createdAt: Date(timeIntervalSince1970: record.createdAt),
            updatedAt: Date(timeIntervalSince1970: record.updatedAt),
            deletedAt: record.deletedAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    nonisolated static func noteSummary(from record: NoteRecord) -> NoteSummary? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        return NoteSummary(
            id: id,
            title: record.title,
            titleSource: NoteTitleSource(rawValue: record.titleSource) ?? .placeholder,
            body: record.body,
            tags: decodeTags(record.tagsJSON),
            noteFolderID: record.noteFolderID.flatMap(UUID.init(uuidString:)),
            sourceConversationId: record.sourceConversationId.flatMap(UUID.init(uuidString:)),
            sourceMessageId: record.sourceMessageId.flatMap(UUID.init(uuidString:)),
            sourceModelName: record.sourceModelName,
            sourceProviderKind: record.sourceProviderKind.flatMap(ProviderKind.init(rawValue:)),
            sourceProviderName: record.sourceProviderName,
            captureKind: NoteCaptureKind.decoded(record.captureKind),
            isPinned: record.isPinned,
            createdAt: Date(timeIntervalSince1970: record.createdAt),
            updatedAt: Date(timeIntervalSince1970: record.updatedAt),
            deletedAt: record.deletedAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    nonisolated static func noteFolder(from record: NoteFolderRecord) -> NoteFolder? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        return NoteFolder(
            id: id,
            name: record.name,
            sortOrder: record.sortOrder,
            colorTag: record.colorTag,
            createdAt: Date(timeIntervalSince1970: record.createdAt),
            updatedAt: Date(timeIntervalSince1970: record.updatedAt),
            deletedAt: record.deletedAt.map(Date.init(timeIntervalSince1970:))
        )
    }


    nonisolated static func decodeTags(_ raw: String?) -> [String] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    nonisolated static func encodeTags(_ tags: [String]) -> String {
        guard let data = try? JSONEncoder().encode(tags),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }


    nonisolated static func decodeProvenance(_ raw: String?) -> [ProvenanceEntry]? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ProvenanceEntry].self, from: data),
              !decoded.isEmpty
        else { return nil }
        return decoded
    }

    nonisolated static func encodeProvenance(_ provenance: [ProvenanceEntry]?) -> String? {
        guard let provenance, !provenance.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(provenance),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }


    nonisolated static func encodePinnedNoteIds(_ ids: [UUID]) -> String? {
        guard !ids.isEmpty else { return nil }
        let strings = ids.map { $0.uuidString }
        guard let data = try? JSONEncoder().encode(strings),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    nonisolated static func decodePinnedNoteIds(_ raw: String?) -> [UUID] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return strings.compactMap(UUID.init(uuidString:))
    }
}
