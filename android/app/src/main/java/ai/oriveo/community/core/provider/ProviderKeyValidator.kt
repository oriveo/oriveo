package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsText
import io.ktor.http.URLBuilder
import io.ktor.http.Url
import io.ktor.http.isSuccess
import io.ktor.http.takeFrom
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/**
 * Validation engine for BYOK API keys.
 *
 * - The provider catalog's `providers[*].validation` block carries one contract for all of it:
 *   probe, probePath, authMode, headerProfile and invalidKeySignals.
 * - The key stays on the device. The probe goes straight to a model-independent endpoint upstream
 *   (GET /models, or GET /key for OpenRouter) and the verdict is drawn from the HTTP status code and
 *   the body text alone. Vendor-internal error codes are never parsed: MiniMax contradicts itself
 *   with 1004 versus 2049, while its HTTP 401 is stable.
 * - The verdict presumes innocence: 2xx -> VALID; a hit in invalidKeySignals -> INVALID; anything
 *   else (404, 429, 5xx, a timeout, a network failure, or simply no signal matched) -> UNVERIFIED.
 *   A good key must never be condemned by mistake; that was the root cause of the old "it will not
 *   let me add my key" reports.
 */
object ProviderKeyValidator {

    /** The outcome of a validation run. */
    sealed class Result {
        /** The probe answered with a 2xx, so the key is definitely good. */
        data object Valid : Result()

        /**
         * The response matched one of the provider's invalidKeySignals, so the key is definitely bad.
         * [httpStatus] is the status code that matched, for display in the UI and in logs.
         */
        data class Invalid(val httpStatus: Int) : Result()

        /**
         * Could not be verified (404, 429, 5xx, a timeout, a network failure, or no signal matched).
         * [reason] is a short human-readable cause, shown for diagnostics only.
         */
        data class Unverified(val reason: UnverifiedReason) : Result()

        val isValid: Boolean get() = this is Valid
        val isInvalid: Boolean get() = this is Invalid
        val isUnverified: Boolean get() = this is Unverified
    }

    /** Why a run came out UNVERIFIED. Diagnostics only: all three mean exactly the same verdict. */
    sealed class UnverifiedReason {
        /** An HTTP response arrived, but the status was neither 2xx nor a match in invalidKeySignals (404, 429, 5xx and so on). */
        data class UnexpectedStatus(val status: Int) : UnverifiedReason()

        /** The request timed out. */
        data object Timeout : UnverifiedReason()

        /** Network failure: no connectivity, DNS failure, region unreachable and the like. */
        data object Network : UnverifiedReason()

        /** The baseURL could not be parsed, i.e. the endpoint is misconfigured. */
        data object InvalidEndpoint : UnverifiedReason()
    }

    /** Probe timeout in milliseconds. A timeout counts as UNVERIFIED, never as INVALID. */
    const val TIMEOUT_MS: Long = 18_000L

    // MARK: - Pure verdict (unit-testable, touches no network)

    /**
     * Draws the verdict for one probe response.
     *
     * - HTTP 2xx -> VALID
     * - a match on any [MetadataClient.InvalidKeySignal] (the HTTP status equals status AND every
     *   string in bodyIncludes appears in the response body; when bodyIncludes is empty or absent
     *   only the status is considered) -> INVALID
     * - anything else (404, 429, 5xx, or no match at all) -> UNVERIFIED
     *
     * bodyIncludes is AND semantics, case sensitive, matched as a literal substring.
     */
    fun judge(
        statusCode: Int,
        body: String,
        signals: List<MetadataClient.InvalidKeySignal>,
    ): Result {
        if (statusCode in 200..299) {
            return Result.Valid
        }

        for (signal in signals) {
            if (signal.status != statusCode) continue
            // AND semantics: an empty bodyIncludes means the status alone decides; otherwise every
            // needle has to be present.
            if (signal.bodyIncludes.all { body.contains(it) }) {
                return Result.Invalid(httpStatus = statusCode)
            }
        }

        return Result.Unverified(UnverifiedReason.UnexpectedStatus(statusCode))
    }

    // MARK: - Network probe

    /**
     * Validates the credential of one provider.
     *
     * It resolves the baseURL (user configuration first, then the catalog, then the built-in
     * fallback, which handles alternate regions on its own), appends
     * [ProviderValidation.probePath], sends a GET probe, assembles the auth headers from the
     * declared authMode and headerProfile, and finally draws the verdict.
     *
     * @param provider the provider to validate; its kind selects the contract and its baseUrlText
     *        acts as the user override.
     * @param apiKey the key to validate. It is used locally and is never uploaded anywhere.
     * @param client the injected Ktor [HttpClient]; production passes the NetworkModule singleton.
     */
    suspend fun validate(
        provider: Provider,
        apiKey: String,
        client: HttpClient,
    ): Result {
        val kind = provider.kind
        // When the contract is missing, fall back to the most common shape (list_models, bearer, a
        // 401 signal) so validation still works offline or against an older contract.
        val validation = MetadataClient.validation(kind)
        val probePath = sanitizedPath(validation?.probePath) ?: "/models"
        val authMode = AuthMode.fromRaw(validation?.authMode) ?: AuthMode.Bearer
        val headerProfile = HeaderProfile.fromRaw(validation?.headerProfile) ?: HeaderProfile.None
        val signals = validation?.invalidKeySignals?.takeIf { it.isNotEmpty() }
            ?: listOf(MetadataClient.InvalidKeySignal(status = 401))

        val baseUrl = resolveBaseUrl(provider)
        val url = buildProbeUrl(
            baseUrl = baseUrl,
            probePath = probePath,
            authMode = authMode,
            apiKey = apiKey,
        ) ?: return Result.Unverified(UnverifiedReason.InvalidEndpoint)

        return try {
            // Run the probe and its timeout on the IO dispatcher: network belongs on IO, and
            // withTimeout then measures against the real clock rather than a virtual test clock -
            // otherwise runTest's StandardTestDispatcher fast-forwards 18s instantly and trips the
            // timeout for no reason.
            withContext(Dispatchers.IO) {
                withTimeout(TIMEOUT_MS) {
                    val response = client.get(url) {
                        applyAuthHeaders(authMode, headerProfile, apiKey)
                    }
                    val body = response.bodyAsText()
                    judge(statusCode = response.status.value, body = body, signals = signals)
                }
            }
        } catch (e: TimeoutCancellationException) {
            Result.Unverified(UnverifiedReason.Timeout)
        } catch (e: kotlinx.coroutines.CancellationException) {
            // Structured concurrency: cancellation of the parent coroutine has to propagate and must
            // not be swallowed as a Network failure.
            throw e
        } catch (e: Exception) {
            Result.Unverified(UnverifiedReason.Network)
        }
    }

    // MARK: - Contract field enums

    /** Authentication scheme, matching the contract's authMode. */
    enum class AuthMode {
        Bearer,
        XApiKey,
        QueryKey;

        companion object {
            fun fromRaw(raw: String?): AuthMode? = when (raw?.trim()?.takeIf { it.isNotEmpty() }) {
                "bearer" -> Bearer
                "x_api_key" -> XApiKey
                "query_key" -> QueryKey
                else -> null
            }
        }
    }

    /** Header profile, matching the contract's headerProfile: the extra headers beyond authMode. */
    enum class HeaderProfile {
        None,

        /** Anthropic: on top of x-api-key it also needs `anthropic-version: 2023-06-01`. */
        AnthropicV2023,

        /** OpenRouter: on top of bearer it carries HTTP-Referer / X-Title, same as a chat request. */
        OpenRouter;

        companion object {
            fun fromRaw(raw: String?): HeaderProfile? = when (raw?.trim()?.takeIf { it.isNotEmpty() }) {
                "none" -> None
                "anthropic_v2023_06_01" -> AnthropicV2023
                "openrouter" -> OpenRouter
                else -> null
            }
        }
    }

    // MARK: - Request construction (reuses the header semantics the services already have)

    /**
     * Resolves the baseURL: user configuration first, then the catalog transport, then the built-in
     * fallback. For a built-in provider baseUrlText is [ProviderKind.defaultBaseUrl], which already
     * carries the version prefix (for example `api.openai.com/v1`), so alternate regions need no
     * change here.
     */
    private fun resolveBaseUrl(provider: Provider): String {
        provider.baseUrlText?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        MetadataClient.providerTransport(provider.kind)?.baseUrl?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { return it }
        return provider.kind.defaultBaseUrl.orEmpty()
    }

    /**
     * Builds the probe URL. With `query_key` (Gemini) the key is appended to the query string.
     *
     * The baseUrl of some providers already carries a version prefix (`api.anthropic.com/v1`,
     * `generativelanguage.googleapis.com/v1beta`), and the `probePath` in the contract carries one
     * as well (`/v1/models`, `/v1beta/models`). Plain concatenation would write the version twice
     * (`.../v1/v1/models` -> 404 -> UNVERIFIED forever). So before concatenating, the overlap
     * between the base path and probePath is removed. This affects the probe URL only and never
     * touches chat requests.
     */
    fun buildProbeUrl(
        baseUrl: String,
        probePath: String,
        authMode: AuthMode,
        apiKey: String,
    ): String? {
        val trimmedBase = baseUrl.trim().takeIf { it.isNotEmpty() } ?: return null
        val normalizedBase = if (trimmedBase.startsWith("http://") || trimmedBase.startsWith("https://")) {
            trimmedBase
        } else {
            "https://$trimmedBase"
        }
        val base = normalizedBase.trimEnd('/')
        val effectiveProbePath = deduplicateVersionPrefix(base = base, probePath = probePath)
        val path = if (effectiveProbePath.startsWith("/")) effectiveProbePath else "/$effectiveProbePath"

        val builder = try {
            URLBuilder().takeFrom(base + path)
        } catch (_: Exception) {
            return null
        }
        if (authMode == AuthMode.QueryKey) {
            builder.parameters.append("key", apiKey)
        }
        return builder.buildString()
    }

    /**
     * Trims the leading version prefix of probePath when it duplicates the base path.
     *
     * basePath is the path portion of base (everything after the host, trailing slash removed). When
     * basePath is non-empty and probePath either equals it or starts with `basePath + "/"`, that
     * prefix is trimmed off probePath; otherwise probePath is returned untouched.
     * Example: base=`https://api.anthropic.com/v1` with probePath=`/v1/models` gives `/models`;
     * a bare-host base, or a probePath that does not start with basePath (OpenAI's `/models`,
     * OpenRouter's `/key`), is left alone.
     */
    private fun deduplicateVersionPrefix(base: String, probePath: String): String {
        val encodedPath = try {
            Url(base).encodedPath
        } catch (_: Exception) {
            return probePath
        }
        // The path portion (everything after the host), trailing slash removed. A bare host has an
        // empty path, for which Ktor reports "/".
        var basePath = encodedPath
        if (basePath.endsWith("/")) basePath = basePath.dropLast(1)
        if (basePath.isEmpty()) return probePath

        if (probePath == basePath) {
            return ""
        }
        if (probePath.startsWith("$basePath/")) {
            return probePath.substring(basePath.length)
        }
        return probePath
    }

    /**
     * Computes the auth header list from authMode plus headerProfile. A pure function, so it is
     * unit-testable.
     *
     * It maps one to one onto the `applyHeaders` semantics of each service: if chat gets through,
     * validation uses exactly the same headers. User-Agent is injected globally by the NetworkModule
     * OkHttp interceptor and is deliberately not repeated here.
     */
    fun authHeaders(
        authMode: AuthMode,
        headerProfile: HeaderProfile,
        apiKey: String,
    ): List<Pair<String, String>> {
        val headers = mutableListOf("Accept" to "application/json")

        when (authMode) {
            AuthMode.Bearer -> headers += "Authorization" to "Bearer $apiKey"
            AuthMode.XApiKey -> headers += "x-api-key" to apiKey
            // The key is already on the URL query (see buildProbeUrl), so no auth header is added.
            AuthMode.QueryKey -> Unit
        }

        when (headerProfile) {
            HeaderProfile.None -> Unit
            HeaderProfile.AnthropicV2023 -> headers += "anthropic-version" to "2023-06-01"
            HeaderProfile.OpenRouter -> {
                headers += "HTTP-Referer" to "https://github.com/oriveo/oriveo"
                headers += "X-Title" to "Oriveo"
            }
        }
        return headers
    }

    private fun io.ktor.client.request.HttpRequestBuilder.applyAuthHeaders(
        authMode: AuthMode,
        headerProfile: HeaderProfile,
        apiKey: String,
    ) {
        authHeaders(authMode, headerProfile, apiKey).forEach { (name, value) ->
            header(name, value)
        }
    }

    private fun sanitizedPath(value: String?): String? =
        value?.trim()?.takeIf { it.isNotEmpty() }
}
