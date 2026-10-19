import Foundation
import OriveoProviderKit

/// Separator row shown after the message a checkpoint covers up to (P3·U4 contract item 1).
/// Only the latestValid row is ever presented; token counts are estimated at display time.
nonisolated struct ContextCompactionSeparator: Hashable, Sendable {
    typealias Kind = ContextCheckpointRecord.Kind

    var kind: Kind
    /// summary: messages covered; fallback: assistant replies dropped from the covered span.
    var count: Int
    /// Estimated tokens of the covered messages (summary only).
    var before: Int?
    /// Estimated tokens of the checkpoint as one message, same estimate as `before` (summary only).
    var after: Int?
    /// User messages kept verbatim.
    var kept: Int
    var model: String
    /// Message id the separator is attached after (record.coversTo).
    var anchorMessageId: String

    /// Builds the separator from the latestValid row; nil when there is no row or coversTo is not loaded.
    /// `modelName` maps the recorded model id to a display name; nil or blank keeps the id.
    static func make(
        latest: ContextCheckpointRecord?,
        messages: [ChatMessage],
        rhoHi: Double,
        modelName: (String) -> String? = { _ in nil }
    ) -> Self? {
        guard let latest,
              let anchor = messages.firstIndex(where: { $0.id.uuidString == latest.coversTo })
        else { return nil }
        let name = modelName(latest.model)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = name.isEmpty ? latest.model : name
        let start = max(0, anchor + 1 - max(0, latest.messagesCovered))
        let covered = messages[start...anchor]
        switch latest.kind {
        case .summary:
            return Self(
                kind: .summary,
                count: latest.messagesCovered,
                before: covered.reduce(0) { $0 + ContextBudget.estimateMessage($1.text, rhoHi: rhoHi) },
                after: ContextBudget.estimateMessage(latest.text, rhoHi: rhoHi),
                kept: latest.userMessageIds.count,
                model: model,
                anchorMessageId: latest.coversTo
            )
        case .fallback:
            return Self(
                kind: .fallback,
                count: covered.filter { $0.role == .assistant }.count,
                before: nil,
                after: nil,
                kept: latest.userMessageIds.count,
                model: model,
                anchorMessageId: latest.coversTo
            )
        }
    }

    /// Picks the latestValid row for the loaded messages and builds the separator from it.
    static func resolve(
        store: ContextCompactionStore,
        conversationId: String,
        messages: [ChatMessage],
        rhoHi: Double,
        modelName: (String) -> String? = { _ in nil }
    ) throws -> Self? {
        let history = messages.map { ContextCheckpoint.CoveredMessage(id: $0.id.uuidString, text: $0.text) }
        let latest = try store.latestValid(conversationId: conversationId, history: history)
        return make(latest: latest, messages: messages, rhoHi: rhoHi, modelName: modelName)
    }

    /// Display name from this device's model catalog: the provider's enabled models first, then the shared
    /// model lookup once it is built. Nil when neither knows the id.
    @MainActor
    static func modelNameLookup(in appState: AppState, providerID: UUID) -> @Sendable (String) -> String? {
        let models = appState.provider(for: providerID)?.models ?? []
        let lookupStore = appState.conversationModelLookupStore
        let lookup: ModelDisplayLookup? = lookupStore.isReady ? lookupStore.lookup : nil
        return { modelID in
            if let model = models.first(where: { $0.id == modelID }) {
                let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
            return lookup?.modelDisplayName(providerID: providerID, modelID: modelID)
        }
    }

    /// Separator for the transcript, fed the conversation's full history (same as latestValid, not the paged window).
    /// Store reads, latestValid and estimation run off the main actor; the main actor only hydrates message text
    /// (no file payloads) when the conversation has checkpoint rows. Nil when the calling task is cancelled.
    @MainActor
    static func current(in appState: AppState, conversationID: UUID?) async -> Self? {
        guard let conversationID,
              let store = ContextCompactionStore.forPartition(appState.sessionPartitionUID)
        else { return nil }
        let conversationKey = conversationID.uuidString
        let hasRows = await Task.detached(priority: .userInitiated) {
            !((try? store.list(conversationId: conversationKey)) ?? []).isEmpty
        }.value
        guard hasRows, !Task.isCancelled,
              appState.hydrateConversationMessagesIfNeeded(id: conversationID, hydrateFilePayloads: false),
              let conversation = appState.conversations.first(where: { $0.id == conversationID })
        else { return nil }
        let messages = conversation.messages
        let rhoHi = appState.chatManager.contextRhoHi(for: conversation)
        let modelName = modelNameLookup(in: appState, providerID: conversation.providerID)
        let separator = await Task.detached(priority: .userInitiated) {
            try? resolve(store: store, conversationId: conversationKey, messages: messages, rhoHi: rhoHi, modelName: modelName)
        }.value
        return Task.isCancelled ? nil : separator
    }

    /// Same compact notation as the token usage menu; shared table, always rounds down (P9·U3).
    @MainActor
    static func compactCount(_ value: Int, locale: Locale = AppLocalization.currentLocale) -> String {
        ContextCompactNumber.format(value, locale: locale.identifier)
    }
}

/// Read-only checkpoint detail (P3·U4 contract item 2).
nonisolated struct ContextCompactionDetail: Hashable, Sendable {
    enum Cost: Hashable, Sendable {
        /// Fallback rows never call a model.
        case noExtraCost
        /// Summary row without a recorded cost.
        case unavailable
        case amount(Double)
    }

    /// Present only when the row carries a non-empty summary.
    var summary: String?
    var kind: ContextCheckpointRecord.Kind
    var kept: Int
    var model: String
    var cost: Cost
    var createdAt: Date

    init(record: ContextCheckpointRecord) {
        let trimmed = record.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        summary = trimmed.isEmpty ? nil : record.summary
        kind = record.kind
        kept = record.userMessageIds.count
        model = record.model
        switch (record.kind, record.cost) {
        case (.fallback, _): cost = .noExtraCost
        case (.summary, nil): cost = .unavailable
        case (.summary, let value?): cost = .amount(value)
        }
        createdAt = Date(timeIntervalSince1970: Double(record.createdAt) / 1_000)
    }
}

/// Pending composer quote for "new chat with summary" (P3·U4 contract item 7).
nonisolated enum ContextCompactionQuote {
    static let paragraphSeparator = "\n\n"

    /// Picks the latestValid row for the loaded messages (same rule as the separator) and quotes it.
    static func resolve(
        store: ContextCompactionStore,
        conversationId: String,
        messages: [ChatMessage],
        label: String
    ) throws -> QuoteContext? {
        let history = messages.map { ContextCheckpoint.CoveredMessage(id: $0.id.uuidString, text: $0.text) }
        guard let latest = try store.latestValid(conversationId: conversationId, history: history) else { return nil }
        return make(record: latest, messages: messages, label: label)
    }

    /// Quotes the row's summary when non-empty, otherwise the kept user messages (time order, one paragraph each).
    /// leadingText + selectedText stays within `QuoteContext.maximumGraphemeCount`: the summary is cut at the tail;
    /// kept messages are dropped oldest first, and the last remaining one is cut at the tail.
    /// Nil when there is nothing to quote.
    static func make(record: ContextCheckpointRecord, messages: [ChatMessage], label: String) -> QuoteContext? {
        let budget = QuoteContext.maximumGraphemeCount - label.count
        guard budget > 0 else { return nil }
        var selected: String
        var truncated = false
        let summary = record.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty {
            selected = summary
        } else {
            let kept = Set(record.userMessageIds)
            var paragraphs = messages
                .filter { kept.contains($0.id.uuidString) }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            selected = paragraphs.joined(separator: paragraphSeparator)
            while paragraphs.count > 1, selected.count > budget {
                paragraphs.removeFirst()
                truncated = true
                selected = paragraphs.joined(separator: paragraphSeparator)
            }
        }
        if selected.count > budget {
            selected = String(selected.prefix(budget))
            truncated = true
        }
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return QuoteContext(
            sourceMessageId: record.coversTo,
            sourceRole: .assistant,
            contentKind: .prose,
            leadingText: label,
            selectedText: selected,
            trailingText: "",
            contextTruncated: truncated
        )
    }
}
