import Foundation
import OriveoProviderKit

/// Runs the one-off provider call behind a cross-check. It deliberately creates no conversation,
/// writes nothing to the database and does not go through `ChatManager`: the request is made
/// straight against the provider client and streamed into the sheet.
@MainActor
final class NoteAIManager {
    unowned private(set) var appState: AppState!
    private(set) var isBound = false

    func bind(to appState: AppState) {
        self.appState = appState
        isBound = true
    }

    enum CrosscheckError: LocalizedError {
        case noProviderService
        case noModel
        case unhandledToolCalls([ProviderToolCall])

        var errorDescription: String? {
            switch self {
            case .noProviderService:
                return L10n.tr("This provider is unavailable. Add a provider with your own key.", table: .notes)
            case .noModel:
                return L10n.tr("Select a second model to run the check.", table: .notes)
            case let .unhandledToolCalls(calls):
                let names = calls.map { $0.name.isEmpty ? "?" : $0.name }
                if names.count == 1 {
                    return String(
                        format: L10n.tr(
                            "The model tried to use a tool (\"%@\") that isn't available on this connection.",
                            table: .chat
                        ),
                        names[0]
                    )
                }
                return String(
                    format: L10n.tr(
                        "The model tried to use tools (%@) that aren't available on this connection.",
                        table: .chat
                    ),
                    names.joined(separator: ", ")
                )
            }
        }
    }

    /// Streams the second opinion chunk by chunk. Providers that do not stream emit nothing but a
    /// final result, so the `.done` text is used as a fallback.
    func crosscheck(
        prompt: String?,
        answer: String,
        model: CrosscheckModelOption
    ) throws -> AsyncThrowingStream<String, Error> {
        let messages = NoteCrosscheckBuilder.messages(prompt: prompt, answer: answer, model: model)

        guard let service = appState.providerManager.service(for: model.providerKind) else {
            throw CrosscheckError.noProviderService
        }

        let eventStream: AsyncThrowingStream<StreamEvent, Error>
        if model.providerKind == .relay,
           let custom = service as? CustomBaseURLProvider,
           let baseURL = model.baseURL {
            eventStream = custom.sendMessageStream(
                apiKey: model.apiKey,
                modelID: model.modelID,
                messages: messages,
                baseURL: baseURL
            )
        } else {
            eventStream = service.sendMessageStream(
                apiKey: model.apiKey,
                modelID: model.modelID,
                messages: messages
            )
        }

        return AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                var streamed = false
                do {
                    for try await event in eventStream {
                        switch event {
                        case .delta(let text):
                            if !text.isEmpty {
                                streamed = true
                                continuation.yield(text)
                            }
                        case .done(let result):
                            if !streamed, !result.text.isEmpty { continuation.yield(result.text) }
                        case let .toolCallDeltas(calls):
                            // A cross-check declares no tools, so a tool call means the model
                            // cannot answer the way it was asked to.
                            if !calls.isEmpty { throw CrosscheckError.unhandledToolCalls(calls) }
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
