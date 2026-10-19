import Foundation

protocol ProviderServiceProtocol {

    func syncProvider(
        apiKey: String,
        preferredModelID: String?
    ) async throws -> ProviderSyncResult

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage]
    ) async throws -> ProviderChatResult

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<StreamEvent, Error>

    /// Non-streaming send with request options: systemPrompt and the like travel with the options, and every native call outside the wire layer goes through here.
    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        requestOptions: ChatRequestOptions
    ) async throws -> ProviderChatResult

    /// Streaming send with request options.
    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        requestOptions: ChatRequestOptions
    ) -> AsyncThrowingStream<StreamEvent, Error>
}

protocol CustomBaseURLProvider {
    func syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseURL: String
    ) async throws -> ProviderSyncResult

    func syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseURL: String,
        relayRequested: RelayRequestedConfig?
    ) async throws -> ProviderSyncResult

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String
    ) async throws -> ProviderChatResult

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String
    ) -> AsyncThrowingStream<StreamEvent, Error>

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String,
        requestOptions: ChatRequestOptions
    ) async throws -> ProviderChatResult

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String,
        requestOptions: ChatRequestOptions
    ) -> AsyncThrowingStream<StreamEvent, Error>
}

extension CustomBaseURLProvider {
    func syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseURL: String,
        relayRequested: RelayRequestedConfig?
    ) async throws -> ProviderSyncResult {
        try await syncProvider(apiKey: apiKey, preferredModelID: preferredModelID, baseURL: baseURL)
    }
}

extension ProviderServiceProtocol {
    func syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseURL: String?,
        relayRequested: RelayRequestedConfig? = nil
    ) async throws -> ProviderSyncResult {
        guard let baseURL,
              let customProvider = self as? any CustomBaseURLProvider else {
            return try await syncProvider(
                apiKey: apiKey,
                preferredModelID: preferredModelID
            )
        }

        return try await customProvider.syncProvider(
            apiKey: apiKey,
            preferredModelID: preferredModelID,
            baseURL: baseURL,
            relayRequested: relayRequested
        )
    }

    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String?
    ) async throws -> ProviderChatResult {
        guard let baseURL,
              let customProvider = self as? any CustomBaseURLProvider else {
            return try await sendMessage(
                apiKey: apiKey,
                modelID: modelID,
                messages: messages
            )
        }

        return try await customProvider.sendMessage(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            baseURL: baseURL
        )
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        guard let baseURL,
              let customProvider = self as? any CustomBaseURLProvider else {
            return sendMessageStream(
                apiKey: apiKey,
                modelID: modelID,
                messages: messages
            )
        }

        return customProvider.sendMessageStream(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            baseURL: baseURL
        )
    }

    /// Forwarding with request options that picks a custom base URL by baseURL.
    func sendMessage(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String?,
        requestOptions: ChatRequestOptions
    ) async throws -> ProviderChatResult {
        guard let baseURL,
              let customProvider = self as? any CustomBaseURLProvider else {
            return try await sendMessage(
                apiKey: apiKey,
                modelID: modelID,
                messages: messages,
                requestOptions: requestOptions
            )
        }

        return try await customProvider.sendMessage(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            baseURL: baseURL,
            requestOptions: requestOptions
        )
    }

    func sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: [ChatMessage],
        baseURL: String?,
        requestOptions: ChatRequestOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        guard let baseURL,
              let customProvider = self as? any CustomBaseURLProvider else {
            return sendMessageStream(
                apiKey: apiKey,
                modelID: modelID,
                messages: messages,
                requestOptions: requestOptions
            )
        }

        return customProvider.sendMessageStream(
            apiKey: apiKey,
            modelID: modelID,
            messages: messages,
            baseURL: baseURL,
            requestOptions: requestOptions
        )
    }
}
