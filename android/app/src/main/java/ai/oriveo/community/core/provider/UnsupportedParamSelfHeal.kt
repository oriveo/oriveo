package ai.oriveo.community.core.provider

import android.content.Context
import androidx.annotation.VisibleForTesting
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ChatRequestOptions
import kotlinx.serialization.json.Json
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.util.concurrent.ConcurrentHashMap
import java.net.URI
import java.security.MessageDigest
import java.util.UUID

object UnsupportedParamRetry {

    /**
     * Executes exactly one production send, unmodified.
     *
     * A parameter is never stripped and the request is never silently reissued: doing so can
     * lose what the user asked for and can duplicate side effects the first attempt already
     * caused. Structured rejections owned by a capability recipe go through the model-control
     * rejection path instead, which requires the user to confirm the resend.
     *
     * Every provider and Relay send funnels through here so that "one attempt" is enforced in one
     * place rather than trusted at twenty call sites. The request context arguments identify the
     * attempt at the call site and for the rejection cache; they never change what is sent.
     */
    internal suspend fun run(
        @Suppress("UNUSED_PARAMETER") providerKind: ProviderKind,
        @Suppress("UNUSED_PARAMETER") modelId: String,
        initialBody: String,
        @Suppress("UNUSED_PARAMETER") requestOptions: ChatRequestOptions = ChatRequestOptions(),
        @Suppress("UNUSED_PARAMETER") identity: CapabilityEvidenceFacade.QueryIdentity? = null,
        sendOnce: suspend (body: String) -> Unit,
    ) {
        sendOnce(initialBody)
    }
}

@Serializable
data class GenerationParameterDiagnosticEntry(
    val id: String,
    val createdAt: Long,
    val parameter: String,
    val status: String,
    val transport: String,
    val errorClass: String,
    val phase: String,
    val modelId: String? = null,
)

object GenerationParameterDiagnosticStore {
    private const val PREFS_NAME = "generation_parameter_diagnostics"
    private const val KEY = "v1"
    // Compact encoding on disk - record() rewrites up to 50 entries on every self-heal - while
    // the human-readable export uses prettyPrint.
    private val json = Json { ignoreUnknownKeys = true }
    private val exportJson = Json { ignoreUnknownKeys = true; prettyPrint = true }
    // A constant pattern, hoisted to the top level: recompiling it on every record() call buys
    // nothing.
    private val parameterNameRegex = Regex("^[A-Za-z0-9_.-]{1,80}$")
    @Volatile private var context: Context? = null

    fun configure(context: Context) { this.context = context.applicationContext }

    @Synchronized
    fun record(
        parameter: String,
        status: String,
        transport: String,
        errorClass: String,
        phase: String,
        modelId: String?,
    ) {
        if (!parameterNameRegex.matches(parameter)) return
        val prefs = prefs() ?: return
        val entry = GenerationParameterDiagnosticEntry(
            id = UUID.randomUUID().toString(),
            createdAt = System.currentTimeMillis(),
            parameter = parameter,
            status = status,
            transport = transport,
            errorClass = errorClass,
            phase = phase,
            modelId = modelId,
        )
        prefs.edit().putString(KEY, json.encodeToString((listOf(entry) + list()).take(50))).apply()
    }

    @Synchronized
    fun list(modelId: String? = null): List<GenerationParameterDiagnosticEntry> = prefs()?.getString(KEY, null)?.let {
        runCatching { json.decodeFromString<List<GenerationParameterDiagnosticEntry>>(it) }.getOrDefault(emptyList())
    }?.filter { modelId == null || it.modelId == null || it.modelId == modelId }?.sortedByDescending { it.createdAt } ?: emptyList()

    @Synchronized
    fun clear() { prefs()?.edit()?.remove(KEY)?.apply() }

    fun redactedJSON(): String = exportJson.encodeToString(list().map { it.copy(modelId = null) })

    private fun prefs() = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}

/**
 * Carries only self-heal results that already succeeded; never a prompt, a URL, a key or a
 * parameter value. AppViewModel maps these onto the existing global toast so the provider layer
 * does not have to depend on the UI or on an Android Context.
 */
object UnsupportedParamNoticeBus {
    private val _recoveredParams = MutableSharedFlow<String>(extraBufferCapacity = 8)
    val recoveredParams = _recoveredParams.asSharedFlow()

    fun publishRecovered(param: String) {
        _recoveredParams.tryEmit(param)
    }
}

/**
 * Extracts the rejected parameter name out of a whitelisted upstream 400 message, or null.
 *
 * Recognition is the **compiled-in baseline plus the patterns published in the catalog**: the
 * [PATTERNS] baseline ships with the build as the safety net, and the published entries are a
 * purely additive layer on top of it - they never replace the baseline - so that when an
 * upstream invents new wording for a rejected parameter, self-heal picks it up without a
 * release.
 */
object UnsupportedParamClassifier {
    // The first capture group is the parameter name. Only used for status == 400, which
    // [UnsupportedParamRetry.run] guarantees.
    private val PATTERNS = listOf(
        Regex("does not support parameter ['\"]?([A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)*)", RegexOption.IGNORE_CASE),          // xAI
        // OpenAI's own o-series and Responses wording: "Unsupported parameter: 'temperature' is
        // not supported...". The \b keeps the plural, generic sentence out, and "Unsupported
        // value" has no literal "parameter", so a rejected value such as xhigh is not swallowed.
        Regex("Unsupported parameter\\b:?\\s*['\"]?([A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)*)", RegexOption.IGNORE_CASE),

        Regex("unrecognized request arguments? supplied:?\\s*['\"]?([A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)*)", RegexOption.IGNORE_CASE), // OpenAI
        Regex("unknown (?:parameter|field|argument):?\\s*['\"]?([A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)*)", RegexOption.IGNORE_CASE),
        Regex("unexpected (?:field|parameter):?\\s*['\"]?([A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)*)", RegexOption.IGNORE_CASE),
        Regex("Unknown name ['\"]?([A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)*)", RegexOption.IGNORE_CASE),                              // Gemini
    )

    /**
     * A compiled published entry. [fixedParam] is the fallback parameter name used when the
     * regex has no capture group (see [MetadataClient.SelfHealPattern.param]); baseline entries
     * are always null, because the baseline recognises capture groups only and is immutable.
     */
    private class RuntimePattern(val regex: Regex, val fixedParam: String?)

    /** Compilation cache for published patterns, keyed by identity of the source list, so
     *  [setRuntimePatterns] is a cheap no-op while that list has not changed. */
    private class Compiled(
        val source: List<MetadataClient.SelfHealPattern>,
        val patterns: List<RuntimePattern>,
    )

    @Volatile
    private var compiled = Compiled(emptyList(), emptyList())

    /** The legal shape of a fixed parameter name, over the same character set the publisher
     *  validates against. */
    private val FIXED_PARAM_SHAPE = Regex("^[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)*$")

    /**
     * Refreshes the additive recognition layer from the published pattern definitions.
     *
     * An empty or over-long pattern (>200 characters, matching the publisher's own limit) is
     * skipped, and a [Regex] that fails to compile is discarded silently - one bad pattern must
     * never crash the app or poison the whole recognition chain. When the source list is the
     * same instance as last time, recompilation is skipped by reference.
     *
     * If `param` has an illegal shape (>64 characters, or illegal characters) only the fixed
     * name is dropped; the pattern itself is kept with pure capture-group semantics.
     */
    fun setRuntimePatterns(defs: List<MetadataClient.SelfHealPattern>) {
        if (defs === compiled.source) return
        compiled = Compiled(defs, defs.mapNotNull(::compileRuntimePattern))
    }

    private fun compileRuntimePattern(def: MetadataClient.SelfHealPattern): RuntimePattern? {
        val raw = def.pattern.trim()
        if (raw.isEmpty() || raw.length > 200) return null
        val options = if (def.flags?.trim()?.lowercase() == "i") setOf(RegexOption.IGNORE_CASE) else emptySet()
        val regex = runCatching { Regex(raw, options) }.getOrNull() ?: return null
        return RuntimePattern(regex, sanitizedFixedParam(def.param))
    }

    private fun sanitizedFixedParam(raw: String?): String? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty() || trimmed.length > 64 || !FIXED_PARAM_SHAPE.matches(trimmed)) return null
        return trimmed
    }

    fun extractParam(detail: String?): String? {
        if (detail.isNullOrEmpty()) return null
        // Baseline first, published patterns after it - the first hit returns the canonicalised
        // parameter name.
        for (pattern in PATTERNS) matchParam(pattern, detail, fixedParam = null)?.let { return it }
        for (entry in compiled.patterns) matchParam(entry.regex, detail, entry.fixedParam)?.let { return it }
        return null
    }

    /**
     * Name precedence: **capture group beats published fixed name**. The capture group was read
     * out of the actual message and is more precise than any configuration; the fixed name only
     * covers the case where the regex has no capture group at all (or it did not participate in
     * the match), which is the only way to handle a 400 that never names the parameter. If
     * neither yields anything, return null and try the next pattern.
     */
    private fun matchParam(pattern: Regex, detail: String, fixedParam: String?): String? {
        val match = pattern.find(detail) ?: return null
        val captured = match.groupValues.getOrNull(1)?.takeIf { it.isNotEmpty() }
        val name = captured ?: fixedParam ?: return null
        return canonicalParamName(name)
    }

    @VisibleForTesting
    fun resetRuntimePatternsForTest() {
        compiled = Compiled(emptyList(), emptyList())
    }
}

/**
 * Removes a rejected parameter from a request body given as a JSON string and returns the new
 * JSON; returns null when the parameter is not in the body, including after canonicalisation and
 * nested-path expansion.
 *
 * Only a top-level parameter or an exact path inside a known generation-parameter container is
 * removed. It never recurses into tools, JSON Schema or messages.
 */
object UnsupportedParamJson {
    private val json = Json { ignoreUnknownKeys = true }

    private fun norm(s: String): String = s.replace("_", "").lowercase()

    fun stripParam(bodyJson: String, param: String): String? {
        val root = runCatching { json.parseToJsonElement(bodyJson) }.getOrNull() as? JsonObject ?: return null
        var changed = false
        val mark = { changed = true }
        var result = removeAtPath(root, listOf(param), mark)
        for (path in candidateNestedPaths(param)) result = removeAtPath(result, path, mark)
        return if (changed) result.toString() else null
    }

    private fun removeAtPath(value: JsonElement, path: List<String>, onChange: () -> Unit): JsonElement {
        if (path.isEmpty()) return value
        return when (value) {
            is JsonObject -> {
                val headNorm = norm(path.first())
                buildJsonObject {
                    for ((key, child) in value) {
                        if (norm(key) != headNorm) {
                            put(key, child)
                            continue
                        }
                        if (path.size == 1) {
                            onChange()
                            continue
                        }
                        put(key, removeAtPath(child, path.drop(1), onChange))
                    }
                }
            }
            else -> value
        }
    }

    /** Splits a parameter path: snake_case on `_`, camelCase on the case boundary. A size of 1
     *  means there is no nested path to try. */
    private fun splitPath(name: String): List<String> {
        if (name.contains(".")) {
            return name.split(".").filter { it.isNotEmpty() }.map { it.lowercase() }
        }
        if (name.contains("_")) {
            return name.split("_").filter { it.isNotEmpty() }.map { it.lowercase() }
        }
        return name.split(Regex("(?<=[a-z0-9])(?=[A-Z])")).filter { it.isNotEmpty() }.map { it.lowercase() }
    }

    private fun candidateNestedPaths(param: String): List<List<String>> {
        val canonical = canonicalParamName(param)
        val paths = mutableListOf<List<String>>()
        if (param.contains('.')) paths.add(param.split('.').filter(String::isNotEmpty))
        val words = splitPath(param)
        if (words.size == 2 && words.first() in setOf("reasoning", "text", "output", "generation")) paths.add(words)
        val aliases = listOf(canonical, canonical.split('_').mapIndexed { index, word ->
            if (index == 0) word else word.replaceFirstChar(Char::uppercaseChar)
        }.joinToString(""))
        for (wrapper in listOf("generationConfig", "generation_config", "extra_body", "output_config")) {
            for (alias in aliases) paths.add(listOf(wrapper, alias))
        }
        if (canonical == "thinking_config") paths.add(listOf("generationConfig", "thinkingConfig"))
        if (canonical == "reasoning_effort" || canonical == "effort") paths.add(listOf("reasoning", "effort"))
        return paths
    }
}

/**
 * A process-lifetime cache of parameters already known to be unsupported. Once a provider that
 * injects optimistically (Grok, for one) has healed itself in this process, later sends for the
 * same provider and model skip the injection instead of paying for a wasted 400 round trip on
 * every message.
 */
internal object UnsupportedParamCache {
    /**
     * Cache eligibility must not silently control the recovery side effects.  The caller needs to
     * distinguish a retry-only observation from a duplicate exact overlay.
     */
    internal enum class WriteOutcome { Added, AlreadyCached, Ineligible }

    private data class Entry(
        val param: String,
        val observedAt: Long,
        val identity: CapabilityEvidenceFacade.QueryIdentity,
    )
    private val unsupported = ConcurrentHashMap<String, Entry>()
    private const val TTL_MILLIS = 24L * 60 * 60 * 1000
    private const val MAX_ENTRIES = 500

    /**
     * Entries are scoped to the exact runtime identity. The key covers account, connection,
     * generation, credential epoch, model, effective transport, endpoint fingerprint and the
     * revisions, so nothing learned under one connection can leak into another.
     */
    internal fun writeUnsupported(
        identity: CapabilityEvidenceFacade.QueryIdentity,
        param: String,
    ): WriteOutcome {
        val complete = completeRuntimeIdentity(identity) ?: return WriteOutcome.Ineligible
        prune()
        val key = exactKey(complete, param)
        val firstTime = unsupported.putIfAbsent(
            key,
            Entry(canonicalParamName(param), System.currentTimeMillis(), complete),
        ) == null
        if (unsupported.size > MAX_ENTRIES) {
            unsupported.entries.minByOrNull { it.value.observedAt }?.key?.let(unsupported::remove)
        }
        return if (firstTime) WriteOutcome.Added else WriteOutcome.AlreadyCached
    }

    /**
     * Production consumer for the exact runtime cache.  Every entry is first converted to the
     * facade's runtime candidate, then the facade is the sole authority for whether its request
     * policy permits omission.  In particular, no cache value can change the support verdict.
     */
    internal fun runtimeRejectedParamsForRequest(identity: CapabilityEvidenceFacade.QueryIdentity): Set<String> {
        val complete = completeRuntimeIdentity(identity) ?: return emptySet()
        return runtimeRejectedEvidence(complete)
            .asSequence()
            .mapNotNull { candidate ->
                val resolution = CapabilityEvidenceFacade.resolve(
                    key = candidate.key,
                    query = CapabilityEvidenceFacade.Query(
                        identity = complete,
                        now = System.currentTimeMillis(),
                        hasExplicitValue = false,
                    ),
                    candidates = listOf(candidate),
                )
                candidate.key.removePrefix("generation_parameter/")
                    .takeIf { resolution.requestPolicy == "omit_runtime_rejected" }
            }
            .toSet()
    }

    /** The production self-heal objects are consumed through the facade adapter; neither the raw
     *  endpoint nor any credential is exposed. */
    internal fun runtimeRejectedEvidence(identity: CapabilityEvidenceFacade.QueryIdentity): List<CapabilityEvidenceFacade.Candidate> {
        val complete = completeRuntimeIdentity(identity) ?: return emptyList()
        prune()
        return unsupported.asSequence()
            .filter { (_, entry) -> entry.identity == complete }
            .map { (_, entry) ->
                CapabilityEvidenceFacade.runtimeRejectedCandidate(
                    key = "generation_parameter/${entry.param}",
                    identity = complete,
                    observedAt = entry.observedAt,
                    expiresAt = entry.observedAt + TTL_MILLIS,
                )
            }
            .toList()
    }

    /** The settings page can only clear this connection's runtime overlay once it holds the
     *  complete local identity. */
    internal fun clear(identity: CapabilityEvidenceFacade.QueryIdentity) {
        val complete = completeRuntimeIdentity(identity) ?: return
        val prefix = exactPrefix(complete)
        unsupported.entries.removeIf { (key, entry) -> key.startsWith(prefix) && entry.identity == complete }
    }

    /**
     * The settings page has no final request URL, but a complete connection generation is enough
     * to clear the runtime overlay for every endpoint and revision of that connection and model.
     * It never falls back to a loose provider-and-model key.
     */
    internal fun clearConnection(
        partitionId: String,
        connectionInstanceId: String,
        connectionGeneration: String,
        credentialEpoch: String,
        providerKind: String,
        effectiveModelId: String,
    ) {
        if (
            partitionId.isBlank() || connectionInstanceId.isBlank() || connectionGeneration.isBlank() ||
            credentialEpoch.isBlank() || providerKind.isBlank() || effectiveModelId.isBlank()
        ) return
        unsupported.entries.removeIf { (_, entry) ->
            val identity = entry.identity
            identity.partitionId == partitionId &&
                identity.connectionInstanceId == connectionInstanceId &&
                identity.connectionGeneration == connectionGeneration &&
                identity.credentialEpoch == credentialEpoch &&
                identity.providerKind == providerKind &&
                identity.modelId == effectiveModelId
        }
    }

    private fun prune() {
        val cutoff = System.currentTimeMillis() - TTL_MILLIS
        unsupported.entries.removeIf { it.value.observedAt < cutoff }
    }

    // Each field is escaped before joining, so `|` is only ever a separator. A Relay modelId is
    // a user-controlled string, and joining it raw lets a modelId containing `|` collide with
    // the prefix of the neighbouring field. The read path re-verifies against entry.identity so
    // nothing is mislearned, but writeUnsupported's putIfAbsent would silently reject the later
    // identity as AlreadyCached and learn nothing.
    private fun exactPrefix(identity: CapabilityEvidenceFacade.QueryIdentity): String =
        listOf(
            "exact",
            identity.partitionId,
            identity.connectionInstanceId,
            identity.connectionGeneration,
            identity.credentialEpoch,
            identity.providerKind,
            identity.modelId,
            identity.canonicalModelId.orEmpty(),
            identity.effectiveTransport,
            identity.endpointFingerprint.orEmpty(),
            identity.metadataRevision.orEmpty(),
            identity.generationRevision.orEmpty(),
        ).joinToString("|") { java.net.URLEncoder.encode(it, "UTF-8") } + "|"

    private fun exactKey(identity: CapabilityEvidenceFacade.QueryIdentity, param: String): String =
        exactPrefix(identity) + cacheParamKey(param)

    /**
     * Runtime evidence has no loose provider-and-model scope: every local identity component
     * must be present. An older entry without a generation revision may conservatively fall back
     * to the catalog revision; if both are missing, only this one retry is allowed and nothing
     * is cached.
     */
    private fun completeRuntimeIdentity(
        identity: CapabilityEvidenceFacade.QueryIdentity,
    ): CapabilityEvidenceFacade.QueryIdentity? {
        if (
            identity.partitionId.isBlank() ||
            identity.connectionInstanceId.isBlank() ||
            identity.connectionGeneration.isBlank() ||
            identity.credentialEpoch.isBlank() ||
            identity.providerKind.isBlank() ||
            identity.modelId.isBlank() ||
            identity.effectiveTransport.isBlank() ||
            identity.endpointFingerprint.isNullOrBlank() ||
            identity.metadataRevision.isNullOrBlank()
        ) return null
        return identity.copy(generationRevision = identity.generationRevision ?: identity.metadataRevision)
    }

    @VisibleForTesting
    fun resetForTest() = unsupported.clear()
}

/** The address only ever participates in local cache partitioning: userInfo and query are
 *  stripped before hashing, and the request address itself is never recorded anywhere. */
fun relayEndpointFingerprint(rawUrl: String): String? = runCatching {
    val uri = URI(rawUrl)
    val originAndPath = "${uri.scheme}://${uri.host}${if (uri.port >= 0) ":${uri.port}" else ""}${uri.path.orEmpty().ifEmpty { "/" }}"
    val digest = MessageDigest.getInstance("SHA-256").digest(originAndPath.toByteArray(Charsets.UTF_8))
    "ep_" + digest.take(8).joinToString("") { "%02x".format(it) }
}.getOrNull()

private fun canonicalParamName(param: String): String {
    val trimmed = param.trim()
    if (trimmed.contains(".")) {
        return trimmed.split(".").filter { it.isNotEmpty() }.joinToString(".") { camelToSnake(it) }
    }
    return camelToSnake(trimmed)
}

private fun camelToSnake(value: String): String =
    value.replace(Regex("([a-z0-9])([A-Z])"), "$1_$2").lowercase()

private fun cacheParamKey(param: String): String =
    canonicalParamName(param).replace("_", "").lowercase()
