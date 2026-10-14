import Foundation

// MARK: - Enum UI labels (shared by manual setup, edit connection and the detail page)

func relayTransportLabel(_ t: RelayTransport) -> String {
    switch t {
    case .auto: return L10n.tr("Auto")
    case .openaiResponses: return L10n.tr("OpenAI Responses", table: .providers)
    case .openaiChatCompletions: return L10n.tr("OpenAI Chat Completions", table: .providers)
    case .llamacppNative: return L10n.tr("llama.cpp native completion", table: .providers)
    case .anthropicMessages: return L10n.tr("Anthropic Messages", table: .providers)
    case .geminiGenerateContent: return L10n.tr("Gemini generateContent", table: .providers)
    }
}

func relayAuthLabel(_ a: RelayAuthMode) -> String {
    switch a {
    case .auto: return L10n.tr("Auto")
    case .none: return L10n.tr("No authentication", table: .providers)
    case .bearer: return "Bearer"
    case .xApiKey: return "x-api-key"
    case .xGoogApiKey: return "x-goog-api-key"
    case .queryKey: return L10n.tr("Query key", table: .providers)
    }
}

// MARK: - Enum allUICases

extension RelayTransport {
    static var allUICases: [RelayTransport] {
        [.auto, .openaiResponses, .openaiChatCompletions, .anthropicMessages, .geminiGenerateContent]
    }
}

extension RelayAuthMode {
    static var allUICases: [RelayAuthMode] {
        [.auto, .none, .bearer, .xApiKey, .xGoogApiKey, .queryKey]
    }
}
