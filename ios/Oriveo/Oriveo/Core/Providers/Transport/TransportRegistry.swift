import Foundation

enum TransportRegistry {

    private static let strategies: [TransportKind: any TransportStrategy] = [
        .openaiChat: OpenAIChatStrategy(),
        .openaiResponses: OpenAIResponsesStrategy(),
        .anthropicMessages: AnthropicMessagesStrategy(),
        .geminiGenerate: GeminiGenerateStrategy(),
        .dashscopeNative: DashScopeNativeStrategy(),
        .openaiImages: OpenAIImagesStrategy(),
        .geminiImage: GeminiImageStrategy(),
        .qwenImage: QwenImageStrategy(),
        .grokImage: GrokImageStrategy(),
        .zhipuImage: ZhipuImageStrategy(),
        .anthropicFiles: AnthropicFilesStrategy(),
        .openaiFiles: OpenAIFilesStrategy(),
    ]

    static func getStrategy(
        for kindRaw: String?,
        modelID: String? = nil,
        providerKind: ProviderKind? = nil
    ) throws -> any TransportStrategy {
        let telemetryModelID = providerKind.map { $0.telemetryModelID(modelID) } ?? "unknown"
        guard let kindRaw = kindRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kindRaw.isEmpty else {
            throw UnsupportedTransportError(kind: "", modelID: modelID)
        }
        guard let kind = TransportKind(rawValue: kindRaw),
              let strategy = strategies[kind] else {
            throw UnsupportedTransportError(kind: kindRaw, modelID: modelID)
        }
        return strategy
    }

    static func strategy(for kind: TransportKind) -> any TransportStrategy {
        return strategies[kind]!
    }

    static func isSupported(kindRaw: String?) -> Bool {
        guard let kindRaw = kindRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kindRaw.isEmpty,
              let kind = TransportKind(rawValue: kindRaw) else { return false }
        return strategies[kind] != nil
    }
}
