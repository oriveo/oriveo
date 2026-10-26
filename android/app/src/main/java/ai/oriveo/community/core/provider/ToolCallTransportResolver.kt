package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.RelayFirstSendTransport
import ai.oriveo.community.core.provider.transport.TransportKind

/**
 * Tool adapters follow the protocol branch implemented by each Provider service. This mapping is
 * transport architecture, not a model-capability guess: capability still comes from catalog,
 * modelFacts, connection memory, or unknown.
 */
internal object ToolCallTransportResolver {
    private val adapters = setOf(
        TransportKind.OpenAIChat.wireValue,
        TransportKind.OpenAIResponses.wireValue,
        TransportKind.AnthropicMessages.wireValue,
        TransportKind.GeminiGenerate.wireValue,
    )

    /**
     * Relay: the protocol chosen by the model or connection; when both layers follow auto it falls back to the first-send protocol ([RelayFirstSendTransport.resolve], read the same way as the first chat send),
     * and no longer counts as having no adapter. The local native channel has no tool adapter, so it is null.
     */
    fun declaredTransport(provider: Provider, model: AIModel? = null): String? = if (provider.kind == ProviderKind.Relay) {
        when (RelayEndpointResolver.declaredTransport(provider, model) ?: RelayFirstSendTransport.resolve(provider, model)) {
            RelayTransport.OpenAIChatCompletions -> TransportKind.OpenAIChat.wireValue
            RelayTransport.OpenAIResponses -> TransportKind.OpenAIResponses.wireValue
            RelayTransport.AnthropicMessages -> TransportKind.AnthropicMessages.wireValue
            RelayTransport.GeminiGenerateContent -> TransportKind.GeminiGenerate.wireValue
            RelayTransport.Auto, RelayTransport.LlamaCppNative -> null
        }
    } else {
        catalogExternalTransport(provider)
    }

    fun hasNativeAdapter(provider: Provider, model: AIModel? = null): Boolean = declaredTransport(provider, model) in adapters

    fun catalogExternalTransport(provider: Provider): String? {
        CapabilityControlResolution.subscriptionFinalTransport(provider)?.let { return it }
        return when (provider.kind) {
            ProviderKind.OpenAI -> TransportKind.OpenAIResponses.wireValue
            ProviderKind.Anthropic -> TransportKind.AnthropicMessages.wireValue
            ProviderKind.Gemini -> TransportKind.GeminiGenerate.wireValue
            ProviderKind.DeepSeek,
            ProviderKind.Grok,
            ProviderKind.OpenRouter,
            ProviderKind.Groq,
            ProviderKind.Together,
            ProviderKind.Fireworks,
            ProviderKind.MiniMax,
            ProviderKind.Zhipu,
            ProviderKind.Qwen,
            ProviderKind.Moonshot,
            ProviderKind.Mistral,
            ProviderKind.SiliconFlow,
            -> TransportKind.OpenAIChat.wireValue
            else -> null
        }
    }
}
