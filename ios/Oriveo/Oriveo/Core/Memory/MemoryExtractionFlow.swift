import Foundation
import Observation
import OriveoProviderKit

/// Pre-execution disclosure for memory drafting / organizing.
/// First works out the provider + model + scope to send to and attaches a pending disclosure; no request is sent before [Send] is tapped,
/// sending uses only the one provider + model shown in the box, and on failure the next candidate is not tried. The step that actually sends the request can be replaced by a stub.
struct MemoryExtractionDisclosure: Equatable {
    let title: String
    /// Three lines of body: who it is sent to (provider · model), the scope sent, and that a failure does not switch providers.
    let message: String
}

@MainActor
@Observable
final class MemoryExtractionFlow {
    typealias Candidate = (provider: Provider, model: AIModel)
    /// Sends one request and returns the full model reply.
    typealias Send = @MainActor (Provider, AIModel, PlannedChatRequest) async throws -> String

    enum DraftPreparation: Equatable {
        /// No usable model: no disclosure is shown, and the caller shows the existing "no provider / no model" error.
        case noModel
        /// The selected provider has no user messages: no disclosure is shown, and the caller shows the existing "not enough conversation" error.
        case notEnough
        /// The disclosure is attached and waiting for the user to confirm.
        case awaitingConfirmation
    }

    enum OrganizePreparation: Equatable {
        /// No usable model: no disclosure is shown, and the caller shows the no_model state of organizing.
        case noModel
        /// The disclosure is attached and waiting for the user to confirm.
        case awaitingConfirmation
    }

    enum Outcome: Equatable {
        case draft(String)
        case failed(title: String, message: String)
        /// Organizing is confirmed: only now does the caller open the organize sheet, and it requests with only this one provider + model.
        case organize(item: MemoryItem, provider: Provider, model: AIModel)
    }

    private enum Pending {
        case draft(candidate: Candidate, request: PlannedChatRequest)
        case organize(candidate: Candidate, item: MemoryItem)
    }

    /// The disclosure currently to show; nil = no request is awaiting confirmation.
    private(set) var disclosure: MemoryExtractionDisclosure?
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private let send: Send

    init(send: @escaping Send = MemoryExtractionFlow.liveSend) {
        self.send = send
    }

    // MARK: Drafting

    /// Takes the first candidate and picks only that provider's user messages; the disclosure is attached only when there is content.
    func prepareDraft(conversations: [Conversation], candidates: [Candidate]) -> DraftPreparation {
        pending = nil
        disclosure = nil
        guard let candidate = candidates.first else { return .noModel }
        let excerpts = MemoryView.buildExcerpts(from: conversations, providerID: candidate.provider.id)
        guard !excerpts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .notEnough }
        let request = MemoryView.draftRequest(
            excerpts: excerpts,
            providerKind: candidate.provider.kind,
            providerName: candidate.provider.displayName,
            model: candidate.model
        )
        pending = .draft(candidate: candidate, request: request)
        disclosure = MemoryExtractionDisclosure(
            title: L10n.tr("memory_extraction_title_draft", table: .chat),
            message: Self.disclosureMessage(
                candidate: candidate,
                scope: L10n.tr("memory_extraction_scope_draft", table: .chat)
            )
        )
        return .awaitingConfirmation
    }

    // MARK: Organizing

    /// Takes the first candidate and attaches the disclosure; the request is sent by the organize sheet after confirmation.
    func prepareOrganize(item: MemoryItem, candidates: [Candidate]) -> OrganizePreparation {
        pending = nil
        disclosure = nil
        guard let candidate = candidates.first else { return .noModel }
        pending = .organize(candidate: candidate, item: item)
        disclosure = MemoryExtractionDisclosure(
            title: L10n.tr("memory_extraction_title_organize", table: .chat),
            message: Self.disclosureMessage(
                candidate: candidate,
                scope: L10n.tr("memory_extraction_scope_organize", table: .chat)
            )
        )
        return .awaitingConfirmation
    }

    /// What is awaiting confirmation is an organize (after confirmation this flow does not wait for the request, so the caller needs no drafting loading state).
    var isOrganizePending: Bool {
        if case .organize = pending { return true }
        return false
    }

    // MARK: Confirm / cancel

    /// Sends the one request awaiting confirmation; returns nil when no request is awaiting confirmation.
    func confirm() async -> Outcome? {
        guard let job = pending else { return nil }
        pending = nil
        disclosure = nil
        switch job {
        case let .draft(candidate, request):
            do {
                let text = try await send(candidate.provider, candidate.model, request)
                let draft = String(text.prefix(2000)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !draft.isEmpty else { return Self.draftFailure(ProviderServiceError.emptyResponse) }
                return .draft(draft)
            } catch {
                #if DEBUG
                print("[Memory draft] [\(candidate.provider.displayName)/\(candidate.model.name)] error: \(error)")
                #endif
                return Self.draftFailure(error)
            }
        case let .organize(candidate, item):
            return .organize(item: item, provider: candidate.provider, model: candidate.model)
        }
    }

    /// Sends nothing and returns to the state before the tap.
    func cancel() {
        pending = nil
        disclosure = nil
    }

    /// Only dismisses the disclosure box (the system writes isPresented back both before and after the button action); what happens to the pending request is decided by the button.
    func dismissDisclosure() {
        disclosure = nil
    }

    // MARK: Copy

    static func disclosureMessage(candidate: Candidate, scope: String) -> String {
        let model = String(
            format: L10n.tr("memory_extraction_model", table: .chat),
            candidate.provider.displayName,
            modelDisplayName(candidate.model.name)
        )
        return [model, scope, L10n.tr("memory_extraction_no_fallback", table: .chat)].joined(separator: "\n")
    }

    /// The same treatment as the home model capsule: strips the "provider: " prefix and a trailing " (free)".
    static func modelDisplayName(_ raw: String) -> String {
        var name = raw
        if let r = name.range(of: ": ") {
            let tail = name[r.upperBound...]
            if !tail.isEmpty { name = String(tail) }
        }
        if name.lowercased().hasSuffix(" (free)") {
            name = String(name.dropLast(" (free)".count))
        }
        return name
    }

    /// Drafting failed: the title is always the generic failure title (the same on all platforms); the body uses the provider's localized error detail,
    /// and when the error is not a provider error or has no detail it uses the generic failure text (not repeating the title).
    static func draftFailure(_ error: Error) -> Outcome {
        let title = L10n.tr("Generation failed, please write manually", table: .settings)
        let generic = L10n.tr("Please try again later or write manually.", table: .settings)
        guard let providerError = error as? ProviderServiceError else {
            return .failed(title: title, message: generic)
        }
        let detail = providerError.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(title: title, message: detail.isEmpty ? generic : detail)
    }

    // MARK: Real request

    /// The same entry point as chat sending: picks the service by (provider, model).
    static func liveSend(provider: Provider, model: AIModel, request: PlannedChatRequest) async throws -> String {
        let transport = request.transportInput(ChatRequestOptions())
        guard let result = try await ProviderServiceRouter.Services().sendMessage(
            provider: provider,
            model: model,
            transport: transport
        ) else {
            throw ProviderServiceError.invalidConfiguration(
                detail: "Provider kind \(provider.kind.rawValue) cannot generate memory drafts through BYOK provider services."
            )
        }
        return result.text
    }
}
