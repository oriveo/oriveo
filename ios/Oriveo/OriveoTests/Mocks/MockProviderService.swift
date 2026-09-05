import Foundation
@testable import Oriveo

// MARK: - MockProviderService

final class MockProviderService {

    // MARK: - syncProvider

    var syncProviderResult: Result<ProviderSyncResult, Error> = .success(
        ProviderSyncResult(models: [])
    )
    var syncProviderCallCount = 0
    var lastSyncAPIKey: String?

    func syncProvider(apiKey: String, preferredModelID: String?) async throws -> ProviderSyncResult {
        syncProviderCallCount += 1
        lastSyncAPIKey = apiKey
        return try syncProviderResult.get()
    }


    var sendMessageResult: Result<ProviderChatResult, Error> = .success(
        ProviderChatResult(text: "Mock reply", promptTokens: 10, completionTokens: 20, estimatedCost: 0.001)
    )
    var sendMessageCallCount = 0
    var lastSentMessages: [ChatMessage]?

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage]
    ) async throws -> ProviderChatResult {
        sendMessageCallCount += 1
        lastSentMessages = messages
        return try sendMessageResult.get()
    }


    var streamEvents: [StreamEvent] = [
        .delta("Hello"),
        .delta(" world"),
        .done(ProviderChatResult(text: "Hello world", promptTokens: 5, completionTokens: 10, estimatedCost: 0.0005))
    ]
    var streamError: Error?
    var sendMessageStreamCallCount = 0

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        sendMessageStreamCallCount += 1
        let events = streamEvents
        let error = streamError
        return AsyncThrowingStream { continuation in
            Task {
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }


    func reset() {
        syncProviderResult = .success(ProviderSyncResult(models: []))
        syncProviderCallCount = 0
        lastSyncAPIKey = nil
        sendMessageResult = .success(
            ProviderChatResult(text: "Mock reply", promptTokens: 10, completionTokens: 20, estimatedCost: 0.001)
        )
        sendMessageCallCount = 0
        lastSentMessages = nil
        streamEvents = [
            .delta("Hello"),
            .delta(" world"),
            .done(ProviderChatResult(text: "Hello world", promptTokens: 5, completionTokens: 10, estimatedCost: 0.0005))
        ]
        streamError = nil
        sendMessageStreamCallCount = 0
    }
}
