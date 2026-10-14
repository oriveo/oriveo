package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RegionOption

/**
 * Official provider address sources and setup fields. The single source of truth for rules and cases is
 * `shared/test-fixtures/provider-catalog/endpoint-source.v1.json` and `setup-fields.v1.json`.
 *
 * Records still store the literal address [Provider.baseUrlText] (older clients and sync read it), plus a device-local [Provider.endpointSource]:
 * `default` / `region:<id>` these are computed at request time from the current metadata (already filtered through the trusted table), falling back to the literal address when they cannot be computed;
 * `custom` uses the literal address; unclassified records are classified in memory first at request time. The region segment of the deterministic provider id only consults
 * [ai.oriveo.community.core.util.DeterministicProviderId] its frozen identity table, which is not touched here.
 */
object OfficialEndpointSource {
    const val DEFAULT = "default"
    const val CUSTOM = "custom"
    private const val REGION_PREFIX = "region:"

    /** The closed set of setup fields the client knows; a second id requires adding an entry on all three clients and shipping a release. */
    const val WORKSPACE_ID = "workspaceId"
    private val KNOWN_SETUP_FIELD_IDS = setOf(WORKSPACE_ID)

    private const val LEGACY_COMPAT_SUFFIX = "/compatible-mode/v1"
    private val PLACEHOLDER = Regex("""\{([^{}]*)\}""")
    private val DNS_LABEL = Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")

    /**
     * Address table used for classification and computation: the default address and region options have all passed the trusted table; an address may be a template with placeholders.
     * [builtInDefaultBaseUrl] only takes part in classification: for existing records where the server moved the default address before this device classified for the first time,
     * the literal address is still the built-in default written at setup time without metadata, and should count as default and follow the move.
     */
    data class Catalog(
        val defaultBaseUrl: String?,
        val regions: List<RegionOption>,
        val builtInDefaultBaseUrl: String? = null,
    )

    /** Retired regions (migration R1), the same table as the fixture `retiredRegions`; adding an entry requires all three clients to ship a release. */
    private data class RetiredRegion(
        val kind: ProviderKind,
        val regionId: String,
        val host: String,
        val replacement: String,
        val builtInReplacementBaseUrl: String,
    )

    private val RETIRED_REGIONS = listOf(
        RetiredRegion(ProviderKind.Qwen, "us", "dashscope-us.aliyuncs.com", "sg", "https://dashscope-intl.aliyuncs.com"),
    )

    fun region(id: String): String = "$REGION_PREFIX$id"

    fun regionId(source: String?): String? =
        source?.takeIf { it.startsWith(REGION_PREFIX) }?.removePrefix(REGION_PREFIX)?.takeIf { it.isNotEmpty() }

    /** Only the official providers have address sources; Relay is unchanged. */
    fun appliesTo(kind: ProviderKind): Boolean = kind != ProviderKind.Relay

    // ── Address normalization and classification ──────────────────────────────────────────────

    /** Trim, lowercase scheme and host, strip trailing slashes and a trailing `/compatible-mode/v1`; empty yields null. */
    fun normalize(raw: String?): String? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        val withScheme = if (trimmed.contains("://")) trimmed else "https://$trimmed"
        val schemeEnd = withScheme.indexOf("://")
        val scheme = withScheme.substring(0, schemeEnd).lowercase()
        val rest = withScheme.substring(schemeEnd + 3)
        val slash = rest.indexOf('/')
        val host = (if (slash < 0) rest else rest.substring(0, slash)).lowercase()
        var path = if (slash < 0) "" else rest.substring(slash).trimEnd('/')
        if (path.endsWith(LEGACY_COMPAT_SUFFIX)) path = path.removeSuffix(LEGACY_COMPAT_SUFFIX).trimEnd('/')
        return "$scheme://$host$path"
    }

    /** Empty -> default; equal to a region -> region (region takes priority over default); equal to the current or built-in default -> default; otherwise custom. */
    fun classify(baseUrlText: String?, catalog: Catalog, setupValues: Map<String, String>? = null): String {
        val normalized = normalize(baseUrlText) ?: return DEFAULT
        matchingRegion(normalized, catalog, setupValues)?.let { return region(it.id) }
        if (catalog.defaultBaseUrl?.let { fill(it, setupValues) }?.let(::normalize) == normalized) return DEFAULT
        if (catalog.builtInDefaultBaseUrl?.let(::normalize) == normalized) return DEFAULT
        return CUSTOM
    }

    private fun matchingRegion(normalized: String, catalog: Catalog, setupValues: Map<String, String>?): RegionOption? =
        catalog.regions.firstOrNull { option -> fill(option.baseURL, setupValues)?.let(::normalize) == normalized }

    // ── Setup fields and address templates ────────────────────────────────────────────

    fun placeholders(template: String): List<String> =
        PLACEHOLDER.findAll(template).map { it.groupValues[1] }.distinct().toList()

    /** The ids in the delivered setupFields that the client knows; missing / null = none. */
    fun declaredSetupFieldIds(fields: List<MetadataClient.ProviderSetupField>?): Set<String> =
        fields.orEmpty().map { it.id.trim() }.filter { it in KNOWN_SETUP_FIELD_IDS }.toSet()

    /** After trim + lowercase it must be a DNS label (1-63 chars of a-z0-9-, not starting or ending with `-`); invalid yields null. */
    fun normalizeSetupValue(raw: String?): String? {
        val value = raw?.trim()?.lowercase().orEmpty()
        return value.takeIf { DNS_LABEL.matches(it) }
    }

    /** Fill the template with values; without placeholders it is returned as-is, and any placeholder with a missing or invalid value yields null. */
    fun fill(template: String, values: Map<String, String>?): String? {
        val ids = placeholders(template)
        if (ids.isEmpty()) return template
        var filled = template
        for (id in ids) {
            val value = normalizeSetupValue(values?.get(id)) ?: return null
            filled = filled.replace("{$id}", value)
        }
        return filled
    }

    /**
     * Decode-time filtering: placeholders must belong to the closed set, be declared in setupFields, and appear only in the host segment;
     * each placeholder is replaced with `a` before passing the trusted table. Addresses without placeholders are judged exactly as before.
     */
    fun isAcceptableTemplate(template: String, declared: Set<String>, trusted: Set<String>): Boolean {
        val ids = placeholders(template)
        if (ids.any { it !in KNOWN_SETUP_FIELD_IDS || it !in declared }) return false
        var sample = template
        ids.forEach { sample = sample.replace("{$it}", "a") }
        if (sample.contains('{') || sample.contains('}')) return false
        if (ids.isNotEmpty()) {
            val afterScheme = template.trim().substringAfter("://")
            val hostPart = afterScheme.substringBefore('/')
            if (ids.any { !hostPart.contains("{$it}") }) return false
        }
        return EndpointResolver.isTrustedHttpsUrl(sample, trusted)
    }

    // ── Current metadata ────────────────────────────────────────────────

    /** The address table for this provider in the current metadata (already filtered through the trusted table); null if this provider was not delivered. */
    fun metadataCatalog(kind: ProviderKind, metadata: MetadataClient = MetadataClient.instance): Catalog? {
        if (!appliesTo(kind)) return null
        val config = metadata.trustedPublicProviderConfig(kind) ?: return null
        val trusted = EndpointResolver.trustedHostSuffixes(kind, config.trustedHosts)
        val declared = declaredSetupFieldIds(config.setupFields)
        val default = config.defaultBaseURL.trim().trimEnd('/')
            .takeIf { it.isNotEmpty() && isAcceptableTemplate(it, declared, trusted) }
        val regions = config.regionOptions.orEmpty().mapNotNull { option ->
            val id = option.id.trim()
            val label = option.label.trim()
            val baseURL = option.baseURL.trim().trimEnd('/')
            if (id.isEmpty() || label.isEmpty() || baseURL.isEmpty()) null else RegionOption(id, label, baseURL)
        }
        return Catalog(default, regions)
    }

    /**
     * Table used for classification at write time: metadata if present, otherwise the built-in fallback; built-in regions fill in when regions are empty,
     * consistent with the options of the setup page [ai.oriveo.community.feature.providers.setup.ProviderSetupCatalog].
     */
    fun classificationCatalog(kind: ProviderKind, metadata: MetadataClient = MetadataClient.instance): Catalog {
        val builtInRegions by lazy {
            val trusted = EndpointResolver.trustedHostSuffixes(kind)
            kind.regionOptions.filter { EndpointResolver.isTrustedHttpsUrl(it.baseURL, trusted) }
        }
        val downloaded = metadataCatalog(kind, metadata)
            ?: return Catalog(kind.defaultBaseUrl, builtInRegions, kind.defaultBaseUrl)
        return Catalog(
            defaultBaseUrl = downloaded.defaultBaseUrl ?: kind.defaultBaseUrl,
            regions = downloaded.regions.ifEmpty { builtInRegions },
            builtInDefaultBaseUrl = kind.defaultBaseUrl,
        )
    }

    // ── Lazy migration (R1 / R2): shared by startup backfill and request time ─────────────

    /**
     * Unclassified records are classified against the current table first, then R1 (retired region moves to its replacement, literal rewritten) and R2 (default whose literal equals some
     * current region -> pinned to that region, literal unchanged) run. Non-official providers are returned as-is.
     */
    fun reconciled(provider: Provider, metadata: MetadataClient = MetadataClient.instance): Provider {
        if (!appliesTo(provider.kind)) return provider
        val catalog = classificationCatalog(provider.kind, metadata)
        movedOffRetiredRegion(provider, catalog)?.let { return it }
        val classified = provider.endpointSource?.let { provider }
            ?: provider.copy(endpointSource = classify(provider.baseUrlText, catalog, provider.setupValues))
        if (classified.endpointSource != DEFAULT) return classified
        val normalized = normalize(classified.baseUrlText) ?: return classified
        val pinned = matchingRegion(normalized, catalog, classified.setupValues) ?: return classified
        return classified.copy(endpointSource = region(pinned.id))
    }

    /**
     * The record the startup backfill writes back to the device (only the address source and literal address change, updatedAt is untouched, nothing is uploaded); null when nothing changed.
     * Without metadata only R1 runs: classification and R2 depend on the current table, so they wait for metadata to avoid different sources depending on startup timing.
     */
    fun startupBackfill(provider: Provider, metadata: MetadataClient = MetadataClient.instance): Provider? {
        if (!appliesTo(provider.kind)) return null
        val next = if (metadata.hasPublicProviderConfigSource()) {
            reconciled(provider, metadata)
        } else {
            movedOffRetiredRegion(provider, classificationCatalog(provider.kind, metadata)) ?: return null
        }
        if (next.endpointSource == provider.endpointSource && next.baseUrlText == provider.baseUrlText) return null
        return next
    }

    /** R1: the source is a retired region, or the literal host is that of a retired region (any source) -> replacement region, literal rewritten to its current address. */
    private fun movedOffRetiredRegion(provider: Provider, catalog: Catalog): Provider? {
        val host = normalize(provider.baseUrlText)?.substringAfter("://")?.substringBefore('/')
        val retired = RETIRED_REGIONS.firstOrNull { entry ->
            entry.kind == provider.kind && (regionId(provider.endpointSource) == entry.regionId || host == entry.host)
        } ?: return null
        // When the current table (metadata if present) has no replacement region, use the built-in address so the move works without metadata.
        val replacementBase = catalog.regions.firstOrNull { it.id == retired.replacement }?.baseURL
            ?.takeIf { placeholders(it).isEmpty() }
            ?: retired.builtInReplacementBaseUrl
        return provider.copy(endpointSource = region(retired.replacement), baseUrlText = replacementBase)
    }

    // ── Read / write ──────────────────────────────────────────────────────

    /** Address used at request time: default / region are computed (templates are filled with values stored on this device); if it cannot be computed or for other sources, fall back to the literal address. */
    fun resolveBaseUrlText(provider: Provider, catalog: Catalog?): String? {
        val literal = provider.baseUrlText
        if (!appliesTo(provider.kind)) return literal
        val source = provider.endpointSource ?: return literal
        catalog ?: return literal
        val template = when {
            source == DEFAULT -> catalog.defaultBaseUrl
            else -> regionId(source)?.let { id -> catalog.regions.firstOrNull { it.id == id }?.baseURL }
        } ?: return literal
        return fill(template, provider.setupValues) ?: literal
    }

    /** The single exit through which all request entry points of official providers obtain the base URL: run the lazy migration in memory first (same rules as the startup backfill), then compute by source. */
    fun effectiveBaseUrlText(provider: Provider, metadata: MetadataClient = MetadataClient.instance): String? {
        if (!appliesTo(provider.kind)) return provider.baseUrlText
        return resolveBaseUrlText(reconciled(provider, metadata), metadataCatalog(provider.kind, metadata))
    }

    /** Unclassified official records are classified against the current table; non-official providers have these two fields cleared. Classified ones are untouched. */
    fun withClassifiedSource(provider: Provider, metadata: MetadataClient = MetadataClient.instance): Provider {
        if (!appliesTo(provider.kind)) {
            return if (provider.endpointSource == null && provider.setupValues == null) {
                provider
            } else {
                provider.copy(endpointSource = null, setupValues = null)
            }
        }
        if (provider.endpointSource != null) return provider
        return provider.copy(
            endpointSource = classify(provider.baseUrlText, classificationCatalog(provider.kind, metadata), provider.setupValues),
        )
    }

    /** All writers that change the literal address go through here: if the address really changed, clear the source and let [withClassifiedSource] recompute it from the new address. */
    fun withBaseUrlText(provider: Provider, baseUrlText: String?): Provider {
        if (normalize(baseUrlText) == normalize(provider.baseUrlText)) return provider.copy(baseUrlText = baseUrlText)
        return provider.copy(baseUrlText = baseUrlText, endpointSource = null)
    }
}
