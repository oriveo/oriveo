import Foundation

enum RecordMappers {
    nonisolated static func sortMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.sorted { lhs, rhs in
            if lhs.state == .delivered && rhs.state != .delivered { return true }
            if lhs.state != .delivered && rhs.state == .delivered { return false }
            let lhsTime = lhs.createdAt ?? .distantPast
            let rhsTime = rhs.createdAt ?? .distantPast
            if lhsTime != rhsTime { return lhsTime < rhsTime }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    nonisolated static func summary(from record: ConversationRecord) -> ConversationSummary? {
        guard
            let id = UUID(uuidString: record.id),
            let providerID = UUID(uuidString: record.providerID),
            let providerKind = ProviderKind(rawValue: record.providerKind)
        else {
            return nil
        }

        return ConversationSummary(
            id: id,
            title: record.title,
            hasCustomTitle: record.hasCustomTitle,
            providerID: providerID,
            providerKind: providerKind,
            modelID: record.modelID,
            previewText: record.previewText,
            messageCount: record.messageCount,
            remoteMessageCount: record.remoteMessageCount,
            estimatedCost: record.estimatedCost,
            isDraft: record.isDraft,
            draftText: record.draftText,
            createdAt: Date(timeIntervalSince1970: record.createdAt),
            updatedAt: Date(timeIntervalSince1970: record.updatedAt),
            folderID: record.folderID.flatMap(UUID.init(uuidString:)),
            useMemory: record.useMemory,
            skillId: record.skillId.flatMap(UUID.init(uuidString:)),
            metadataUpdatedAt: record.metadataUpdatedAt.map(Date.init(timeIntervalSince1970:)),
            messagesHydratedAt: record.messagesHydratedAt.map(Date.init(timeIntervalSince1970:)),
            messagesStale: record.messagesStale,
            deletedAt: record.deletedAt.map(Date.init(timeIntervalSince1970:)),
            isConflictCopy: record.isConflictCopy,
            originalConversationId: record.originalConversationId.flatMap(UUID.init(uuidString:)),
            pinnedNoteIds: RecordMappers.decodePinnedNoteIds(record.pinnedNoteIds)
        )
    }

    nonisolated static func thread(
        from summary: ConversationSummary,
        messageRecords: [MessageRecord],
        attachmentRecordsByMessageID: [String: [AttachmentRecord]],
        hydrateFilePayloads: Bool,
        attachmentFileStore: AttachmentFileStore
    ) -> ConversationThread {
        let messages = messageRecords.compactMap { messageRecord in
            message(
                from: messageRecord,
                attachmentRecords: attachmentRecordsByMessageID[messageRecord.id] ?? [],
                hydrateFilePayloads: hydrateFilePayloads,
                attachmentFileStore: attachmentFileStore
            )
        }
        return ConversationThread(summary: summary, messages: messages)
    }

    nonisolated static func conversation(from thread: ConversationThread) -> Conversation {
        var conversation = Conversation(
            id: thread.summary.id,
            title: thread.summary.title,
            providerID: thread.summary.providerID,
            providerKind: thread.summary.providerKind,
            modelID: thread.summary.modelID,
            previewText: thread.summary.previewText,
            estimatedCost: thread.summary.estimatedCost,
            isDraft: thread.summary.isDraft,
            messages: thread.messages,
            draftText: thread.summary.draftText,
            createdAt: thread.summary.createdAt,
            updatedAt: thread.summary.updatedAt,
            folderID: thread.summary.folderID
        )
        conversation.hasCustomTitle = thread.summary.hasCustomTitle
        conversation.useMemory = thread.summary.useMemory
        conversation.skillId = thread.summary.skillId
        conversation.metadataUpdatedAt = thread.summary.metadataUpdatedAt
        conversation.messageCountOverride = max(thread.summary.messageCount, thread.summary.remoteMessageCount)
        conversation.deletedAt = thread.summary.deletedAt
        conversation.isConflictCopy = thread.summary.isConflictCopy
        conversation.originalConversationId = thread.summary.originalConversationId
        conversation.pinnedNoteIds = thread.summary.pinnedNoteIds
        return conversation
    }

    nonisolated static func message(
        from record: MessageRecord,
        attachmentRecords: [AttachmentRecord],
        hydrateFilePayloads: Bool,
        attachmentFileStore: AttachmentFileStore
    ) -> ChatMessage? {
        guard
            let id = UUID(uuidString: record.id),
            let role = ChatRole(rawValue: record.role),
            let providerKind = ProviderKind(rawValue: record.providerKind),
            let state = ChatMessageState(rawValue: record.state)
        else {
            return nil
        }

        let attachments = attachmentRecords.compactMap {
            attachment(
                from: $0,
                hydrateFilePayloads: hydrateFilePayloads,
                attachmentFileStore: attachmentFileStore
            )
        }

        let citations: [Citation]?
        if let raw = record.citations,
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Citation].self, from: data),
           !decoded.isEmpty {
            citations = decoded
        } else {
            citations = nil
        }

        let quoteContext = decodeQuoteContext(record.quoteContext)
        let capabilityExecution = decodeCapabilityExecution(record.capabilityExecution)
        let unhandledToolCalls = decodeUnhandledToolCalls(record.unhandledToolCalls)

        return ChatMessage(
            id: id,
            role: role,
            text: record.text,
            reasoningText: record.reasoningText,
            reasoningDurationMs: record.reasoningDurationMs,
            providerID: record.providerID.flatMap(UUID.init(uuidString:)),
            providerKind: providerKind,
            providerName: record.providerName,
            modelID: record.modelID,
            modelName: record.modelName,
            servedModelID: record.servedModelID,
            estimatedCost: record.estimatedCost,
            state: state,
            errorTitle: record.errorTitle,
            errorDetail: record.errorDetail,
            attachments: attachments.isEmpty ? nil : attachments,
            quoteContext: quoteContext,
            citations: citations,
            createdAt: record.createdAt.map(Date.init(timeIntervalSince1970:)),
            inputTokens: record.inputTokens,
            outputTokens: record.outputTokens,
            cachedInputTokens: record.cachedInputTokens,
            cacheCreationInputTokens: record.cacheCreationInputTokens,
            cacheCreation5mTokens: record.cacheCreation5mTokens,
            cacheCreation1hTokens: record.cacheCreation1hTokens,
            costSource: record.costSource.flatMap(CostSource.init(rawValue:)),
            capabilityExecution: capabilityExecution,
            unhandledToolCalls: unhandledToolCalls,
        )
    }

    nonisolated static func encodeCitations(_ citations: [Citation]?) -> String? {
        guard let citations, !citations.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(citations),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    nonisolated static func encodeCapabilityExecution(_ result: CapabilityExecutionResult?) -> String? {
        guard let result, !result.states.isEmpty,
              let data = try? JSONEncoder().encode(result) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func decodeCapabilityExecution(_ raw: String?) -> CapabilityExecutionResult? {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CapabilityExecutionResult.self, from: data),
              !decoded.states.isEmpty else { return nil }
        return decoded
    }

    nonisolated static func encodeUnhandledToolCalls(_ calls: [UnhandledToolCall]?) -> String? {
        guard let calls, !calls.isEmpty,
              let data = try? JSONEncoder().encode(calls) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func decodeUnhandledToolCalls(_ raw: String?) -> [UnhandledToolCall]? {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([UnhandledToolCall].self, from: data),
              !decoded.isEmpty else { return nil }
        return decoded
    }

    nonisolated static func encodeQuoteContext(_ quoteContext: QuoteContext?) -> String? {
        guard let quoteContext, quoteContext.isValid,
              let data = try? JSONEncoder().encode(quoteContext),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    nonisolated static func decodeQuoteContext(_ json: String?) -> QuoteContext? {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(QuoteContext.self, from: data),
              decoded.isValid else { return nil }
        return decoded
    }

    nonisolated static func attachment(
        from record: AttachmentRecord,
        hydrateFilePayloads: Bool,
        attachmentFileStore: AttachmentFileStore
    ) -> Attachment? {
        guard
            let id = UUID(uuidString: record.id),
            let kind = AttachmentKind(rawValue: record.kind)
        else {
            return nil
        }

        let base64Data: String?
        if hydrateFilePayloads, kind == .file, let localFileID = record.localFileID {
            base64Data = attachmentFileStore.loadBase64(for: localFileID)
        } else {
            base64Data = nil
        }

        let originalBase64Data: String?
        if hydrateFilePayloads, kind == .file, let originalFileID = record.originalFileID {
            originalBase64Data = attachmentFileStore.loadBase64(for: originalFileID)
        } else {
            originalBase64Data = nil
        }

        return Attachment(
            id: id,
            kind: kind,
            fileName: record.fileName,
            mimeType: record.mimeType,
            base64Data: base64Data,
            localImageID: record.localImageID,
            thumbnailBase64: record.thumbnailBase64,
            extractedTotalLines: record.extractedTotalLines,
            extractedTruncated: record.extractedTruncated,
            extractedSizeBytes: record.extractedSizeBytes,
            extractionErrorCode: record.extractionErrorCode,
            originalBase64Data: originalBase64Data
        )
    }
}
