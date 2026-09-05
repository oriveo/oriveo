package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport
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

    fun declaredTransport(provider: Provider): String? = if (provider.kind == ProviderKind.Relay) {
        when (provider.relayRequested?.transport) {
            RelayTransport.OpenAIChatCompletions -> TransportKind.OpenAIChat.wireValue
            RelayTransport.OpenAIResponses -> TransportKind.OpenAIResponses.wireValue
            RelayTransport.AnthropicMessages -> TransportKind.AnthropicMessages.wireValue
            RelayTransport.GeminiGenerateContent -> TransportKind.GeminiGenerate.wireValue
            RelayTransport.Auto, RelayTransport.LlamaCppNative, null -> null
        }
    } else {
        catalogExternalTransport(provider)
    }

    fun hasNativeAdapter(provider: Provider): Boolean = declaredTransport(provider) in adapters

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
