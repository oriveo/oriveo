//  RelayRuntimeSupport.swift

import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum RelayRuntimeSupport {
    typealias AttachmentSupport = (image: Bool, nativeFile: Bool, textFileInline: Bool)

    /// Maps a relay transport to its runtime envelope key (aligned with the backend `transportEnvelopes` keys).
    /// The protocol is resolved per model (`RelayEndpointResolver.effectiveTransport`); without a model
    /// the connection default is used.
    static func envelopeKey(for provider: Provider, model: AIModel?) -> String? {
        guard provider.kind == .relay else { return nil }
        let transport = model.map { RelayEndpointResolver.effectiveTransport(provider: provider, model: $0) }
            ?? RelayEndpointResolver.connectionTransport(of: provider)
        return envelopeKey(transport: transport)
    }

    /// Maps an already decided transport to an envelope key, using the same mapping as `envelopeKey(for:model:)`.
    static func envelopeKey(transport: RelayTransport) -> String {
        switch transport {
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

    static func transportProviderKind(for provider: Provider, model: AIModel?) -> ProviderKind? {
        guard let key = envelopeKey(for: provider, model: model) else { return nil }
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        if let raw = runtime.transportRules[key]?.providerPriority,
           let kind = providerKindFromBackendKey(raw) {
            return kind
        }
        return nil
    }

    static func attachmentSupport(
        for provider: Provider,
        model: AIModel?,
        runtimeConfig: MetadataClient.RelayRuntimeConfig
    ) -> AttachmentSupport? {
        guard let key = envelopeKey(for: provider, model: model) else { return nil }
        guard let env = runtimeConfig.transportEnvelopes[key] else { return nil }
        return (image: env.image, nativeFile: env.nativeFile, textFileInline: env.textFileInline)
    }

    /// Reads the envelope flags for an already decided transport (used by the input capability projection; the final writer has no Provider at hand).
    static func inputEnvelope(
        transport: RelayTransport,
        runtimeConfig: MetadataClient.RelayRuntimeConfig
    ) -> AttachmentSupport? {
        guard let env = runtimeConfig.transportEnvelopes[envelopeKey(transport: transport)] else { return nil }
        return (image: env.image, nativeFile: env.nativeFile, textFileInline: env.textFileInline)
    }

    static func supportsWebSearch(
        for provider: Provider,
        model: AIModel?,
        runtimeConfig: MetadataClient.RelayRuntimeConfig
    ) -> Bool {
        guard let key = envelopeKey(for: provider, model: model) else { return false }
        return runtimeConfig.transportEnvelopes[key]?.webSearch ?? false
    }

    static func supportsImageGeneration(
        for provider: Provider,
        model: AIModel?,
        runtimeConfig: MetadataClient.RelayRuntimeConfig
    ) -> Bool {
        guard let key = envelopeKey(for: provider, model: model) else { return false }
        return runtimeConfig.transportEnvelopes[key]?.imageGeneration ?? false
    }

    static func supportsReasoning(
        for provider: Provider,
        model: AIModel?,
        runtimeConfig: MetadataClient.RelayRuntimeConfig
    ) -> Bool {
        guard let key = envelopeKey(for: provider, model: model) else { return false }
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

    /// Whether this relay message goes through image-generation dispatch: a model-level image-generation
    /// override (user / tested) takes precedence over the model's capabilities. `true` is treated as if
    /// the capabilities included image generation (existing errors apply when the route does not support
    /// it); `false` sends it as chat even if the capabilities include image generation.
    nonisolated static func dispatchesImageGeneration(model: AIModel) -> Bool {
        model.relayCapabilityOverrides?.imageGeneration ?? model.capabilities.contains(.imageGen)
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


    /// Built-in fallback value. The server delivers the current version under
    /// `transportRules.openai_responses.codexClientVersion`; this is used only when the delivered value is
    /// missing, invalid, or the runtime config has not loaded yet (see `resolvedCodexCliVersion`).
    nonisolated static let codexCliVersion = "0.162.1"

    /// A delivered value is accepted only if it matches `^\d{1,6}\.\d{1,6}\.\d{1,6}$` (ASCII digits);
    /// otherwise the built-in value is used. Checked byte by byte instead of with a regex: `$` would let a
    /// trailing newline through and `\d` would let non-ASCII digits through, and neither may end up in a header.
    nonisolated static func resolvedCodexCliVersion(delivered: String?) -> String {
        guard let delivered else { return codexCliVersion }
        let parts = delivered.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        let isValid = parts.count == 3 && parts.allSatisfy { part in
            (1...6).contains(part.count) && part.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        }
        return isValid ? delivered : codexCliVersion
    }
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
        let version = resolvedCodexCliVersion(
            delivered: MetadataClient.shared.syncRelayRuntimeConfig()
                .transportRules[MetadataClient.RelayTransportKey.openaiResponses]?.codexClientVersion
        )
        return "codex_cli_rs/\(version) (iOS \(systemVersion); arm64)"
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

    /// Codex identity headers for a relay request, gated on the resolved auth mode not being none. This is
    /// the single check shared by chat, ping and the library legs. An empty result means no identity
    /// headers are injected and the request body also omits `prompt_cache_key` (the two go together).
    static func codexIdentityHeaders(
        for transport: RelayTransport,
        relayRequested: RelayRequestedConfig?,
        resolvedAuthMode: RelayAuthMode
    ) -> [String: String] {
        guard resolvedAuthMode != .none else { return [:] }
        return codexIdentityHeaders(for: transport, codexCompatIdentity: relayRequested?.effectiveCodexCompatIdentity)
    }

    /// `prompt_cache_key` of a Responses request body (a public OpenAI Responses API parameter). Same
    /// algorithm on all platforms: the first 32 lowercase hex characters of
    /// SHA-256(model + "\n" + instructions + "\n" + firstUserText).
    ///
    /// Some Codex-style relays (observed with packyapi) check only whether this key is present in the body
    /// and answer 403 ("use the standard Codex client") without it, regardless of headers. Only the first
    /// user text is used, so the value stays the same for later turns of one conversation.
    nonisolated static func promptCacheKey(model: String, instructions: String, firstUserText: String) -> String {
        let digest = SHA256.hash(data: Data("\(model)\n\(instructions)\n\(firstUserText)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    enum RoutingError: Error, Equatable {
        case missingChatDriverModel
    }

    /// Multi-key: `currentKeyID` is the effective key of the image model and `keyID` returns the effective
    /// key of each model. A driver model bound to the same key is preferred; otherwise fall back to the
    /// plain rule (a key mismatch never blocks image generation). Callers pass nothing when the
    /// connection has a single key.
    static func pickChatDriverModelID(
        in provider: Provider,
        currentModel: AIModel,
        currentKeyID: String? = nil,
        keyID: ((AIModel) -> String?)? = nil
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
        if let currentKeyID, let keyID,
           let sameKey = provider.allModels.first(where: { acceptableChatDriver($0) && keyID($0) == currentKeyID }) {
            return .success(upstreamID(sameKey))
        }
        // A relay has no default model and the legacy isDefault flag is not read: take the first model in allModels order that can drive a chat.
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
