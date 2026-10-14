package ai.oriveo.community.core.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonNames

@Serializable
enum class RelayKind(val value: String) {
    @SerialName("openai_compatible")
    OpenAICompatible("openai_compatible"),

    @SerialName("codex_style")
    CodexStyle("codex_style"),

    @SerialName("anthropic_compatible")
    AnthropicCompatible("anthropic_compatible"),

    @SerialName("gemini_compatible")
    GeminiCompatible("gemini_compatible"),

    @SerialName("custom")
    Custom("custom");

    companion object {
        fun fromValue(value: String?): RelayKind? {
            val normalized = value?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            return entries.firstOrNull { kind ->
                kind.value == normalized || kind.name == normalized
            } ?: Custom
        }
    }
}

@Serializable(with = RelayTransportSerializer::class)
enum class RelayTransport(val value: String) {
    @SerialName("auto")
    Auto("auto"),

    @SerialName("openai_responses")
    OpenAIResponses("openai_responses"),

    @SerialName("openai_chat_completions")
    OpenAIChatCompletions("openai_chat_completions"),

    /** llama.cpp native completion endpoint (`POST /completion`), not its OpenAI facade. */
    @SerialName("llamacpp_native")
    LlamaCppNative("llamacpp_native"),

    @SerialName("anthropic_messages")
    AnthropicMessages("anthropic_messages"),

    @SerialName("gemini_generate_content")
    GeminiGenerateContent("gemini_generate_content"),
}

object RelayTransportSerializer : KSerializer<RelayTransport> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("RelayTransport", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): RelayTransport {
        val raw = decoder.decodeString()
        return RelayTransport.entries.firstOrNull { it.value == raw } ?: RelayTransport.Auto
    }

    override fun serialize(encoder: Encoder, value: RelayTransport) {
        encoder.encodeString(value.value)
    }
}

@Serializable(with = RelayAuthModeSerializer::class)
enum class RelayAuthMode(val value: String) {
    @SerialName("auto")
    Auto("auto"),

    @SerialName("none")
    None("none"),

    @SerialName("bearer")
    Bearer("bearer"),

    @SerialName("x_api_key")
    XApiKey("x_api_key"),

    @SerialName("x_goog_api_key")
    XGoogApiKey("x_goog_api_key"),

    @SerialName("query_key")
    QueryKey("query_key"),
}

@Serializable
enum class RelayConnectionSecurityMode(val value: String) {
    @SerialName("remote_https") RemoteHttps("remote_https"),
    @SerialName("local_http") LocalHttp("local_http"),
    @SerialName("private_vpn") PrivateVpn("private_vpn"),
    @SerialName("tofu_https") TofuHttps("tofu_https"),
}

object RelayAuthModeSerializer : KSerializer<RelayAuthMode> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("RelayAuthMode", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): RelayAuthMode {
        val raw = decoder.decodeString()
        return RelayAuthMode.entries.firstOrNull { it.value == raw } ?: RelayAuthMode.Auto
    }

    override fun serialize(encoder: Encoder, value: RelayAuthMode) {
        encoder.encodeString(value.value)
    }
}

@Serializable
enum class RelayReasoningEffort(val value: String) {
    @SerialName("automatic")
    Automatic("automatic"),

    @SerialName("low")
    Low("low"),

    @SerialName("medium")
    Medium("medium"),

    @SerialName("high")
    High("high"),

    @SerialName("xhigh")
    XHigh("xhigh"),
}

@Serializable
enum class RelayImageMode(val value: String) {
    @SerialName("same_model")
    SameModel("same_model"),

    @SerialName("tool_model")
    ToolModel("tool_model"),
}

@Serializable
enum class RelayImageOutputFormat(val value: String) {
    @SerialName("png")
    Png("png"),

    @SerialName("jpeg")
    Jpeg("jpeg"),
}

@Serializable
data class RelayKeyValue(
    val key: String,
    val value: String,
)

@Serializable
data class RelayRequestedConfig(
    val transport: RelayTransport = RelayTransport.Auto,
    val authMode: RelayAuthMode = RelayAuthMode.Auto,
    val securityMode: RelayConnectionSecurityMode = RelayConnectionSecurityMode.RemoteHttps,
    val modelID: String? = null,
    val reasoningEffort: RelayReasoningEffort? = null,
    val serviceTier: String? = null,
    val stream: Boolean? = null,
    val disableResponseStorage: Boolean? = null,
    val headers: List<RelayKeyValue>? = null,
    val queryParams: List<RelayKeyValue>? = null,
    val codexCompatIdentity: Boolean? = null,
    val customUserAgent: String? = null,

    val imageSize: String? = null,

    val imageQuality: String? = null,

    val imageStyle: String? = null,

    val imageCount: Int? = null,

    val imageResponseFormat: String? = null,

    val webSearchToolName: RelayWebSearchToolName? = null,

    val hasWebSearch: Boolean = false,

    val webSearchProfile: String? = null,

    @SerialName("transportKind")
    @OptIn(ExperimentalSerializationApi::class)
    @JsonNames("transportKindOverride")
    val transportKind: String? = null,

    val resolvedAPIBaseURL: String? = null,
    /**
     * Exact API root recorded per transport, keyed by [RelayTransport.value]. Different models on one connection may use
     * different transports, and their roots do not necessarily share one version segment. Keys stay strings: unknown transports written by other platforms / newer versions
     * must not make the whole config fail to decode. Reads go only through `RelayEndpointResolver.effectiveAPIRoot`.
     */
    val resolvedAPIBaseURLs: Map<String, String>? = null,
    /** Explicit local engine profile; null preserves all existing/cloud Relay behavior. */
    val engineProfile: String? = null,
    /** SHA-256 leaf certificate pin for explicit TOFU HTTPS mode. */
    val certificateFingerprint: String? = null,
)

object RelayCredentialPolicy {

    fun requiresCredential(authMode: RelayAuthMode?): Boolean =
        (authMode ?: RelayAuthMode.Auto) != RelayAuthMode.None

    fun requiresCredential(requested: RelayRequestedConfig?): Boolean =
        requiresCredential(requested?.authMode)

    fun hasStoredCredential(rawKey: String?): Boolean = !rawKey.isNullOrBlank()
}

val RelayAuthMode.requiresCredential: Boolean
    get() = RelayCredentialPolicy.requiresCredential(this)

val RelayRequestedConfig?.requiresCredential: Boolean
    get() = RelayCredentialPolicy.requiresCredential(this)

val RelayConnectionSecurityMode.isCleartext: Boolean
    get() = this == RelayConnectionSecurityMode.LocalHttp ||
        this == RelayConnectionSecurityMode.PrivateVpn

val RelayRequestedConfig?.isCleartextConnection: Boolean
    get() = (this?.securityMode ?: RelayConnectionSecurityMode.RemoteHttps).isCleartext

fun hasStoredCredential(rawKey: String?): Boolean = RelayCredentialPolicy.hasStoredCredential(rawKey)

val PORTABLE_RELAY_REQUESTED_FIELDS: Set<String> = setOf(
    "transport", "authMode", "securityMode", "modelID", "reasoningEffort", "serviceTier",
    "stream", "disableResponseStorage", "codexCompatIdentity",
    "imageSize", "imageQuality", "imageStyle", "imageCount", "imageResponseFormat",
    "webSearchToolName", "hasWebSearch", "webSearchProfile", "transportKind",
    "resolvedAPIBaseURL", "resolvedAPIBaseURLs", "engineProfile",
)

fun RelayRequestedConfig.credentialFreePortableCopy(): RelayRequestedConfig = RelayRequestedConfig(
    transport = transport,
    authMode = authMode,
    securityMode = securityMode,
    modelID = modelID,
    reasoningEffort = reasoningEffort,
    serviceTier = serviceTier,
    stream = stream,
    disableResponseStorage = disableResponseStorage,
    codexCompatIdentity = codexCompatIdentity,
    imageSize = imageSize,
    imageQuality = imageQuality,
    imageStyle = imageStyle,
    imageCount = imageCount,
    imageResponseFormat = imageResponseFormat,
    webSearchToolName = webSearchToolName,
    hasWebSearch = hasWebSearch,
    webSearchProfile = webSearchProfile,
    transportKind = transportKind,
    resolvedAPIBaseURL = credentialFreeRelayAPIRoot(resolvedAPIBaseURL),
    resolvedAPIBaseURLs = resolvedAPIBaseURLs?.credentialFreePortableRoots(),
    engineProfile = engineProfile,
)

/** Outbound keeps only entries whose key is a known transport (`auto` is not an addressable transport) and whose value parses; if none remain the whole key is omitted. */
private fun Map<String, String>.credentialFreePortableRoots(): Map<String, String>? {
    val addressable = RelayTransport.entries.filter { it != RelayTransport.Auto }.map { it.value }.toSet()
    return buildMap {
        for ((transport, root) in this@credentialFreePortableRoots) {
            if (transport !in addressable) continue
            credentialFreeRelayAPIRoot(root)?.let { put(transport, it) }
        }
    }.takeIf { it.isNotEmpty() }
}

/**
 * An outbound API root must be an absolute address with scheme and host. `java.net.URI` treats a string without a scheme such as `relay.example.com/v1`
 * as a plain path and lets it through, so syncing it out as is would upload a value that cannot be resolved.
 * The connection address the user typed by hand (`baseUrlText`) is not tightened and still goes through [credentialFreeRelayEndpoint].
 */
fun credentialFreeRelayAPIRoot(raw: String?): String? {
    val value = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    val uri = runCatching { java.net.URI(value) }.getOrNull() ?: return null
    if (uri.scheme.isNullOrEmpty() || uri.host.isNullOrEmpty()) return null
    return credentialFreeRelayEndpoint(value)
}

fun credentialFreeRelayEndpoint(raw: String?): String? {
    val value = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    return runCatching {
        val uri = java.net.URI(value)
        java.net.URI(uri.scheme, null, uri.host, uri.port, uri.path, null, null).toASCIIString()
    }.getOrNull()
}

@Serializable(with = RelayWebSearchToolNameLenientSerializer::class)
enum class RelayWebSearchToolName(val wireValue: String) {
    WebSearch("web_search"),
    WebSearchPreview("web_search_preview"),
    Disabled("disabled"),
}

object RelayWebSearchToolNameLenientSerializer : KSerializer<RelayWebSearchToolName?> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("RelayWebSearchToolName", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): RelayWebSearchToolName? {
        val raw = decoder.decodeString()
        return RelayWebSearchToolName.entries.firstOrNull { it.wireValue == raw }
    }

    override fun serialize(encoder: Encoder, value: RelayWebSearchToolName?) {
        if (value == null) return
        encoder.encodeString(value.wireValue)
    }
}

@Serializable
data class RelayImageConfig(
    val enabled: Boolean = false,
    val mode: RelayImageMode = RelayImageMode.SameModel,
    val toolModelID: String? = null,
    val outputFormat: RelayImageOutputFormat? = null,
)

// ── The only decode point for legacy connection-level web fields (lint exemption) ──
// Legacy fields are read and written only here: mapped to web fragments on read (not written back), carried over as is when editing a connection, and cleared when the web settings page saves.

/** Transport a legacy profile belongs to (fixture `profileTransport`); profiles not in the table are not mapped. */
private val LEGACY_WEB_PROFILE_TRANSPORTS: Map<String, RelayTransport> = mapOf(
    "oai_responses_web" to RelayTransport.OpenAIResponses,
    "grok_responses_web" to RelayTransport.OpenAIResponses,
    "ant_web_tool" to RelayTransport.AnthropicMessages,
    "gem_web" to RelayTransport.GeminiGenerateContent,
    "gem_web_retrieval" to RelayTransport.GeminiGenerateContent,
    "or_web" to RelayTransport.OpenAIChatCompletions,
    "qwen_web" to RelayTransport.OpenAIChatCompletions,
    "zhipu_web" to RelayTransport.OpenAIChatCompletions,
    "oai_web_tool" to RelayTransport.OpenAIChatCompletions,
    "kimi_web_search" to RelayTransport.OpenAIChatCompletions,
)

/** Needs a tool loop; a fragment alone cannot send web search. */
private const val LEGACY_TOOL_LOOP_PROFILE = "kimi_web_search"

/**
 * Read-time mapping of legacy `hasWebSearch == true` (fixture `legacyCases`). [profileMergeParams]: if the profile is in metadata
 * -> its mergeParams (empty object when absent), if not -> null. The result is used in memory only and never written back to the connection.
 */
fun RelayRequestedConfig?.legacyWebFragments(
    profileMergeParams: (String) -> kotlinx.serialization.json.JsonObject?,
): Map<String, kotlinx.serialization.json.JsonObject> {
    val requested = this ?: return emptyMap()
    if (!requested.hasWebSearch) return emptyMap()
    val profile = requested.webSearchProfile?.takeIf(String::isNotBlank)
    val declared = profile?.let(profileMergeParams)
    if (profile != null && declared != null) {
        val transport = LEGACY_WEB_PROFILE_TRANSPORTS[profile] ?: return emptyMap()
        if (profile == LEGACY_TOOL_LOOP_PROFILE) return emptyMap()
        val forbidden = ai.oriveo.community.core.provider.relay.RelayWebFragments.FORBIDDEN_TOP_LEVEL_KEYS.toSet()
        val params = kotlinx.serialization.json.JsonObject(declared.filterKeys { it !in forbidden })
        return if (params.isEmpty()) emptyMap() else mapOf(transport.value to params)
    }
    // No profile (or the profile is not in metadata): the only existing builders that can send web search are Responses and Gemini.
    return buildMap {
        val toolName = requested.webSearchToolName ?: RelayWebSearchToolName.WebSearch
        if (toolName != RelayWebSearchToolName.Disabled) {
            put(
                RelayTransport.OpenAIResponses.value,
                kotlinx.serialization.json.Json.parseToJsonElement("""{"tools":[{"type":"${toolName.wireValue}"}]}""")
                    as kotlinx.serialization.json.JsonObject,
            )
        }
        ai.oriveo.community.core.provider.relay.RelayWebFragments.template(RelayTransport.GeminiGenerateContent)
            ?.let { put(RelayTransport.GeminiGenerateContent.value, it) }
    }
}

/** When editing a connection, carry the legacy fields over to the new config unchanged (they must not be cleared even though the UI was removed). */
fun RelayRequestedConfig.carryingLegacyWebSearch(from: RelayRequestedConfig?): RelayRequestedConfig =
    if (from == null) this else copy(hasWebSearch = from.hasWebSearch, webSearchProfile = from.webSearchProfile)

/** Saving once on the web settings page clears both legacy fields. */
fun RelayRequestedConfig.clearingLegacyWebSearch(): RelayRequestedConfig =
    copy(hasWebSearch = false, webSearchProfile = null)

object RelayKindDefaults {
    /**
     * When a local-engine connection (with an engineProfile) changes type, the three engine fields (engineProfile / securityMode /
     * certificateFingerprint) are kept as is; behavior for connections without an engineProfile is unchanged.
     */
    fun makeRequested(
        kind: RelayKind,
        preserving: RelayRequestedConfig? = null,
    ): RelayRequestedConfig {
        val defaults = kindDefaults(kind, preserving)
        if (preserving == null || preserving.engineProfile.isNullOrBlank()) return defaults
        return defaults.copy(
            engineProfile = preserving.engineProfile,
            securityMode = preserving.securityMode,
            certificateFingerprint = preserving.certificateFingerprint,
        )
    }

    private fun kindDefaults(
        kind: RelayKind,
        preserving: RelayRequestedConfig?,
    ): RelayRequestedConfig = when (kind) {
        RelayKind.OpenAICompatible -> RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            authMode = RelayAuthMode.Bearer,
            modelID = preserving?.modelID,
            reasoningEffort = preserving?.reasoningEffort ?: RelayReasoningEffort.Automatic,
            serviceTier = preserving?.serviceTier,
            stream = true,
            headers = preserving?.headers,
            queryParams = preserving?.queryParams,
            customUserAgent = preserving?.customUserAgent,
            imageSize = preserving?.imageSize,
            imageQuality = preserving?.imageQuality,
            imageStyle = preserving?.imageStyle,
            imageCount = preserving?.imageCount,
            imageResponseFormat = preserving?.imageResponseFormat,
            webSearchToolName = preserving?.webSearchToolName,
            hasWebSearch = preserving?.hasWebSearch ?: false,
            webSearchProfile = preserving?.webSearchProfile,
            transportKind = preserving?.transportKind,
            resolvedAPIBaseURL = preserving?.resolvedAPIBaseURL,
        )
        RelayKind.CodexStyle -> RelayRequestedConfig(
            transport = RelayTransport.OpenAIResponses,
            authMode = RelayAuthMode.Bearer,
            modelID = preserving?.modelID,
            reasoningEffort = preserving?.reasoningEffort ?: RelayReasoningEffort.Automatic,
            serviceTier = preserving?.serviceTier,
            stream = true,
            disableResponseStorage = true,
            headers = preserving?.headers,
            queryParams = preserving?.queryParams,
            codexCompatIdentity = true,
            customUserAgent = preserving?.customUserAgent,
            imageSize = preserving?.imageSize,
            imageQuality = preserving?.imageQuality,
            imageStyle = preserving?.imageStyle,
            imageCount = preserving?.imageCount,
            imageResponseFormat = preserving?.imageResponseFormat,
            webSearchToolName = preserving?.webSearchToolName,
            hasWebSearch = preserving?.hasWebSearch ?: false,
            webSearchProfile = preserving?.webSearchProfile,
            transportKind = preserving?.transportKind,
            resolvedAPIBaseURL = preserving?.resolvedAPIBaseURL,
        )
        RelayKind.AnthropicCompatible -> RelayRequestedConfig(
            transport = RelayTransport.AnthropicMessages,
            authMode = RelayAuthMode.XApiKey,
            modelID = preserving?.modelID,
            stream = true,
            headers = preserving?.headers,
            queryParams = preserving?.queryParams,
            customUserAgent = preserving?.customUserAgent,
            imageSize = preserving?.imageSize,
            imageQuality = preserving?.imageQuality,
            imageStyle = preserving?.imageStyle,
            imageCount = preserving?.imageCount,
            imageResponseFormat = preserving?.imageResponseFormat,
            webSearchToolName = preserving?.webSearchToolName,
            hasWebSearch = preserving?.hasWebSearch ?: false,
            webSearchProfile = preserving?.webSearchProfile,
            transportKind = preserving?.transportKind,
            resolvedAPIBaseURL = preserving?.resolvedAPIBaseURL,
        )
        RelayKind.GeminiCompatible -> RelayRequestedConfig(
            transport = RelayTransport.GeminiGenerateContent,
            authMode = RelayAuthMode.XGoogApiKey,
            modelID = preserving?.modelID,
            stream = true,
            headers = preserving?.headers,
            queryParams = preserving?.queryParams,
            customUserAgent = preserving?.customUserAgent,
            imageSize = preserving?.imageSize,
            imageQuality = preserving?.imageQuality,
            imageStyle = preserving?.imageStyle,
            imageCount = preserving?.imageCount,
            imageResponseFormat = preserving?.imageResponseFormat,
            webSearchToolName = preserving?.webSearchToolName,
            hasWebSearch = preserving?.hasWebSearch ?: false,
            webSearchProfile = preserving?.webSearchProfile,
            transportKind = preserving?.transportKind,
            resolvedAPIBaseURL = preserving?.resolvedAPIBaseURL,
        )
        RelayKind.Custom -> RelayRequestedConfig(
            transport = preserving?.transport ?: RelayTransport.OpenAIChatCompletions,
            authMode = preserving?.authMode ?: RelayAuthMode.Bearer,
            modelID = preserving?.modelID,
            reasoningEffort = preserving?.reasoningEffort ?: RelayReasoningEffort.Automatic,
            serviceTier = preserving?.serviceTier,
            stream = preserving?.stream ?: true,
            disableResponseStorage = preserving?.disableResponseStorage,
            headers = preserving?.headers,
            queryParams = preserving?.queryParams,
            codexCompatIdentity = preserving?.codexCompatIdentity,
            customUserAgent = preserving?.customUserAgent,
            imageSize = preserving?.imageSize,
            imageQuality = preserving?.imageQuality,
            imageStyle = preserving?.imageStyle,
            imageCount = preserving?.imageCount,
            imageResponseFormat = preserving?.imageResponseFormat,
            webSearchToolName = preserving?.webSearchToolName,
            hasWebSearch = preserving?.hasWebSearch ?: false,
            webSearchProfile = preserving?.webSearchProfile,
            transportKind = preserving?.transportKind,
            resolvedAPIBaseURL = preserving?.resolvedAPIBaseURL,
        )
    }

    /**
     * Connection type for display / editing: an `auto` connection is always treated as fully custom, even if the legacy relayKind is something else.
     * Mapped on read only, never written back: preset types pin the connection transport to a concrete value, and only Custom can express `auto` as is.
     */
    fun effectiveKind(stored: RelayKind?, requested: RelayRequestedConfig?): RelayKind =
        if (requested?.transport == RelayTransport.Auto) RelayKind.Custom else stored ?: inferKind(requested)

    fun inferKind(requested: RelayRequestedConfig?): RelayKind = when (requested?.transport) {
        RelayTransport.OpenAIChatCompletions,
        RelayTransport.LlamaCppNative,
        -> RelayKind.OpenAICompatible
        RelayTransport.Auto -> RelayKind.Custom

        RelayTransport.OpenAIResponses -> RelayKind.CodexStyle
        RelayTransport.AnthropicMessages -> RelayKind.AnthropicCompatible
        RelayTransport.GeminiGenerateContent -> RelayKind.GeminiCompatible
        null -> RelayKind.Custom
    }
}
