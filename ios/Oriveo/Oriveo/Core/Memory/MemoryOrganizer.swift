import Foundation
import OriveoProviderKit

/// The result of one "organize into items" request.
enum MemoryOrganizeOutcome: Equatable, Sendable {
    /// No usable model: prompt the user to pick a default model first.
    case noModel
    /// The request failed or the reply was empty (the next candidate is not tried).
    case failed
    /// The model replied, but no items could be parsed.
    case empty
    case entries([MemoryOrganizeEntry])
}

/// Hands one memory to the default model to split into several: sends `MemoryItems.organizeRequest` (system + user),
/// and after collecting the full text calls `MemoryItems.organizeParse`. The candidate models are the same set as for "AI draft" (`MemoryView.draftCandidateModels`),
/// only the first candidate is used (the one named in the disclosure box); a failure or empty reply is .failed right away and no other provider is tried.
/// The step that actually sends the request can be replaced by a stub (tests never hit a real provider).
struct MemoryOrganizer {
    typealias Candidate = (provider: Provider, model: AIModel)
    /// Sends one request and returns the full model reply.
    typealias Send = @MainActor (Provider, AIModel, MemoryOrganizeRequest) async throws -> String

    let candidates: [Candidate]
    let send: Send

    init(candidates: [Candidate], send: @escaping Send = MemoryOrganizer.liveSend) {
        self.candidates = candidates
        self.send = send
    }

    init(providers: [Provider], lastUsedModelRef: LastUsedModelRef?, send: @escaping Send = MemoryOrganizer.liveSend) {
        self.init(
            candidates: MemoryView.draftCandidateModels(providers: providers, lastUsedModelRef: lastUsedModelRef),
            send: send
        )
    }

    func organize(content: String) async -> MemoryOrganizeOutcome {
        guard let candidate = candidates.first else { return .noModel }
        let request = MemoryItems.organizeRequest(content: content)
        if Task.isCancelled { return .failed }
        do {
            let text = try await send(candidate.provider, candidate.model, request)
            // An empty reply also counts as a failure and the next candidate is not tried (same as "AI draft")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failed }
            let entries = MemoryItems.organizeParse(text)
            return entries.isEmpty ? .empty : .entries(entries)
        } catch {
            #if DEBUG
            print("[Memory organize] [\(candidate.provider.displayName)/\(candidate.model.name)] error: \(error)")
            #endif
            return .failed
        }
    }

    // MARK: Real request

    /// purpose memoryExtraction: the organize system prompt goes into purposeSystem, and the user text is used as the message unchanged.
    static func plannedRequest(
        _ request: MemoryOrganizeRequest,
        provider: Provider,
        model: AIModel
    ) -> PlannedChatRequest {
        let history = request.messages.map { message in
            ChatMessage(
                id: UUID(),
                role: message.role == .user ? .user : .assistant,
                text: message.text,
                providerKind: provider.kind,
                providerName: provider.displayName,
                modelName: model.name,
                state: .delivered
            )
        }
        return ChatRequestBuilder.purposeRequest(
            purpose: .memoryExtraction,
            purposeSystem: request.system,
            history: history,
            window: ChatRequestBuilder.contextWindowInput(providerKind: provider.kind, model: model)
        )
    }

    /// The same entry point as "AI draft": picks the service by (provider, model).
    static func liveSend(provider: Provider, model: AIModel, request: MemoryOrganizeRequest) async throws -> String {
        let transport = plannedRequest(request, provider: provider, model: model).transportInput(ChatRequestOptions())
        guard let result = try await ProviderServiceRouter.Services().sendMessage(
            provider: provider,
            model: model,
            transport: transport
        ) else {
            throw ProviderServiceError.invalidConfiguration(
                detail: "Provider kind \(provider.kind.rawValue) cannot organize memory through BYOK provider services."
            )
        }
        return result.text
    }
}

/// Check state and saving of the organize result: everything is selected by default, and "keep the original item" is off by default.
nonisolated struct MemoryOrganizeSelection: Equatable, Sendable {
    let sourceId: String
    let entries: [MemoryOrganizeEntry]
    var selected: [Bool]
    var keepOriginal: Bool = false

    init(sourceId: String, entries: [MemoryOrganizeEntry]) {
        self.sourceId = sourceId
        self.entries = entries
        self.selected = Array(repeating: true, count: entries.count)
    }

    var chosen: [MemoryOrganizeEntry] {
        zip(entries, selected).filter(\.1).map(\.0)
    }

    var canSave: Bool { selected.contains(true) }

    /// Each checked entry creates one new item (source manual, kind taken from the parse result); when the original is not kept it is tombstoned. Returns the newly created items.
    @discardableResult
    func save(_ writer: MemoryItemWriter) throws -> [MemoryItem] {
        let created = try chosen.map { try writer.create(kind: $0.kind, content: $0.content) }
        if !keepOriginal {
            _ = try writer.remove(id: sourceId)
        }
        return created
    }
}
