package ai.oriveo.community.feature.providers.setup

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RegionOption

data class ProviderSetupDefaults(
    val displayName: String,
    val shortName: String,
    val apiKeyPlaceholder: String,
    val defaultBaseUrl: String?,
    val autoFillNote: String?,
)

data class ProviderSetupCatalog(
    val directProviders: List<ProviderKind>,
    val aggregatorProviders: List<ProviderKind>,
    private val defaultsByKind: Map<ProviderKind, ProviderSetupDefaults>,
    private val regionsByKind: Map<ProviderKind, List<RegionOption>>,
) {
    fun displayName(kind: ProviderKind): String = defaultsByKind[kind]?.displayName ?: kind.displayName

    fun shortName(kind: ProviderKind): String = defaultsByKind[kind]?.shortName ?: kind.shortName

    fun apiKeyPlaceholder(kind: ProviderKind): String =
        defaultsByKind[kind]?.apiKeyPlaceholder ?: kind.apiKeyPlaceholder

    fun defaultBaseUrl(kind: ProviderKind): String? =
        defaultsByKind[kind]?.defaultBaseUrl ?: kind.defaultBaseUrl

    fun autoFillNote(kind: ProviderKind): String? =
        defaultsByKind[kind]?.autoFillNote ?: kind.autoFillNote

    fun regionOptions(kind: ProviderKind): List<RegionOption> =
        regionsByKind[kind] ?: kind.regionOptions

    fun resolveRegionOption(kind: ProviderKind, baseUrl: String?): RegionOption? {
        val options = regionOptions(kind)
        if (options.isEmpty()) return null
        val normalized = normalizeBaseUrl(baseUrl) ?: return options.firstOrNull()
        return options.firstOrNull { normalizeBaseUrl(it.baseURL) == normalized } ?: options.firstOrNull()
    }

    companion object {
        fun fromProviderConfigs(
            providerConfigs: List<MetadataClient.PublicProviderConfig>?,
        ): ProviderSetupCatalog {
            if (providerConfigs == null) return fallback()

            val knownConfigs = providerConfigs
                .mapNotNull { config -> config.toKnownProviderConfig() }
                .sortedWith(
                    compareBy<KnownProviderConfig> { it.sortOrder ?: Int.MAX_VALUE }
                        .thenBy { fallbackOrder.indexOf(it.kind).takeIf { index -> index >= 0 } ?: Int.MAX_VALUE }
                        .thenBy { it.kind.rawValue },
                )

            if (knownConfigs.isEmpty()) {
                return ProviderSetupCatalog(
                    directProviders = emptyList(),
                    aggregatorProviders = emptyList(),
                    defaultsByKind = fallbackDefaults(),
                    regionsByKind = fallbackRegions(),
                )
            }

            val defaults = fallbackDefaults().toMutableMap()
            val regions = fallbackRegions().toMutableMap()
            val direct = mutableListOf<ProviderKind>()
            val aggregators = mutableListOf<ProviderKind>()

            knownConfigs.forEach { config ->
                defaults[config.kind] = ProviderSetupDefaults(
                    displayName = config.selectionLabel ?: config.displayName,
                    shortName = config.shortName ?: config.displayName,
                    apiKeyPlaceholder = config.apiKeyPlaceholder ?: config.kind.apiKeyPlaceholder,
                    defaultBaseUrl = config.defaultBaseURL,
                    autoFillNote = config.autoFillNote,
                )
                
                if (config.regionOptions.isNotEmpty()) {
                    regions[config.kind] = config.regionOptions
                }
                when (config.category) {
                    "aggregator" -> aggregators.add(config.kind)
                    else -> direct.add(config.kind)
                }
            }

            return ProviderSetupCatalog(
                directProviders = direct,
                aggregatorProviders = aggregators,
                defaultsByKind = defaults,
                regionsByKind = regions,
            )
        }

        fun fallback(): ProviderSetupCatalog = ProviderSetupCatalog(
            directProviders = ProviderKind.directProviders,
            aggregatorProviders = ProviderKind.aggregators,
            defaultsByKind = fallbackDefaults(),
            regionsByKind = fallbackRegions(),
        )

        private val fallbackOrder = listOf(
            ProviderKind.OpenAI,
            ProviderKind.Anthropic,
            ProviderKind.Gemini,
            ProviderKind.OpenRouter,
            ProviderKind.DeepSeek,
            ProviderKind.Grok,
            ProviderKind.Moonshot,
            ProviderKind.Mistral,
            ProviderKind.SiliconFlow,
            ProviderKind.Groq,
            ProviderKind.Together,
            ProviderKind.Fireworks,
            ProviderKind.MiniMax,
            ProviderKind.Zhipu,
            ProviderKind.Qwen,
        )

        private fun fallbackDefaults(): Map<ProviderKind, ProviderSetupDefaults> =
            fallbackOrder.associateWith { kind ->
                ProviderSetupDefaults(
                    displayName = kind.displayName,
                    shortName = kind.shortName,
                    apiKeyPlaceholder = kind.apiKeyPlaceholder,
                    defaultBaseUrl = kind.defaultBaseUrl,
                    autoFillNote = kind.autoFillNote,
                )
            }

        private fun fallbackRegions(): Map<ProviderKind, List<RegionOption>> =
            fallbackOrder.associateWith { kind -> kind.regionOptions }
    }
}

object ProviderSetupCatalogResolver {
    fun current(): ProviderSetupCatalog = ProviderSetupCatalog.fromProviderConfigs(
        if (MetadataClient.hasPublicProviderConfigSource()) {
            MetadataClient.listPublicProviderConfigs()
        } else {
            null
        },
    )
}

private data class KnownProviderConfig(
    val kind: ProviderKind,
    val displayName: String,
    val shortName: String?,
    val selectionLabel: String?,
    val autoFillNote: String?,
    val defaultBaseURL: String?,
    val apiKeyPlaceholder: String?,
    val category: String?,
    val regionOptions: List<RegionOption>,
    val sortOrder: Int?,
)

private fun MetadataClient.PublicProviderConfig.toKnownProviderConfig(): KnownProviderConfig? {
    val kind = when (kind) {
        "openAI" -> ProviderKind.OpenAI
        "anthropic" -> ProviderKind.Anthropic
        "gemini" -> ProviderKind.Gemini
        "deepseek" -> ProviderKind.DeepSeek
        "grok" -> ProviderKind.Grok
        "openRouter" -> ProviderKind.OpenRouter
        "groq" -> ProviderKind.Groq
        "togetherAI" -> ProviderKind.Together
        "fireworksAI" -> ProviderKind.Fireworks
        "miniMax" -> ProviderKind.MiniMax
        "zhipu" -> ProviderKind.Zhipu
        "qwen" -> ProviderKind.Qwen
        "moonshot" -> ProviderKind.Moonshot
        "mistral" -> ProviderKind.Mistral
        "siliconFlow" -> ProviderKind.SiliconFlow
        else -> return null
    }
    val normalizedDefault = defaultBaseURL.trim().takeIf { it.isNotEmpty() }
    return KnownProviderConfig(
        kind = kind,
        displayName = displayName.trim().takeIf { it.isNotEmpty() } ?: kind.displayName,
        shortName = shortName?.trim()?.takeIf { it.isNotEmpty() },
        selectionLabel = selectionLabel?.trim()?.takeIf { it.isNotEmpty() },
        autoFillNote = autoFillNote?.trim()?.takeIf { it.isNotEmpty() },
        defaultBaseURL = normalizedDefault,
        apiKeyPlaceholder = apiKeyPlaceholder?.trim()?.takeIf { it.isNotEmpty() },
        category = category?.takeIf { it == "direct" || it == "aggregator" },
        regionOptions = regionOptions
            ?.mapNotNull { option ->
                val id = option.id.trim()
                val label = option.label.trim()
                val baseURL = option.baseURL.trim().trimEnd('/')
                if (id.isEmpty() || label.isEmpty() || baseURL.isEmpty()) {
                    null
                } else {
                    RegionOption(id, label, baseURL)
                }
            }
            ?: emptyList(),
        sortOrder = sortOrder,
    )
}

private fun normalizeBaseUrl(baseUrl: String?): String? {
    var normalized = baseUrl?.trim()?.lowercase().orEmpty()
    if (normalized.isEmpty()) return null
    normalized = normalized.removePrefix("https://").removePrefix("http://")
    while (normalized.endsWith("/")) {
        normalized = normalized.dropLast(1)
    }
    return normalized
}
