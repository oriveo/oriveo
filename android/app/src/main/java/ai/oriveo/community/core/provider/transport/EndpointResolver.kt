package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import java.net.URI

/**
 * Endpoint URL resolver.
 *
 * Three levels of priority:
 *   1. the [Provider.baseUrlText] the user typed into the provider settings (a self-hosted
 *      proxy, Azure OpenAI, a regional gateway, and so on)
 *   2. the [ProviderTransportDefinition.baseUrl] and endpoints from the published catalog
 *   3. the built-in fallback table, as a safety net
 *
 * A Relay provider always requires an explicit base URL and gets no transport from the catalog.
 */
object EndpointResolver {

    /** DashScope's OpenAI-compatible endpoint prefix, used by the Qwen base-normalisation case. */
    private const val QWEN_COMPATIBLE_PREFIX = "/compatible-mode/v1"

    /** Endpoint kinds, aligned one-to-one with the fields of [TransportEndpoints]. */
    enum class EndpointKind {
        CHAT,
        RESPONSES,
        IMAGES,
        EMBEDDINGS,
        FILES,
    }

    /**
     * Resolves the full URL for this provider and endpoint kind.
     *
     * @param provider the current provider instance, including any user-supplied baseUrlText
     * @param kind which endpoint is being addressed
     * @param metadata the provider transport from the published catalog, when available
     * @return a full URL including scheme, host and path; falls back to the built-in table
     */
    fun resolveEndpoint(
        provider: Provider,
        kind: EndpointKind,
        metadata: ProviderTransportDefinition? = null,
    ): String {
        val userBase = provider.baseUrlText?.trim()?.takeIf { it.isNotEmpty() }
        val userPath = endpointPathFor(metadata?.endpoints, kind)

        // Priority, merged: user baseUrl + user endpoint > user baseUrl + catalog endpoint
        //                   > catalog baseUrl + catalog endpoint
        //                   > built-in fallback baseUrl + built-in fallback path
        val metadataBase = metadata?.baseUrl?.trim()?.takeIf { it.isNotEmpty() }
        val resolvedBase = userBase
            ?: metadataBase?.takeIf { isAllowedOfficialMetadataBase(provider.kind, it) }
            ?: fallbackBaseUrl(provider.kind)

        val resolvedPath = userPath
            ?: fallbackPath(provider.kind, kind)
            ?: ""

        // A version segment already present in the base has to come off before the path is
        // appended, or `/v1` + `/v1/chat/completions` produces a 404. See below.
        val normalizedBase = normalizeBaseForEndpoint(resolvedBase, provider.kind, resolvedPath)

        return joinUrl(normalizedBase, resolvedPath)
    }

    /**
     * De-duplicates the version segment between the base and the endpoint path.
     *
     * The catalog contract is "baseUrl stops at the origin, endpoints.* carries the full version
     * path" (deepseek is `https://api.deepseek.com` plus `/v1/chat/completions`), while an
     * official provider's [Provider.baseUrlText] holds [ProviderKind.defaultBaseUrl]
     * (`api.deepseek.com/v1`, version segment included). Concatenating the two naively yields
     * `/v1/v1/chat/completions`, and the upstream answers 404 with an empty body.
     *
     * The base is only trimmed back to its origin when the path really does cover the prefix the
     * base already carries; everything else is returned unchanged, so the version-less fallback
     * shape (base = origin plus path = /v1/...) behaves exactly as before.
     */
    private fun normalizeBaseForEndpoint(
        base: String,
        providerKind: ProviderKind,
        endpoint: String,
    ): String {
        if (endpoint.isEmpty()) return base
        // An absolute endpoint URL has its own joinUrl semantics; the base takes no part.
        if (endpoint.startsWith("http://", ignoreCase = true) ||
            endpoint.startsWith("https://", ignoreCase = true)
        ) {
            return base
        }

        val uri = runCatching { URI(ensureScheme(base).trimEnd('/')) }.getOrNull() ?: return base
        val scheme = uri.scheme ?: return base
        val authority = uri.authority ?: return base
        val basePath = uri.path.orEmpty().trimEnd('/')
        if (basePath.isEmpty()) return base

        val endpointPath = pathnameForPath(endpoint)
        if (endpointPath.isEmpty()) return base

        val origin = "$scheme://$authority"

        // Qwen special case: chat goes to /compatible-mode/v1/... while images go to the native
        // /api/v1/... path. If the user's base stops on the compatible prefix, both paths have
        // to strip it first - images do not overlap the base at all, so the general rule below
        // never fires for them.
        if (providerKind == ProviderKind.Qwen && basePath.endsWith(QWEN_COMPATIBLE_PREFIX)) {
            return origin + basePath.removeSuffix(QWEN_COMPATIBLE_PREFIX)
        }

        if (endpointPath == basePath || endpointPath.startsWith("$basePath/")) {
            return origin
        }

        return base
    }

    /** The bare path part of an endpoint: query and fragment dropped, trailing slash removed,
     *  leading slash added. */
    private fun pathnameForPath(path: String): String {
        val trimmed = path.substringBefore('#').substringBefore('?').trimEnd('/')
        if (trimmed.isEmpty()) return ""
        return if (trimmed.startsWith("/")) trimmed else "/$trimmed"
    }

    /** For services that assemble their own URLs: returns the base URL only, without appending
     *  an endpoint path. */
    fun resolveBaseUrl(
        provider: Provider,
        metadata: ProviderTransportDefinition? = null,
    ): String {
        val userBase = provider.baseUrlText?.trim()?.takeIf { it.isNotEmpty() }
        val metadataBase = metadata?.baseUrl?.trim()?.takeIf { it.isNotEmpty() }
        val base = userBase
            ?: metadataBase?.takeIf { isAllowedOfficialMetadataBase(provider.kind, it) }
            ?: fallbackBaseUrl(provider.kind)
        return ensureScheme(base).trimEnd('/')
    }

    private fun isAllowedOfficialMetadataBase(kind: ProviderKind, rawBase: String): Boolean {
        if (kind == ProviderKind.Relay) return true
        val normalized = ensureScheme(rawBase).trimEnd('/')
        val uri = runCatching { URI(normalized) }.getOrNull()
        val host = uri?.host?.lowercase()
        val allowedDomains = OFFICIAL_METADATA_BASE_ETLD1[kind].orEmpty()
        return uri?.scheme == "https" &&
            host != null &&
            allowedDomains.any { host == it || host.endsWith(".$it") }
    }

    private fun endpointPathFor(endpoints: TransportEndpoints?, kind: EndpointKind): String? {
        endpoints ?: return null
        return when (kind) {
            EndpointKind.CHAT -> endpoints.chat
            EndpointKind.RESPONSES -> endpoints.responses
            EndpointKind.IMAGES -> endpoints.images
            EndpointKind.EMBEDDINGS -> endpoints.embeddings
            EndpointKind.FILES -> endpoints.files
        }?.takeIf { it.isNotBlank() }
    }

    /**
     * The built-in fallback base URL, used only when catalog metadata is entirely unavailable.
     *
     * **Delegates to [ProviderKind.defaultBaseUrl]**, which is the single source of truth for
     * official endpoints and is also what provider auto-fill uses. This used to be a second copy
     * of that table, and the copy had dropped four path prefixes (openRouter was missing `/api`,
     * groq `/openai`, fireworks `/inference`, zhipu `/api/paas`), so every fallback landed on a
     * 404.
     *
     * It takes the origin rather than the whole string, matching the catalog contract of
     * "baseUrl to the origin, endpoints carry the full version path"; the path half is supplied
     * by [fallbackPath] from the same table (see [fallbackVersionPrefix]).
     */
    private fun fallbackBaseUrl(kind: ProviderKind): String = when (kind) {
        // Relay requires an explicit base URL, so there is nothing to fall back to.
        ProviderKind.Relay -> ""
        else -> kind.defaultBaseUrl?.let(::originOf).orEmpty()
    }

    /** The `scheme://authority` of a URL; returned unchanged when it cannot be parsed (with a
     *  scheme added and any trailing slash removed). */
    private fun originOf(baseUrl: String): String {
        val normalized = ensureScheme(baseUrl).trimEnd('/')
        val uri = runCatching { URI(normalized) }.getOrNull() ?: return normalized
        val scheme = uri.scheme ?: return normalized
        val authority = uri.authority ?: return normalized
        return "$scheme://$authority"
    }

    /**
     * The version-segment prefix for OpenAI-compatible fallback paths, taken from the path part
     * of [ProviderKind.defaultBaseUrl].
     *
     * That way base (origin) plus path (including the prefix) reconstructs the real official
     * endpoint, and it still lines up in the common case where the user's baseUrl happens to be
     * exactly defaultBaseUrl ([normalizeBaseForEndpoint] trims the duplicated segment). When the
     * table has no path at all - Relay, or DashScope's native origin - it follows the OpenAI
     * convention of `/v1`.
     */
    private fun fallbackVersionPrefix(kind: ProviderKind): String {
        val base = kind.defaultBaseUrl ?: return "/v1"
        val path = runCatching { URI(ensureScheme(base).trimEnd('/')).path }.getOrNull().orEmpty()
        return path.ifEmpty { "/v1" }
    }

    private val OFFICIAL_METADATA_BASE_ETLD1: Map<ProviderKind, Set<String>> = mapOf(
        ProviderKind.OpenAI to setOf("openai.com"),
        ProviderKind.Anthropic to setOf("anthropic.com"),
        ProviderKind.Gemini to setOf("googleapis.com"),
        ProviderKind.DeepSeek to setOf("deepseek.com"),
        ProviderKind.Grok to setOf("x.ai"),
        ProviderKind.OpenRouter to setOf("openrouter.ai"),
        ProviderKind.Groq to setOf("groq.com"),
        ProviderKind.Together to setOf("together.xyz"),
        ProviderKind.Fireworks to setOf("fireworks.ai"),
        ProviderKind.MiniMax to setOf("minimax.io"),
        ProviderKind.Zhipu to setOf("bigmodel.cn"),
        ProviderKind.Qwen to setOf("aliyuncs.com"),
        ProviderKind.Moonshot to setOf("moonshot.ai", "moonshot.cn"),
        ProviderKind.Mistral to setOf("mistral.ai"),
        ProviderKind.SiliconFlow to setOf("siliconflow.cn", "siliconflow.com"),
    )

    /**
     * The built-in fallback endpoint paths, aligned with the catalog's default transport table.
     */
    private fun fallbackPath(provider: ProviderKind, kind: EndpointKind): String? {
        return when (provider) {
            ProviderKind.OpenAI -> when (kind) {
                EndpointKind.CHAT -> "/v1/chat/completions"
                EndpointKind.RESPONSES -> "/v1/responses"
                EndpointKind.IMAGES -> "/v1/images/generations"
                EndpointKind.FILES -> "/v1/files"
                EndpointKind.EMBEDDINGS -> "/v1/embeddings"
            }
            ProviderKind.Anthropic -> when (kind) {
                EndpointKind.CHAT -> "/v1/messages"
                EndpointKind.FILES -> "/v1/files"
                else -> null
            }
            ProviderKind.Gemini -> when (kind) {
                EndpointKind.CHAT -> "/v1beta"
                EndpointKind.IMAGES -> "/v1beta"
                else -> null
            }
            ProviderKind.Qwen -> when (kind) {
                // Chat uses the OpenAI-compatible endpoint: DashScope's native text-generation
                // path is retired, and qwen3.x answers it with an in-stream error that gets
                // swallowed into an empty response.
                EndpointKind.CHAT -> "/compatible-mode/v1/chat/completions"
                EndpointKind.IMAGES -> "/api/v1/services/aigc/multimodal-generation/generation"
                else -> null
            }
            ProviderKind.MiniMax -> when (kind) {
                // Text uses the OpenAI-compatible path; image models use MiniMax's own endpoint.
                // The OpenAI-shaped /v1/images/generations does not exist on MiniMax, so falling
                // into the generic bucket is a guaranteed 404.
                EndpointKind.CHAT -> "/v1/chat/completions"
                EndpointKind.IMAGES -> "/v1/image_generation"
                else -> null
            }
            ProviderKind.Grok,
            ProviderKind.DeepSeek,
            ProviderKind.OpenRouter,
            ProviderKind.Groq,
            ProviderKind.Together,
            ProviderKind.Fireworks,
            ProviderKind.Zhipu,
            ProviderKind.Moonshot,
            ProviderKind.Mistral,
            ProviderKind.SiliconFlow,
            ProviderKind.Relay -> fallbackVersionPrefix(provider).let { prefix ->
                when (kind) {
                    EndpointKind.CHAT -> "$prefix/chat/completions"
                    EndpointKind.RESPONSES -> "$prefix/responses"
                    EndpointKind.IMAGES -> "$prefix/images/generations"
                    EndpointKind.FILES -> "$prefix/files"
                    EndpointKind.EMBEDDINGS -> "$prefix/embeddings"
                }
            }
        }
    }

    /** Joins a URL, accepting either a host-only or a host-plus-path base. */
    private fun joinUrl(base: String, path: String): String {
        val scheme = ensureScheme(base).trimEnd('/')
        if (path.isEmpty()) return scheme
        val normalizedPath = if (path.startsWith("/")) path else "/$path"
        return "$scheme$normalizedPath"
    }

    private fun ensureScheme(url: String): String {
        val trimmed = url.trim()
        return if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
            trimmed
        } else {
            "https://$trimmed"
        }
    }
}
