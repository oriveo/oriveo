import Foundation
import Testing
@testable import Oriveo

nonisolated private func localEngineReleaseRuntimeTestsEnabled() -> Bool {
    ProcessInfo.processInfo.environment["ORIVEO_LOCAL_ENGINE_RUNTIME_E2E"] == "1"
}

nonisolated private func localEngineRuntimeVariableIsPresent(_ key: String) -> Bool {
    guard let value = ProcessInfo.processInfo.environment[key] else { return false }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Release qualification against real engines from the iOS Simulator test host.
/// Normal unit runs keep this suite disabled because it requires five externally managed services.
@Suite(
    "Local engine simulator release matrix",
    .serialized,
    .enabled(if: localEngineReleaseRuntimeTestsEnabled(), "requires the explicit five-engine runtime fixture")
)
struct LocalEngineReleaseRuntimeTests {
    @Test("Ollama catalog, probe, non-stream, stream, and cancellation")
    func ollama() async throws {
        try await verify(
            engine: .ollama,
            endpoint: try requiredURL(portVariable: "ORIVEO_RELEASE_OLLAMA_PORT", defaultPort: 11_435)
        )
    }

    @Test("LM Studio catalog, probe, non-stream, stream, and cancellation")
    func lmStudio() async throws {
        try await verify(
            engine: .lmstudio,
            endpoint: try requiredURL(portVariable: "ORIVEO_RELEASE_LMSTUDIO_PORT", defaultPort: 1_234)
        )
    }

    @Test("llama.cpp catalog, probe, non-stream, stream, and cancellation")
    func llamaCpp() async throws {
        try await verify(
            engine: .llamacpp,
            endpoint: try requiredURL(portVariable: "ORIVEO_RELEASE_LLAMACPP_PORT", defaultPort: 8_080)
        )
    }

    @Test(
        "vLLM catalog, probe, non-stream, stream, and cancellation",
        .enabled(
            if: localEngineRuntimeVariableIsPresent("ORIVEO_RELEASE_VLLM_PORT"),
            "requires an explicit vLLM runtime port"
        )
    )
    func vLLM() async throws {
        try await verify(
            engine: .vllm,
            endpoint: try requiredURL(portVariable: "ORIVEO_RELEASE_VLLM_PORT", defaultPort: 8_000)
        )
    }

    @Test(
        "Open WebUI trusted HTTPS bearer catalog, non-stream, stream, and cancellation",
        .enabled(
            if: localEngineRuntimeVariableIsPresent("ORIVEO_RELEASE_OPENWEBUI_URL")
                && localEngineRuntimeVariableIsPresent("ORIVEO_RELEASE_OPENWEBUI_KEY_URL"),
            "requires explicit trusted HTTPS service and credential URLs"
        )
    )
    func openWebUI() async throws {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = try #require(environment["ORIVEO_RELEASE_OPENWEBUI_URL"])
        let keyURL = try #require(environment["ORIVEO_RELEASE_OPENWEBUI_KEY_URL"])
        #expect(endpoint.lowercased().hasPrefix("https://"))
        #expect(keyURL.lowercased().hasPrefix("https://"))
        let apiKey = try await fetchRuntimeCredential(from: keyURL)
        #expect(!apiKey.isEmpty)
        try await verify(
            engine: .openwebui,
            endpoint: endpoint,
            securityMode: .remoteHTTPS,
            apiKey: apiKey
        )
    }

    private func fetchRuntimeCredential(from rawURL: String) async throws -> String {
        let url = try #require(URL(string: rawURL))
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect((200..<300).contains(http.statusCode))
        #expect(data.count <= 256)
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requiredURL(portVariable: String, defaultPort: Int) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let host = try #require(environment["ORIVEO_RELEASE_RUNTIME_HOST"])
        let port = Int(environment[portVariable] ?? "") ?? defaultPort
        return "http://\(host):\(port)"
    }

    private func verify(
        engine: LocalEngineKind,
        endpoint: String,
        securityMode: RelayConnectionSecurityMode = .localHTTP,
        apiKey: String = ""
    ) async throws {
        let connection = try await LocalEngineConnector.connect(
            engine: engine,
            endpoint: endpoint,
            securityMode: securityMode,
            apiKey: apiKey
        )
        #expect(connection.engine == engine)
        #expect(!connection.modelIDs.isEmpty)
        #expect(connection.modelIDs.contains(connection.selectedModelID))
        #expect(connection.endpoint == endpoint)

        let message = ChatMessage(
            id: UUID(),
            role: .user,
            text: "Reply with exactly OK.",
            providerKind: .relay,
            providerName: "Release runtime fixture",
            modelName: connection.selectedModelID,
            state: .delivered
        )
        let service = OpenAIService()
        let nonStreaming = try await service.sendMessage(
            apiKey: apiKey,
            modelID: connection.selectedModelID,
            messages: [message],
            baseURL: connection.apiBaseURL,
            relayRequested: connection.requested
        )
        #expect(!nonStreaming.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        var streamedText = ""
        for try await event in service.sendMessageStream(
            apiKey: apiKey,
            modelID: connection.selectedModelID,
            messages: [message],
            baseURL: connection.apiBaseURL,
            relayRequested: connection.requested
        ) {
            switch event {
            case .delta(let text): streamedText += text
            case .done: break
            case .reasoning, .imagePart, .citations, .toolCallDeltas: break
            }
        }
        #expect(!streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let cancellation = Task {
            let stream = service.sendMessageStream(
                apiKey: apiKey,
                modelID: connection.selectedModelID,
                messages: [ChatMessage(
                    id: UUID(),
                    role: .user,
                    text: "Count upward slowly from one to one thousand.",
                    providerKind: .relay,
                    providerName: "Release runtime fixture",
                    modelName: connection.selectedModelID,
                    state: .delivered
                )],
                baseURL: connection.apiBaseURL,
                relayRequested: connection.requested
            )
            for try await _ in stream {
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
        }
        await Task.yield()
        cancellation.cancel()
        switch await cancellation.result {
        case .failure(let error):
            #expect(error is CancellationError)
        case .success:
            Issue.record("the cancellation stream completed before cancellation was observed")
        }
    }
}
