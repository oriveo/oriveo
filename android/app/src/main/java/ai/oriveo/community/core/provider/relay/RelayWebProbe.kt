package ai.oriveo.community.core.provider.relay

import android.content.Context
import ai.oriveo.community.core.capability.truth.ProviderForm
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.provider.transport.StreamShape
import ai.oriveo.community.core.provider.transport.TransportStrategy
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put

/** The result of one web probe; [wire] matches the fixture `evidenceCases[].expect.result`. */
enum class RelayWebProbeResult(val wire: String) {
    Searched("searched"),
    Silent("silent"),
    Rejected("rejected"),
    Undetermined("undetermined"),
}

/** Record source: derived by a probe (tested) or observed in a real chat (observed). */
enum class RelayWebProbeSource(val wire: String) {
    Tested("tested"),
    Observed("observed"),
}

/** Evidence produced by the production stream parser: [searched] = there are citations or a search-ran signal; [urls] = citation urls, deduplicated in order. */
data class RelayWebProbeEvidence(val searched: Boolean, val urls: List<String>) {
    companion object {
        val None = RelayWebProbeEvidence(searched = false, urls = emptyList())
    }
}

/** The response after the probe request is read in full, together with the evidence decoded by the production parser for that protocol (decoded only on 2xx). */
data class RelayWebProbeReply(val response: RelayCapabilityTestResponse.Http, val evidence: RelayWebProbeEvidence)

sealed interface RelayWebProbeOutcome {
    /** This item is not listed: not a relay, not testable, or the protocol has no fragment; zero requests. */
    data object NotListed : RelayWebProbeOutcome

    /**
     * [at] comes from the injected clock (milliseconds); [written] = the record was written; [overrideWritten] = the override web was actually rewritten
     * (its value or source changed; silent removing tested does not count; the panel's Written indicator looks only at it).
     */
    data class Completed(
        val result: RelayWebProbeResult,
        val reason: RelayCapabilityTestReason,
        val status: Int?,
        val evidenceUrls: List<String>,
        val fragmentHash: String,
        val at: Long,
        val written: Boolean = false,
        val overrideWritten: Boolean = false,
    ) : RelayWebProbeOutcome

    /** Re-check failed after sending and before write-back (model gone / connection / first-send protocol / fragment changed): neither the record nor the override is written. */
    data class Stopped(val reason: RelayWebProbeStopReason) : RelayWebProbeOutcome
}

/** Reasons for aborting the pre-write-back re-check of a web probe (same as Web `RelayWebProbeStopReason`; cancellation goes through coroutine cancellation). */
enum class RelayWebProbeStopReason(val wire: String) {
    Unavailable("unavailable"),
    Connection("connection"),
    Protocol("protocol"),
    Fragment("fragment"),
}

/**
 * Relay web probe core (capability spec on RELAY x web):
 * only for the RELAY form, send one streaming request using the same builder as capability testing (the model's first-send protocol) + the stored fragment of that protocol (same merge function as chat),
 * the only user message is [PROMPT], output limit [OUTPUT_LIMIT], total time limit [TIMEOUT_SECONDS] seconds, sent once only.
 * Status classification reuses capability testing [RelayCapabilityTest.classify]; on 2xx the stream is fed to this protocol's production parser, and evidence means searched.
 * Fixture: shared `relay/web-probe.v1.json`. See [RelayWebProbeTrigger] for how auto triggers are selected.
 */
object RelayWebProbe {
    const val PROMPT = "Search the web and give one source URL for today's top news."
    const val OUTPUT_LIMIT = 256
    const val TIMEOUT_SECONDS = 30
    const val TIMEOUT_MILLIS = TIMEOUT_SECONDS * 1_000L
    private const val WEB_KEY = "web"

    /** Only the relay form is probed; BYOK / FREE / MANAGED / SUB never send. */
    fun isProbeForm(provider: Provider): Boolean = ProviderForm.of(provider) == ProviderForm.Relay

    /** The single user message of the probe, handed to the chat builder. */
    fun message(modelID: String): ChatMessage = ChatMessage(
        id = "web-probe",
        role = ChatRole.User,
        text = PROMPT,
        providerKind = ProviderKind.Relay,
        providerName = "",
        modelID = modelID,
        modelName = modelID,
        state = ChatMessageState.Delivered,
    )

    /** The output limit uses the builder's original field; no function tools, no images. */
    internal fun buildExtras(): RelayChatBuildExtras = RelayChatBuildExtras(maxOutputTokens = OUTPUT_LIMIT)

    /** JSON with keys sorted by code point and no whitespace (arrays keep order, numbers are stored as is). */
    fun canonicalJson(element: JsonElement): String = when (element) {
        is JsonObject -> element.entries
            .sortedWith { a, b -> compareCodePoints(a.key, b.key) }
            .joinToString(",", "{", "}") { (key, value) -> JsonPrimitive(key).toString() + ":" + canonicalJson(value) }
        is JsonArray -> element.joinToString(",", "[", "]") { canonicalJson(it) }
        is JsonPrimitive -> element.toString()
    }

    private fun compareCodePoints(a: String, b: String): Int {
        val left = a.codePoints().toArray()
        val right = b.codePoints().toArray()
        for (i in 0 until minOf(left.size, right.size)) {
            if (left[i] != right[i]) return left[i].compareTo(right[i])
        }
        return left.size.compareTo(right.size)
    }

    /** SHA-256 of the canonical JSON's UTF-8 bytes, lowercase hex. */
    fun fragmentHash(fragment: JsonObject): String =
        MessageDigest.getInstance("SHA-256")
            .digest(canonicalJson(fragment).toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    /** Feed the response to this protocol's production parser event by event; a non-SSE 2xx body counts as one event. */
    internal fun evidence(body: String, contentType: String?, strategy: TransportStrategy, shape: StreamShape?): RelayWebProbeEvidence {
        val chunks = if (contentType.orEmpty().lowercase().contains("text/event-stream")) {
            body.lineSequence()
                .map { it.trimEnd('\r') }
                .filter { it.startsWith("data:") }
                .map { it.removePrefix("data:").trim() }
                .filter { it.isNotEmpty() && it != "[DONE]" }
                .toList()
        } else {
            listOf(body)
        }
        var ran = false
        val urls = LinkedHashSet<String>()
        chunks.forEach { chunk ->
            strategy.parseCitations(chunk, shape).forEach { citation -> citation.url.trim().takeIf { it.isNotEmpty() }?.let(urls::add) }
            if (strategy.parseSearchRan(chunk)) ran = true
        }
        return RelayWebProbeEvidence(searched = ran || urls.isNotEmpty(), urls = urls.toList())
    }

    private sealed interface Sent {
        data class Reply(val reply: RelayWebProbeReply) : Sent
        data object Network : Sent
        data object Timeout : Sent
    }

    /**
     * Run one probe (no write): [fragment] null = not listed, zero requests. [send] reads the full body and decodes evidence;
     * beyond [deadlineMillis] counts as timeout, a thrown error (except cancellation) counts as a network error; [now] supplies the record time.
     */
    suspend fun run(
        fragment: JsonObject?,
        deadlineMillis: Long = TIMEOUT_MILLIS,
        now: () -> Long = { System.currentTimeMillis() },
        send: suspend () -> RelayWebProbeReply,
    ): RelayWebProbeOutcome {
        if (fragment == null) return RelayWebProbeOutcome.NotListed
        val hash = fragmentHash(fragment)
        val sent = try {
            withTimeoutOrNull(deadlineMillis) { Sent.Reply(send()) } ?: Sent.Timeout
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            Sent.Network
        }
        fun outcome(result: RelayWebProbeResult, reason: RelayCapabilityTestReason, status: Int?, urls: List<String> = emptyList()) =
            RelayWebProbeOutcome.Completed(result, reason, status, urls, hash, now())
        return when (sent) {
            Sent.Network -> outcome(RelayWebProbeResult.Undetermined, RelayCapabilityTestReason.Network, null)
            Sent.Timeout -> outcome(RelayWebProbeResult.Undetermined, RelayCapabilityTestReason.Timeout, null)
            is Sent.Reply -> {
                val http = sent.reply.response
                val classified = RelayCapabilityTest.classify(http.status, http.contentType, http.body)
                when (classified.verdict) {
                    RelayCapabilityVerdict.Rejected -> outcome(RelayWebProbeResult.Rejected, classified.reason, http.status)
                    // classify never yields notObserved (that is the evidence step of capability testing), so treat it as undetermined.
                    RelayCapabilityVerdict.Undetermined, RelayCapabilityVerdict.NotObserved,
                    RelayCapabilityVerdict.Searched, RelayCapabilityVerdict.Silent,
                    -> outcome(RelayWebProbeResult.Undetermined, classified.reason, http.status)
                    RelayCapabilityVerdict.Accepted -> when {
                        // An error frame after output has started is not a rejection: undetermined, write nothing.
                        http.contentType.orEmpty().lowercase().contains("text/event-stream") &&
                            RelayCapabilityTest.sseHasErrorEvent(http.body) ->
                            outcome(RelayWebProbeResult.Undetermined, RelayCapabilityTestReason.Server, http.status)
                        sent.reply.evidence.searched ->
                            outcome(RelayWebProbeResult.Searched, RelayCapabilityTestReason.Ok, http.status, sent.reply.evidence.urls)
                        else -> outcome(RelayWebProbeResult.Silent, RelayCapabilityTestReason.Ok, http.status)
                    }
                }
            }
        }
    }

    /** The entry to write into the record (tested); undetermined is not written and returns null. */
    fun recordOf(outcome: RelayWebProbeOutcome.Completed): RelayWebProbeRecord? =
        outcome.result.takeUnless { it == RelayWebProbeResult.Undetermined }?.let {
            RelayWebProbeRecord(it, RelayWebProbeSource.Tested, outcome.at, outcome.fragmentHash)
        }

    /**
     * tested web = a mirror of the current record after merging (ruling shared by all platforms): [merged] is the merged record result,
     * searched maps to web true, rejected to web false (source tested); silent removes the tested web;
     * undetermined writes no record and keeps the override value. A web set by the user is left alone.
     */
    fun applyingResult(overrides: RelayCapabilityOverrides?, merged: RelayWebProbeResult): RelayCapabilityOverrides? {
        if (overrides != null && overrides.web != null && WEB_KEY !in overrides.testedKeys) return overrides
        val value = when (merged) {
            RelayWebProbeResult.Searched -> true
            RelayWebProbeResult.Rejected -> false
            RelayWebProbeResult.Silent -> return clearingTestedWeb(overrides)
            RelayWebProbeResult.Undetermined -> return overrides
        }
        val current = overrides ?: RelayCapabilityOverrides()
        return current.copy(web = value, testedKeys = current.testedKeys + WEB_KEY)
    }

    /** With no old record the merge result is the probe result. */
    fun applyingResult(overrides: RelayCapabilityOverrides?, outcome: RelayWebProbeOutcome.Completed): RelayCapabilityOverrides? =
        applyingResult(overrides, outcome.result)

    /** Remove the web whose source is tested (user-set ones stay); keep other items, return null if everything is empty. */
    fun clearingTestedWeb(overrides: RelayCapabilityOverrides?): RelayCapabilityOverrides? {
        val current = overrides ?: return null
        if (WEB_KEY !in current.testedKeys) return current
        return current.copy(web = null, testedKeys = current.testedKeys - WEB_KEY).takeUnless { it.isEmpty }
    }

    /** The first-send protocol's fragment changed: remove the tested web of [modelIDs] (same id in the enabled list and the catalog). */
    fun clearingTestedWeb(provider: Provider, modelIDs: Set<String>): Provider {
        fun List<ai.oriveo.community.core.model.AIModel>.mapped() =
            map { if (it.id in modelIDs) it.copy(relayCapabilityOverrides = clearingTestedWeb(it.relayCapabilityOverrides)) else it }
        return provider.copy(models = provider.models.mapped(), catalogModels = provider.catalogModels.mapped())
    }

    /** Write back to the connection: mirror the merged record [merged]; models with the same id in the enabled list and the catalog are both updated. */
    fun applyingResult(provider: Provider, modelID: String, merged: RelayWebProbeResult): Provider {
        fun List<ai.oriveo.community.core.model.AIModel>.mapped() =
            map { if (it.id == modelID) it.copy(relayCapabilityOverrides = applyingResult(it.relayCapabilityOverrides, merged)) else it }
        return provider.copy(models = provider.models.mapped(), catalogModels = provider.catalogModels.mapped())
    }
}

/** One probe record: {result, source, at, fragmentHash}; result is only ever searched / silent / rejected. */
data class RelayWebProbeRecord(
    val result: RelayWebProbeResult,
    val source: RelayWebProbeSource,
    val at: Long,
    val fragmentHash: String,
)

/**
 * Local probe records `relay_web_probe_records.v1` (fixture `record`): key = connection x model x protocol, stored on this device only,
 * excluded from cloud sync and backup (excluded in backup_rules / data_extraction_rules), and cleared with the whole connection when it is deleted.
 * Same hash merges per mergeCases; hash differing from the current fragment means untested.
 */
class RelayWebProbeRecordStore(
    private val store: Store,
    /** Milliseconds; injected by tests. */
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    /** [transport] is `RelayTransport.value`. */
    data class Key(val connectionId: String, val modelId: String, val transport: String)

    interface Store {
        fun snapshot(): Map<String, String>
        fun put(name: String, value: String)
        fun remove(names: Collection<String>)
    }

    class MemoryStore : Store {
        private val values = LinkedHashMap<String, String>()
        @Synchronized override fun snapshot(): Map<String, String> = values.toMap()
        @Synchronized override fun put(name: String, value: String) { values[name] = value }
        @Synchronized override fun remove(names: Collection<String>) { names.forEach { values.remove(it) } }
    }

    fun now(): Long = clock()

    /** Write by the merge rules and return the merged record; nothing is written when incoming is undetermined. */
    @Synchronized
    fun record(key: Key, incoming: RelayWebProbeRecord): RelayWebProbeRecord? {
        val merged = merge(read(key), incoming) ?: return null
        store.put(encode(key), encodeRecord(merged))
        return merged
    }

    @Synchronized
    fun read(key: Key): RelayWebProbeRecord? = store.snapshot()[encode(key)]?.let(::decodeRecord)

    /** The record under the current fragment (hash); a different hash means untested and returns null. */
    fun current(key: Key, fragmentHash: String): RelayWebProbeRecord? = read(key)?.takeIf { it.fragmentHash == fragmentHash }

    /** The probe result of this connection x model x protocol under this fragment; untested or a stale hash means null. */
    fun currentResult(connectionId: String, modelId: String, transport: String, fragment: JsonObject): RelayWebProbeResult? =
        current(Key(connectionId, modelId, transport), RelayWebProbe.fragmentHash(fragment))?.result

    /**
     * The fragment chat actually attaches: protocols recorded as rejected under the current fragment are dropped, the rest (silent / untested / stale hash) are attached as usual.
     * The panel's sendsFragment goes through the same function as chat.
     */
    fun sendable(connectionId: String, modelId: String, fragments: Map<String, JsonObject>): Map<String, JsonObject> =
        fragments.filter { (transport, fragment) ->
            currentResult(connectionId, modelId, transport, fragment) != RelayWebProbeResult.Rejected
        }

    @Synchronized
    fun clearConnection(connectionId: String) {
        store.remove(store.snapshot().keys.filter { decode(it)?.connectionId == connectionId })
    }

    private fun encode(key: Key): String = listOf(key.connectionId, key.modelId, key.transport).joinToString(SEPARATOR)

    private fun decode(name: String): Key? {
        val parts = name.split(SEPARATOR)
        return if (parts.size == 3) Key(parts[0], parts[1], parts[2]) else null
    }

    private fun encodeRecord(record: RelayWebProbeRecord): String = buildJsonObject {
        put("result", record.result.wire)
        put("source", record.source.wire)
        put("at", record.at)
        put("fragmentHash", record.fragmentHash)
    }.toString()

    private fun decodeRecord(raw: String): RelayWebProbeRecord? = runCatching {
        val root = Json.parseToJsonElement(raw) as JsonObject
        fun text(key: String) = (root.getValue(key) as JsonPrimitive).content
        RelayWebProbeRecord(
            result = RelayWebProbeResult.entries.first { it.wire == text("result") && it != RelayWebProbeResult.Undetermined },
            source = RelayWebProbeSource.entries.first { it.wire == text("source") },
            at = (root.getValue("at") as JsonPrimitive).long,
            fragmentHash = text("fragmentHash"),
        )
    }.getOrNull()

    /** Before startup and in unit tests there is no Context: fall back to in-process memory, with the same semantics but nothing persisted. */
    private object DefaultStore : Store {
        @Volatile var context: Context? = null
        private val memory = MemoryStore()

        private fun prefs() = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        override fun snapshot(): Map<String, String> =
            prefs()?.all?.mapNotNull { (name, value) -> (value as? String)?.let { name to it } }?.toMap()
                ?: memory.snapshot()

        override fun put(name: String, value: String) {
            prefs()?.edit()?.putString(name, value)?.apply() ?: memory.put(name, value)
        }

        override fun remove(names: Collection<String>) {
            if (names.isEmpty()) return
            val prefs = prefs() ?: return memory.remove(names)
            prefs.edit().apply { names.forEach { remove(it) } }.apply()
        }
    }

    companion object {
        const val PREFS_NAME = "relay_web_probe_records.v1"
        private const val SEPARATOR = "\u001F"

        val shared: RelayWebProbeRecordStore = RelayWebProbeRecordStore(DefaultStore)

        /** Only remember the application context; SharedPreferences is opened on first read or write. */
        fun configure(context: Context) {
            DefaultStore.context = context.applicationContext
        }

        /**
         * Merge (fixture mergeCases): no old record or a different hash means take the new one; with the same hash, rejected / searched take the new one,
         * silent takes the new one only when the old one is not searched (not finding something does not negate having found it). undetermined is not written and returns null.
         */
        fun merge(existing: RelayWebProbeRecord?, incoming: RelayWebProbeRecord): RelayWebProbeRecord? {
            if (incoming.result == RelayWebProbeResult.Undetermined) return null
            if (existing == null || existing.fragmentHash != incoming.fragmentHash) return incoming
            return when (incoming.result) {
                RelayWebProbeResult.Silent -> existing.takeIf { it.result == RelayWebProbeResult.Searched } ?: incoming
                else -> incoming
            }
        }
    }
}
