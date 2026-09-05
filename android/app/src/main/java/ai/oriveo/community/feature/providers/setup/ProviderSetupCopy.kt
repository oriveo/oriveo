package ai.oriveo.community.feature.providers.setup

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ProviderKind


object ProviderSetupCopy {

    
    @StringRes
    fun endpointTitle(kind: ProviderKind): Int = R.string.official_endpoint

    
    @StringRes
    fun endpointDescription(kind: ProviderKind): Int? = when (kind) {
        ProviderKind.MiniMax -> R.string.provider_endpoint_minimax_description
        ProviderKind.Qwen -> R.string.provider_endpoint_qwen_description
        ProviderKind.Moonshot -> R.string.provider_endpoint_moonshot_description
        ProviderKind.SiliconFlow -> R.string.provider_endpoint_siliconflow_description
        else -> null
    }

    
    @StringRes
    fun autoFillNote(kind: ProviderKind): Int? = when (kind) {
        ProviderKind.Relay, ProviderKind.OpenAI -> null
        else -> R.string.auto_fill_note
    }

    
    fun shouldShowAutoFillNote(kind: ProviderKind): Boolean = autoFillNote(kind) != null

    
    @StringRes
    fun tagline(kind: ProviderKind): Int? = when (kind) {
        ProviderKind.OpenAI -> R.string.provider_tagline_openai
        ProviderKind.Anthropic -> R.string.provider_tagline_anthropic
        ProviderKind.Gemini -> R.string.provider_tagline_gemini
        ProviderKind.DeepSeek -> R.string.provider_tagline_deepseek
        ProviderKind.Grok -> R.string.provider_tagline_grok
        ProviderKind.MiniMax -> R.string.provider_tagline_minimax
        ProviderKind.Zhipu -> R.string.provider_tagline_zhipu
        ProviderKind.Qwen -> R.string.provider_tagline_qwen
        ProviderKind.Moonshot -> R.string.provider_tagline_moonshot
        ProviderKind.Mistral -> R.string.provider_tagline_mistral
        ProviderKind.SiliconFlow -> R.string.provider_tagline_siliconflow
        ProviderKind.OpenRouter -> R.string.provider_tagline_openrouter
        ProviderKind.Groq -> R.string.provider_tagline_groq
        ProviderKind.Together -> R.string.provider_tagline_together
        ProviderKind.Fireworks -> R.string.provider_tagline_fireworks
        else -> null
    }

    
    @StringRes
    fun regionOptionLabel(kind: ProviderKind, optionId: String): Int? =
        kind.endpointOptionLabelRes(optionId)

    
    fun regionOptions(kind: ProviderKind) = ProviderSetupCatalogResolver.current().regionOptions(kind)

    
    fun resolveRegionOption(kind: ProviderKind, baseUrl: String?) =
        ProviderSetupCatalogResolver.current().resolveRegionOption(kind, baseUrl)

    fun defaultBaseUrl(kind: ProviderKind) = ProviderSetupCatalogResolver.current().defaultBaseUrl(kind)
}
