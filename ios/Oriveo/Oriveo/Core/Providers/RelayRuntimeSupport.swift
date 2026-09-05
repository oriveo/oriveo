//  RelayRuntimeSupport.swift

import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum RelayRuntimeSupport {
    typealias AttachmentSupport = (image: Bool, video: Bool, nativeFile: Bool, textFileInline: Bool)

    static func envelopeKey(for provider: Provider) -> String? {
        guard provider.kind == .relay else { return nil }
        switch provider.relayRequested?.transport ?? .auto {
        case .auto:
            return MetadataClient.RelayTransportKey.openaiChatCompletions
        case .openaiResponses:
            return MetadataClient.RelayTransportKey.openaiResponses
        case .openaiChatCompletions:
            return MetadataClient.RelayTransportKey.openaiChatCompletions
        case .llamacppNative:
            return MetadataClient.RelayTransportKey.openaiChatCompletions
        case .anthropicMessages:
            return MetadataClient.RelayTransportKey.anthropicMessages
        case .geminiGenerateContent:
            return MetadataClient.RelayTransportKey.geminiGenerateContent
        }
    }

    static func transportProviderKind(for provider: Provider) -> ProviderKind? {
        guard let key = envelopeKey(for: provider) else { return nil }
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        if let raw = runtime.transportRules[key]?.providerPriority,
           let kind = providerKindFromBackendKey(raw) {
            return kind
        }
        return nil
    }

    static func attachmentSupport(
        for provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig
    ) -> AttachmentSupport? {
        guard let key = envelopeKey(for: provider) else { return nil }
        guard let env = runtimeConfig.transportEnvelopes[key] else { return nil }
        return (image: env.image, video: false, nativeFile: env.nativeFile, textFileInline: env.textFileInline)
    }

    static func supportsWebSearch(
        for provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig
    ) -> Bool {
        guard let key = envelopeKey(for: provider) else { return false }
        return runtimeConfig.transportEnvelopes[key]?.webSearch ?? false
    }

    static func supportsImageGeneration(
        for provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig
    ) -> Bool {
        guard let key = envelopeKey(for: provider) else { return false }
        return runtimeConfig.transportEnvelopes[key]?.imageGeneration ?? false
    }

    static func supportsReasoning(
        for provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig
    ) -> Bool {
        guard let key = envelopeKey(for: provider) else { return false }
        return runtimeConfig.transportEnvelopes[key]?.reasoning ?? false
    }


    static func envelopeCapabilities(
        transport: RelayTransport,
        runtimeConfig: MetadataClient.RelayRuntimeConfig
    ) -> [ModelCapability] {
        let key = transportEnvelopeKey(transport: transport)
        guard let key, let env = runtimeConfig.transportEnvelopes[key] else {
            return [.text]
        }
        var caps: [ModelCapability] = [.text]
        if env.image { caps.append(.image) }
        if env.nativeFile || env.textFileInline { caps.append(.file) }
        if env.webSearch { caps.append(.web) }
        if env.reasoning { caps.append(.reasoning) }
        return caps
    }

    private static func transportEnvelopeKey(transport: RelayTransport) -> String? {
        switch transport {
        case .auto: return nil
        case .openaiResponses: return MetadataClient.RelayTransportKey.openaiResponses
        case .openaiChatCompletions: return MetadataClient.RelayTransportKey.openaiChatCompletions
        case .llamacppNative: return nil
        case .anthropicMessages: return MetadataClient.RelayTransportKey.anthropicMessages
        case .geminiGenerateContent: return MetadataClient.RelayTransportKey.geminiGenerateContent
        }
    }


    enum ImageRoute: String, Equatable {
        case inlineResponsesTool
        case imagesEndpoint
        /// Gemini native modality(`responseModalities: ["TEXT","IMAGE"]`)
        case geminiModality
        case unsupported
    }

    static func imageRoute(for transport: RelayTransport) -> ImageRoute {
        let key = transport == .auto
            ? MetadataClient.RelayTransportKey.openaiChatCompletions
            : transportEnvelopeKey(transport: transport)
        if let key,
           let raw = MetadataClient.shared.syncRelayRuntimeConfig().transportRules[key]?.imageRoute,
           let route = imageRouteFromRuntime(raw) {
            return route
        }
        switch transport {
        case .openaiResponses: return .inlineResponsesTool
        case .openaiChatCompletions, .auto: return .imagesEndpoint
        case .geminiGenerateContent: return .geminiModality
        case .anthropicMessages: return .unsupported
        case .llamacppNative: return .unsupported
        }
    }


    static let codexCliVersion = "0.50.0"
    static let codexOriginator = "codex_cli_rs"
    static let codexOpenAIBeta = "responses=experimental"

    static var codexCliUserAgent: String {
        let systemVersion: String
        #if canImport(UIKit)
        systemVersion = UIDevice.current.systemVersion
        #else
        let os = ProcessInfo.processInfo.operatingSystemVersion
        systemVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #endif
        return "codex_cli_rs/\(codexCliVersion) (iOS \(systemVersion); arm64)"
    }

    static func codexIdentityHeaders(
        for transport: RelayTransport,
        codexCompatIdentity: Bool? = nil,
        sessionID: String = UUID().uuidString
    ) -> [String: String] {
        if codexCompatIdentity == false { return [:] }

        let key = transport == .auto
            ? MetadataClient.RelayTransportKey.openaiChatCompletions
            : transportEnvelopeKey(transport: transport)
        let enabled = key.flatMap {
            MetadataClient.shared.syncRelayRuntimeConfig().transportRules[$0]?.codexIdentityDefault
        } ?? (transport == .openaiResponses)
        if enabled {
            return [
                "User-Agent": codexCliUserAgent,
                "Originator": codexOriginator,
                "session_id": sessionID,
                "OpenAI-Beta": codexOpenAIBeta
            ]
        }
        return [:]
    }


    enum RoutingError: Error, Equatable {
        case missingChatDriverModel
    }

    static func pickChatDriverModelID(
        in provider: Provider,
        currentModel: AIModel
    ) -> Result<String, RoutingError> {
        func upstreamID(_ model: AIModel) -> String {
            ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind)
        }
        let currentUpstreamID = upstreamID(currentModel)
        if !isDedicatedImageModel(currentUpstreamID) {
            return .success(currentUpstreamID)
        }
        func acceptableChatDriver(_ model: AIModel) -> Bool {
            model.isAvailable
                && !isDedicatedImageModel(upstreamID(model))
                && !model.capabilities.contains(.imageGen)
        }
        if let def = provider.defaultModel, acceptableChatDriver(def) {
            return .success(upstreamID(def))
        }
        if let first = provider.allModels.first(where: acceptableChatDriver) {
            return .success(upstreamID(first))
        }
        return .failure(.missingChatDriverModel)
    }

    static func isDedicatedImageModel(_ modelID: String) -> Bool {
        let lower = modelID.lowercased()
        return lower.hasPrefix("gpt-image-") || lower.hasPrefix("chatgpt-image-")
    }


    static func shouldForceStream(
        transport: RelayTransport,
        capabilities: Set<ModelCapability>
    ) -> Bool {
        guard capabilities.contains(.imageGen) else { return false }
        let key = transport == .auto
            ? MetadataClient.RelayTransportKey.openaiChatCompletions
            : transportEnvelopeKey(transport: transport)
        if let key,
           let force = MetadataClient.shared.syncRelayRuntimeConfig().transportRules[key]?.forceStreamForImageGeneration {
            return force
        }
        return imageRoute(for: transport) == .inlineResponsesTool
    }

    private static func providerKindFromBackendKey(_ raw: String) -> ProviderKind? {
        switch raw {
        case "openAI": return .openAI
        case "anthropic": return .anthropic
        case "gemini": return .gemini
        case "deepseek": return .deepseek
        case "moonshot": return .moonshot
        case "miniMax": return .miniMax
        case "zhipu": return .zhipu
        case "qwen": return .qwen
        default: return nil
        }
    }

    private static func imageRouteFromRuntime(_ raw: String) -> ImageRoute? {
        switch raw {
        case "inline_responses_tool", "inlineResponsesTool": return .inlineResponsesTool
        case "images_endpoint", "imagesEndpoint": return .imagesEndpoint
        case "gemini_modality", "geminiModality": return .geminiModality
        case "unsupported": return .unsupported
        default: return nil
        }
    }
}

// MARK: - Transport Key Constants

extension MetadataClient {
    enum RelayTransportKey {
        static let openaiResponses = "openai_responses"
        static let openaiChatCompletions = "openai_chat_completions"
        static let anthropicMessages = "anthropic_messages"
        static let geminiGenerateContent = "gemini_generate_content"
    }
}
