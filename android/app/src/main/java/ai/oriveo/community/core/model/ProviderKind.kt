package ai.oriveo.community.core.model

import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.util.DeterministicProviderId
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Built-in and user-owned provider kinds. */
@Serializable
enum class ProviderKind {
    @SerialName("openAI") OpenAI,
    @SerialName("anthropic") Anthropic,
    @SerialName("gemini") Gemini,
    @SerialName("deepseek") DeepSeek,
    @SerialName("grok") Grok,
    @SerialName("openRouter") OpenRouter,
    @SerialName("groq") Groq,
    @SerialName("together") Together,
    @SerialName("fireworks") Fireworks,
    @SerialName("miniMax") MiniMax,
    @SerialName("zhipu") Zhipu,
    @SerialName("qwen") Qwen,
    @SerialName("moonshot") Moonshot,
    @SerialName("mistral") Mistral,
    @SerialName("siliconFlow") SiliconFlow,
    @SerialName("relay") Relay;

    val displayName: String
        get() = when (this) {
            OpenAI -> "OpenAI"
            Anthropic -> "Anthropic"
            Gemini -> "Gemini"
            DeepSeek -> "DeepSeek"
            Grok -> "Grok"
            OpenRouter -> "OpenRouter"
            Groq -> "Groq"
            Together -> "Together AI"
            Fireworks -> "Fireworks AI"
            MiniMax -> "MiniMax"
            Zhipu -> "Z.ai"
            Qwen -> "Qwen"
            Moonshot -> "Kimi"
            Mistral -> "Mistral"
            SiliconFlow -> "SiliconFlow"
            Relay -> "Relay"
        }

    val shortName: String
        get() = when (this) {
            Anthropic -> "Claude"
            Relay -> "Relay"
            else -> displayName
        }

    val apiKeyPlaceholder: String
        get() = when (this) {
            OpenAI -> "sk-..."
            Anthropic -> "sk-ant-..."
            Gemini -> "AIza..."
            DeepSeek -> "sk-..."
            Grok -> "xai-..."
            OpenRouter -> "sk-or-..."
            Groq -> "gsk_..."
            Together -> ""
            Fireworks -> "fw_..."
            MiniMax -> "sk-api-..."
            Zhipu -> "sk-xxxxxxxx..."
            Qwen -> "sk-xxxxxxxxxxxxxxxx"
            Moonshot -> "sk-..."
            Mistral -> ""
            SiliconFlow -> "sk-..."
            Relay -> "sk-..."
        }

    /** Known provider default base URL; Relay is null (user-supplied). */
    val defaultBaseUrl: String?
        get() = when (this) {
            OpenAI -> "api.openai.com/v1"
            Anthropic -> "api.anthropic.com"
            Gemini -> "generativelanguage.googleapis.com"
            DeepSeek -> "api.deepseek.com/v1"
            Grok -> "api.x.ai/v1"
            OpenRouter -> "openrouter.ai/api/v1"
            Groq -> "api.groq.com/openai/v1"
            Together -> "api.together.xyz/v1"
            Fireworks -> "api.fireworks.ai/inference/v1"
            MiniMax -> "api.minimax.io/v1"
            Zhipu -> "open.bigmodel.cn/api/paas/v4"
            // The DashScope origin carries no path: EndpointResolver appends chat's /compatible-mode/v1/chat/completions
            // and image generation's /api/v1/services/aigc/multimodal-generation/generation; key validation appends
            // the metadata validation probePath (/compatible-mode/v1/models).
            Qwen -> "dashscope-intl.aliyuncs.com"
            Moonshot -> "api.moonshot.ai/v1"
            Mistral -> "api.mistral.ai/v1"
            SiliconFlow -> "api.siliconflow.cn/v1"
            Relay -> null
        }

    val isAggregatedProvider: Boolean
        get() = this != Relay

    val usesServerOrderedModels: Boolean
        get() = false

    /**
     * Whether the endpoint this provider is reached on may change after setup.
     *
     * Derived from [regionOptions] rather than listed by hand, so a provider that offers a region
     * picker always has somewhere to store the answer; listing the kinds separately let the picker
     * and the write path drift apart, which showed up as a region change that silently did nothing.
     * Relay has no fixed endpoint at all - its address is whatever the user typed.
     */
    val usesConfigurableBaseUrl: Boolean
        get() = this == Relay || regionOptions.isNotEmpty()

    val supportsAutomaticSync: Boolean
        get() = this != Relay

    val allowsCredentialEditing: Boolean
        get() = true

    val allowsManualModelEntry: Boolean
        get() = true

    val allowsAdvancedSettings: Boolean
        get() = true

    val allowsDeletion: Boolean
        get() = true

    val privacyPolicyUrl: String?
        get() = when (this) {
            OpenAI -> "https://openai.com/policies/row-privacy-policy/"
            Anthropic -> "https://www.anthropic.com/legal/privacy"
            Gemini -> "https://policies.google.com/privacy"
            DeepSeek -> "https://www.deepseek.com/privacy"
            Grok -> "https://x.ai/legal/privacy-policy"
            OpenRouter -> "https://openrouter.ai/privacy"
            Groq -> "https://groq.com/privacy-policy/"
            Together -> "https://www.together.ai/privacy"
            Fireworks -> "https://fireworks.ai/privacy-policy"
            MiniMax -> "https://www.minimax.io/privacy-policy"
            Zhipu -> "https://z.ai/legal/privacy"
            Qwen -> "https://www.alibabacloud.com/help/en/legal/latest/alibaba-cloud-international-website-privacy-policy"
            Moonshot -> "https://platform.kimi.ai/docs"
            Mistral -> "https://mistral.ai/terms#privacy-policy"
            SiliconFlow -> "https://siliconflow.com/privacy-policy"
            Relay -> null
        }

    val isThirdPartyAggregator: Boolean
        get() = this in setOf(Groq, Together, Fireworks)

    val isProviderSetupAggregator: Boolean
        get() = this in aggregators

    /**
     * Provider-level attachment envelope, taken only from the catalog (including the snapshot bundled in the APK);
     * when it is missing no support is claimed (all false). Relay does not publish one, so the entry check reads the input-capability projection.
     */
    val attachmentSupport: AttachmentSupportInfo
        get() = MetadataClient.providerAttachmentSupport(this)?.let { support ->
            AttachmentSupportInfo(
                image = support.image,
                video = support.video,
                nativeFile = support.nativeFile,
                textFileInline = support.textFileInline,
            )
        } ?: AttachmentSupportInfo(image = false, video = false, nativeFile = false, textFileInline = false)

    val autoFillNote: String?
        get() = when (this) {
            Relay -> null
            else -> "The service endpoint is auto-filled for you."
        }

    val openRouterVendorPrefix: String?
        get() = when (this) {
            OpenAI -> "openai"
            Anthropic -> "anthropic"
            Gemini -> "google"
            else -> null
        }

    val selectionLabelRes: Int?
        get() = when (this) {
            OpenRouter -> R.string.selection_label_aggregated
            Groq -> R.string.selection_label_ultra_fast
            Together -> R.string.selection_label_open_source
            Fireworks -> R.string.selection_label_high_performance
            MiniMax -> R.string.selection_label_chinese_ai
            Zhipu -> R.string.selection_label_chinese_ai
            Qwen -> R.string.selection_label_chinese_ai
            Moonshot -> R.string.selection_label_chinese_ai
            SiliconFlow -> R.string.selection_label_aggregated
            else -> null
        }

    val aggregatorSubtitleRes: Int?
        get() = when (this) {
            Groq -> R.string.aggregator_groq_subtitle
            Together -> R.string.aggregator_together_subtitle
            Fireworks -> R.string.aggregator_fireworks_subtitle
            else -> null
        }

    val endpointTitleRes: Int
        get() = R.string.official_endpoint

    val endpointDescriptionRes: Int?
        get() = when (this) {
            MiniMax -> R.string.provider_endpoint_minimax_description
            Qwen -> R.string.provider_endpoint_qwen_description
            Moonshot -> R.string.provider_endpoint_moonshot_description
            SiliconFlow -> R.string.provider_endpoint_siliconflow_description
            else -> null
        }

    val regionOptions: List<RegionOption>
        get() = when (this) {
            MiniMax -> listOf(
                RegionOption("global", "Global (api.minimax.io)", "https://api.minimax.io/v1"),
                RegionOption("cn", "China Mainland (api.minimaxi.com)", "https://api.minimaxi.com/v1"),
            )
            // DashScope origin (without /compatible-mode/v1): EndpointResolver appends chat's
            // /compatible-mode/v1/chat/completions and image generation's /api/v1/services/aigc/multimodal-generation/generation.
            // us is retired and no longer selectable; stored us records are lazily migrated to sg, and the
            // deterministic id still looks up us in the identity table.
            Qwen -> listOf(
                RegionOption("sg", "Singapore (International)", "https://dashscope-intl.aliyuncs.com"),
                RegionOption("bj", "Beijing (China Mainland)", "https://dashscope.aliyuncs.com"),
                RegionOption("hk", "Hong Kong", "https://cn-hongkong.dashscope.aliyuncs.com"),
            )
            Moonshot -> listOf(
                RegionOption("intl", "International (api.moonshot.ai)", "https://api.moonshot.ai/v1"),
                RegionOption("cn", "China Mainland (api.moonshot.cn)", "https://api.moonshot.cn/v1"),
            )
            SiliconFlow -> listOf(
                RegionOption("cn", "China Mainland (api.siliconflow.cn)", "https://api.siliconflow.cn/v1"),
                RegionOption("intl", "International (api.siliconflow.com)", "https://api.siliconflow.com/v1"),
            )
            else -> emptyList()
        }

    fun endpointOptionLabelRes(optionId: String): Int? = when (this) {
        MiniMax -> when (optionId) {
            "global" -> R.string.provider_endpoint_mini_max_global
            "cn" -> R.string.provider_endpoint_mini_max_cn
            else -> null
        }
        Qwen -> when (optionId) {
            "sg" -> R.string.provider_endpoint_qwen_sg
            "bj" -> R.string.provider_endpoint_qwen_bj
            "hk" -> R.string.provider_endpoint_qwen_hk
            "us" -> R.string.provider_endpoint_qwen_us
            else -> null
        }
        Moonshot -> when (optionId) {
            "intl" -> R.string.provider_endpoint_moonshot_intl
            "cn" -> R.string.provider_endpoint_moonshot_cn
            else -> null
        }
        SiliconFlow -> when (optionId) {
            "cn" -> R.string.provider_endpoint_siliconflow_cn
            "intl" -> R.string.provider_endpoint_siliconflow_intl
            else -> null
        }
        else -> null
    }

    /**
     * Literal reverse lookup for the deterministic id: it queries the frozen identity table, not the selectable
     * regions, so Qwen us is not selectable yet still resolves. Empty or unmatched falls to the first entry;
     * providers outside the table return null. Callers go through [DeterministicProviderId.identityRegionId].
     */
    fun resolveRegionOption(baseUrl: String?): DeterministicProviderId.IdentityRegion? {
        val table = DeterministicProviderId.identityRegions[this].orEmpty()
        if (table.isEmpty()) return null
        val normalizedBaseUrl = normalizeBaseUrl(baseUrl) ?: return table.first()
        return table.firstOrNull { normalizeBaseUrl(it.baseURL) == normalizedBaseUrl } ?: table.first()
    }

    val rawValue: String
        get() = when (this) {
            OpenAI -> "openAI"
            Anthropic -> "anthropic"
            Gemini -> "gemini"
            DeepSeek -> "deepseek"
            Grok -> "grok"
            OpenRouter -> "openRouter"
            Groq -> "groq"
            Together -> "together"
            Fireworks -> "fireworks"
            MiniMax -> "miniMax"
            Zhipu -> "zhipu"
            Qwen -> "qwen"
            Moonshot -> "moonshot"
            Mistral -> "mistral"
            SiliconFlow -> "siliconFlow"
            Relay -> "relay"
        }

    companion object {
        fun fromRawValue(raw: String): ProviderKind? =
            entries.firstOrNull { it.rawValue == raw }

        fun inferredFromApiKey(apiKey: String): ProviderKind? {
            val normalized = apiKey.trim().lowercase()
            if (normalized.isEmpty()) return null
            return when {
                normalized.startsWith("sk-ant-") -> Anthropic
                normalized.startsWith("sk-or-") -> OpenRouter
                normalized.startsWith("xai-") -> Grok
                normalized.startsWith("gsk_") -> Groq
                normalized.startsWith("fw_") -> Fireworks
                normalized.startsWith("sk-api-") -> MiniMax
                normalized.startsWith("eyjh") -> MiniMax
                normalized.startsWith("aiza") -> Gemini
                else -> null
            }
        }

        val directProviders = listOf(OpenAI, Anthropic, Gemini, DeepSeek, Grok, MiniMax, Zhipu, Qwen, Moonshot, Mistral)
        val aggregators = listOf(OpenRouter, Groq, Together, Fireworks, SiliconFlow)
    }

    private fun normalizeBaseUrl(baseUrl: String?): String? {
        var normalized = baseUrl?.trim()?.lowercase().orEmpty()
        if (normalized.isEmpty()) return null
        normalized = normalized.removePrefix("https://").removePrefix("http://")
        while (normalized.endsWith("/")) {
            normalized = normalized.dropLast(1)
        }
        normalized = normalized.removeSuffix("/compatible-mode/v1")
        return normalized
    }
}

data class AttachmentSupportInfo(
    val image: Boolean,
    val video: Boolean = false,
    val nativeFile: Boolean,
    val textFileInline: Boolean,
)

data class RegionOption(
    val id: String,
    val label: String,
    val baseURL: String,
)
