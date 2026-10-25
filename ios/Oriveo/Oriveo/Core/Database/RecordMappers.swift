import Foundation
import OriveoProviderKit

enum RecordMappers {
    /// The single entry point for every message sort. Swift's sort is not stable, so the input index is the
    /// fallback: two messages the comparator cannot order (both missing createdAt) keep their input order.
    nonisolated static func sortMessages<S: Sequence>(_ messages: S) -> [ChatMessage] where S.Element == ChatMessage {
        messages.enumerated()
            .sorted { lhs, rhs in
                if messageOrderPrecedes(lhs.element, rhs.element) { return true }
                if messageOrderPrecedes(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Message order: non-delivered messages always come after delivered ones; within a group the order key is (createdAt in milliseconds, roleRank, id).
    /// A message without createdAt (nil, or a millisecond value <= 0, e.g. from an old backup import) sorts before those with a time; two
    /// such messages do not lead each other, and `sortMessages` keeps their input order (no roleRank, no id comparison).
    /// roleRank: user=0 < assistant=1, so when the user and assistant messages of one turn are equal after millisecond truncation the user
    /// message always comes first, instead of the UUID string order deciding.
    /// Only for `sortMessages`: handing it straight to `sort(by:)` would lose the input order for messages without createdAt.
    nonisolated static func messageOrderPrecedes(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.state == .delivered && rhs.state != .delivered { return true }
        if lhs.state != .delivered && rhs.state == .delivered { return false }
        let lhsMillis = orderMillis(lhs)
        let rhsMillis = orderMillis(rhs)
        switch (lhsMillis, rhsMillis) {
        case (nil, nil): return false
        case (nil, _?): return true
        case (_?, nil): return false
        case let (l?, r?) where l != r: return l < r
        default: break
        }
        let lhsRank = roleRank(lhs.role)
        let rhsRank = roleRank(rhs.role)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.id.uuidString.uppercased() < rhs.id.uuidString.uppercased()
    }

    /// createdAt in milliseconds for ordering (truncated); missing (nil or <= 0) -> nil.
    nonisolated private static func orderMillis(_ message: ChatMessage) -> Int64? {
        guard let createdAt = message.createdAt else { return nil }
        let millis = Int64((createdAt.timeIntervalSince1970 * 1000).rounded(.down))
        return millis > 0 ? millis : nil
    }

    nonisolated private static func roleRank(_ role: ChatRole) -> Int {
        switch role {
        case .user: return 0
        case .assistant: return 1
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

        var summary = ConversationSummary(
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
            pinnedNoteIds: RecordMappers.decodePinnedNoteIds(record.pinnedNoteIds),
            instructions: record.instructions,
            contextCap: record.contextCap
        )
        summary.nonUsdCostTotals = decodeNonUsdCostTotals(record.nonUsdCostTotals)
        return summary
    }

    /// Storage shape of a conversation's non-USD totals: a JSON object (currency code -> amount); an empty table is stored as NULL.
    nonisolated static func encodeNonUsdCostTotals(_ totals: [String: Double]) -> String? {
        guard !totals.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: totals, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func decodeNonUsdCostTotals(_ raw: String?) -> [String: Double] {
        guard let data = raw?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return decoded
    }

    /// The three columns of a message's non-USD part -> a value; if any column is missing (or the source is not recognized) there is none.
    nonisolated static func nonUsdCost(currency: String?, amount: Double?, source: String?) -> NonUsdCost? {
        guard let currency, !currency.isEmpty, let amount,
              let costSource = source.flatMap(CostSource.init(rawValue:)) else { return nil }
        return NonUsdCost(currencyCode: currency, amount: amount, costSource: costSource)
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
        conversation.instructions = thread.summary.instructions
        conversation.contextCap = thread.summary.contextCap
        conversation.nonUsdCostTotals = thread.summary.nonUsdCostTotals
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
        let toolSteps = decodeToolSteps(record.toolSteps, messageState: state)

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
            toolSteps: toolSteps,
            stopReason: StopReason.fromStored(record.stopReason),
            memoryItemIds: decodeMemoryItemIds(record.memoryItemIds),
            createdAt: record.createdAt.map(Date.init(timeIntervalSince1970:)),
            inputTokens: record.inputTokens,
            outputTokens: record.outputTokens,
            cachedInputTokens: record.cachedInputTokens,
            cacheCreationInputTokens: record.cacheCreationInputTokens,
            cacheCreation5mTokens: record.cacheCreation5mTokens,
            cacheCreation1hTokens: record.cacheCreation1hTokens,
            costSource: record.costSource.flatMap(CostSource.init(rawValue:)),
            nonUsdCost: nonUsdCost(
                currency: record.nonUsdCostCurrency,
                amount: record.nonUsdCostAmount,
                source: record.nonUsdCostSource
            ),
            capabilityExecution: capabilityExecution,
            unhandledToolCalls: unhandledToolCalls,
            toolFallbackNotice: record.toolFallbackNotice,
            recoveryPrimaryAction: record.recoveryPrimaryAction
        )
    }

    /// A step still marked `running` on a message that is no longer generating (the process was killed
    /// mid-loop) is read back as `interrupted`. A generating message is returned untouched: a projection
    /// refresh inside the same process must not rewrite a step that is really running. After a kill the
    /// message itself leaves the generating state at launch, and the next read takes the first branch.
    nonisolated static func decodeToolSteps(_ raw: String?, messageState: ChatMessageState) -> [McpToolStep]? {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([McpToolStep].self, from: data),
              !decoded.isEmpty else { return nil }
        return messageState == .generating ? decoded : McpToolStep.interruptingRunning(decoded)
    }

    /// stopReason is stored as the raw fixture string; nil is stored as NULL.
    nonisolated static func encodeStopReason(_ reason: StopReason?) -> String? {
        reason?.rawValue
    }

    /// memoryItemIds is stored as a JSON array; an empty array is stored as NULL (device-local only).
    nonisolated static func encodeMemoryItemIds(_ ids: [String]) -> String? {
        guard !ids.isEmpty,
              let data = try? JSONEncoder().encode(ids),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    nonisolated static func decodeMemoryItemIds(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return decoded
    }

    nonisolated static func encodeToolSteps(_ steps: [McpToolStep]?) -> String? {
        guard let steps, !steps.isEmpty,
              let data = try? JSONEncoder().encode(steps),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
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

extension ContextBudgetCap {
    /// Storage form for a local text column / local preference (the shared `conversation-context-cap.v1.json` storageCases):
    /// accepts only "auto" / "unlimited" / an unsigned decimal integer with no spaces or leading zeros, which then goes through the budget cap rules; anything else returns nil (follow the global default).
    nonisolated init?(storageText text: String) {
        switch text {
        case "auto":
            self = .auto
        case "unlimited":
            self = .unlimited
        default:
            let scalars = text.unicodeScalars
            guard let first = scalars.first, ("1"..."9").contains(first),
                  scalars.allSatisfy({ ("0"..."9").contains($0) }),
                  let value = Int(text),
                  let cap = ContextBudgetCap.parse(value)
            else { return nil }
            self = cap
        }
    }

    /// The storage text; `ContextBudgetCap(storageText: cap.storageText) == cap`.
    nonisolated var storageText: String {
        switch self {
        case .auto: "auto"
        case .unlimited: "unlimited"
        case .custom(let tokens): String(tokens)
        }
    }
}
