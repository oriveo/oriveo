package ai.oriveo.community.feature.providers.setup

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RegionOption
import ai.oriveo.community.core.provider.transport.EndpointResolver
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource

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
    /** Ids among the delivered setupFields that the client recognizes; production does not deliver them yet, empty by default. */
    private val setupFieldIdsByKind: Map<ProviderKind, Set<String>> = emptyMap(),
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
        regionsByKind[kind] ?: trustedBuiltInRegions(kind)

    /**
     * Fields that appear in the selected address template (the region address if a region is selected, otherwise the default address) and were declared by the delivered metadata.
     * An address without placeholders is always empty, so the setup page UI does not change at all.
     */
    fun setupFieldIds(kind: ProviderKind, region: RegionOption?): List<String> {
        val template = region?.baseURL ?: defaultBaseUrl(kind) ?: return emptyList()
        val declared = setupFieldIdsByKind[kind].orEmpty()
        return OfficialEndpointSource.placeholders(template).filter { it in declared }
    }

    /**
     * The region matching the saved address (the "current value" on the detail / settings page). The trust table constrains only the selectable options, not the value the user already saved:
     * look among the options first, and if not found look in the unfiltered table; when nothing matches, fall back to the first item as before.
     */
    fun resolveRegionOption(kind: ProviderKind, baseUrl: String?): RegionOption? {
        val options = regionOptions(kind)
        if (normalizeBaseUrl(baseUrl) == null) return options.firstOrNull()
        return exactRegionOption(kind, baseUrl) ?: options.firstOrNull()
    }

    /** The region exactly equal to the saved address (options first, then the unfiltered delivered table and the built-in table); null if none. */
    fun exactRegionOption(kind: ProviderKind, baseUrl: String?): RegionOption? {
        val normalized = normalizeBaseUrl(baseUrl) ?: return null
        return (regionOptions(kind) + unfilteredRegionOptions(kind))
            .firstOrNull { normalizeBaseUrl(it.baseURL) == normalized }
    }

    /**
     * Detail-page echo: a `region:<id>` source whose item is in the displayed (trusted) catalog takes priority -- even if metadata moved
     * the address so the literal address matches no option, it is still recognized; otherwise it keeps the literal rule of [resolveRegionOption].
     */
    fun resolveRegionOption(kind: ProviderKind, baseUrl: String?, endpointSource: String?): RegionOption? =
        sourceRegionOption(kind, endpointSource) ?: resolveRegionOption(kind, baseUrl)

    /** The region matching the saved value, source first (as above), otherwise the literal rule of [exactRegionOption]; null if none. */
    fun exactRegionOption(kind: ProviderKind, baseUrl: String?, endpointSource: String?): RegionOption? =
        sourceRegionOption(kind, endpointSource) ?: exactRegionOption(kind, baseUrl)

    /**
     * The same predicate for the region picker display and region saving: the displayed catalog has at least one region option (after trust filtering,
     * the built-in one when there is no metadata). A Relay address is exactly what the user typed and is kept separate.
     */
    fun usesConfigurableBaseUrl(kind: ProviderKind): Boolean =
        kind == ProviderKind.Relay || regionOptions(kind).isNotEmpty()

    private fun sourceRegionOption(kind: ProviderKind, endpointSource: String?): RegionOption? {
        val id = OfficialEndpointSource.regionId(endpointSource) ?: return null
        return regionOptions(kind).firstOrNull { it.id == id }
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
            val setupFields = mutableMapOf<ProviderKind, Set<String>>()
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
                if (config.setupFieldIds.isNotEmpty()) {
                    setupFields[config.kind] = config.setupFieldIds
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
                setupFieldIdsByKind = setupFields,
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
            fallbackOrder.associateWith(::trustedBuiltInRegions)
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
    val setupFieldIds: Set<String>,
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
    val declaredSetupFields = OfficialEndpointSource.declaredSetupFieldIds(setupFields)
    // The default address may also be a template: when a placeholder is outside the closed set or undeclared it is treated as not delivered, falling back to the built-in default address.
    val normalizedDefault = defaultBaseURL.trim().takeIf { it.isNotEmpty() }
        ?.takeIf { template -> OfficialEndpointSource.placeholders(template).all { it in declaredSetupFields } }
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
        setupFieldIds = declaredSetupFields,
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

/** The region table without trust filtering: delivered raw values + the client built-in table, used only to reverse-look-up saved values and never enters the selectable options. */
private fun unfilteredRegionOptions(kind: ProviderKind): List<RegionOption> {
    val downloaded = MetadataClient.publicProviderConfig(kind)?.regionOptions.orEmpty().mapNotNull { option ->
        val id = option.id.trim()
        val label = option.label.trim()
        val baseURL = option.baseURL.trim().trimEnd('/')
        if (id.isEmpty() || label.isEmpty() || baseURL.isEmpty()) null else RegionOption(id, label, baseURL)
    }
    return downloaded + kind.regionOptions
}

/**
 * When falling back to the client built-in region table, the built-in options pass the same trust matching as delivered options: with a missing field only the last two labels of the fallback host are trusted,
 * so no host outside the trust table can appear after the fallback (for example the MiniMax domestic site when `minimaxi.com` was not delivered).
 */
private fun trustedBuiltInRegions(kind: ProviderKind): List<RegionOption> {
    val trusted = EndpointResolver.trustedHostSuffixes(kind)
    return kind.regionOptions.filter { EndpointResolver.isTrustedHttpsUrl(it.baseURL, trusted) }
}
