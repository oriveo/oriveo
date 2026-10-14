package ai.oriveo.community.core.provider.relay

import android.content.Context
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.legacyWebFragments
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject

/**
 * Connection-level web fragments of a relay:
 * each connection stores one JSON object per transport, and once stored it is always sent with every chat request on that transport; auxiliary requests such as capability tests and titles do not carry it.
 * Fixture `shared/test-fixtures/relay/web-fragment.v1.json`.
 */
object RelayWebFragments {
    /** Section order on the settings page: Chat Completions / Responses / Messages / Gemini. */
    val TRANSPORTS: List<RelayTransport> = listOf(
        RelayTransport.OpenAIChatCompletions,
        RelayTransport.OpenAIResponses,
        RelayTransport.AnthropicMessages,
        RelayTransport.GeminiGenerateContent,
    )

    const val MAX_BYTES = 8192

    val FORBIDDEN_TOP_LEVEL_KEYS: List<String> = listOf(
        "model", "messages", "input", "contents", "system", "systemInstruction", "system_instruction",
        "instructions", "stream", "stream_options", "previous_response_id", "tool_choice", "toolConfig", "tool_config",
    )

    private val FUNCTION_TOOL_KEYS = setOf("functionDeclarations", "function_declarations")

    private val TEMPLATES: Map<RelayTransport, String> = mapOf(
        RelayTransport.OpenAIResponses to """{"tools":[{"type":"web_search"}]}""",
        RelayTransport.OpenAIChatCompletions to """{"web_search_options":{}}""",
        RelayTransport.AnthropicMessages to """{"tools":[{"type":"web_search_20250305","name":"web_search","max_uses":5}]}""",
        RelayTransport.GeminiGenerateContent to """{"tools":[{"googleSearch":{}}]}""",
    )

    fun template(transport: RelayTransport): JsonObject? =
        TEMPLATES[transport]?.let { Json.parseToJsonElement(it).jsonObject }

    sealed interface Validation {
        data class Ok(val fragment: JsonObject) : Validation
        /** [code] matches the error codes in the fixture's `validateCases`; [key] exists only for forbidden_key. */
        data class Error(val code: String, val key: String? = null) : Validation
    }

    /** Verdict order matches the fixture: not_json -> not_object -> empty -> too_large -> forbidden_key -> invalid_tools -> function_tool. */
    fun validate(raw: String): Validation {
        val parsed = try {
            Json.parseToJsonElement(raw)
        } catch (_: Exception) {
            return Validation.Error("not_json")
        }
        val root = parsed as? JsonObject ?: return Validation.Error("not_object")
        if (root.isEmpty()) return Validation.Error("empty")
        if (raw.encodeToByteArray().size > MAX_BYTES) return Validation.Error("too_large")
        FORBIDDEN_TOP_LEVEL_KEYS.firstOrNull { it in root }?.let { return Validation.Error("forbidden_key", it) }
        root["tools"]?.let { tools ->
            val entries = (tools as? JsonArray)?.takeIf { array -> array.all { it is JsonObject } }
                ?: return Validation.Error("invalid_tools")
            if (entries.any { isFunctionTool(it.jsonObject) }) return Validation.Error("function_tool")
        }
        return Validation.Ok(root)
    }

    private fun isFunctionTool(tool: JsonObject): Boolean =
        (tool["type"] as? JsonPrimitive)?.takeIf { it.isString }?.content == "function" ||
            tool.keys.any { it in FUNCTION_TOOL_KEYS }

    /**
     * After the builder output and before the extra request body: `tools` is appended after the builder's tools (the whole segment is skipped when the Gemini builder already has functionDeclarations),
     * other keys are deep-merged, and on leaf / type conflicts the builder wins.
     */
    fun merge(transport: RelayTransport, builderBody: JsonObject, fragment: JsonObject): JsonObject {
        val merged = LinkedHashMap<String, JsonElement>(builderBody)
        for ((key, value) in fragment) {
            val existing = merged[key]
            merged[key] = when {
                key == "tools" -> mergeTools(transport, existing, value)
                existing == null -> value
                existing is JsonObject && value is JsonObject -> deepMerge(existing, value)
                else -> existing
            }
        }
        return JsonObject(merged)
    }

    private fun mergeTools(transport: RelayTransport, builder: JsonElement?, fragment: JsonElement): JsonElement {
        val builderTools = builder as? JsonArray ?: return builder ?: fragment
        val fragmentTools = fragment as? JsonArray ?: return builderTools
        val hasFunctionDeclarations = transport == RelayTransport.GeminiGenerateContent &&
            builderTools.any { (it as? JsonObject)?.keys?.any { key -> key in FUNCTION_TOOL_KEYS } == true }
        if (hasFunctionDeclarations) return builderTools
        return JsonArray(builderTools + fragmentTools)
    }

    private fun deepMerge(builder: JsonObject, fragment: JsonObject): JsonObject {
        val merged = LinkedHashMap<String, JsonElement>(builder)
        for ((key, value) in fragment) {
            val existing = merged[key]
            merged[key] = when {
                existing == null -> value
                existing is JsonObject && value is JsonObject -> deepMerge(existing, value)
                else -> existing
            }
        }
        return JsonObject(merged)
    }

    /** Merge point of the relay chat builder: merges only when this request carries an effective fragment for that transport; otherwise returns unchanged. */
    internal fun applyTo(bodyJson: String, transport: RelayTransport, requestOptions: ChatRequestOptions): String {
        val fragment = requestOptions.relayWebFragments[transport.value] ?: return bodyJson
        val body = runCatching { Json.parseToJsonElement(bodyJson) as? JsonObject }.getOrNull() ?: return bodyJson
        return merge(transport, body, fragment).toString()
    }

    /** The profile used for citation parsing is inferred from the fragment merged in this round (fixture `citationCases`); null = no citation shape. */
    fun citationProfile(transport: RelayTransport, fragment: JsonObject?): String? {
        if (fragment == null) return null
        val tools = (fragment["tools"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
        fun toolType(tool: JsonObject) = (tool["type"] as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()
        return when (transport) {
            RelayTransport.OpenAIResponses ->
                "oai_responses_web".takeIf { tools.any { toolType(it).startsWith("web_search") } }
            RelayTransport.AnthropicMessages ->
                "ant_web_tool".takeIf { tools.any { toolType(it).startsWith("web_search_") } }
            RelayTransport.GeminiGenerateContent -> "gem_web".takeIf {
                tools.any { tool ->
                    tool.keys.any { it in setOf("googleSearch", "google_search", "googleSearchRetrieval", "google_search_retrieval") }
                }
            }
            RelayTransport.OpenAIChatCompletions -> when {
                (fragment["plugins"] as? JsonArray).orEmpty()
                    .any { ((it as? JsonObject)?.get("id") as? JsonPrimitive)?.content == "web" } -> "or_web"
                "web_search_options" in fragment -> "oai_web_tool"
                tools.any { toolType(it) == "web_search" } -> "zhipu_web"
                else -> null
            }
            RelayTransport.Auto, RelayTransport.LlamaCppNative -> null
        }
    }
}

/**
 * Local key-value store `relay_web_fragments.v1`: key = connection id, value = the raw text of `{transport: JSON object}`.
 * Stored locally only, never enters cloud sync or backups (excluded in backup_rules / data_extraction_rules), and the whole key is deleted when the connection is deleted.
 */
class RelayWebFragmentStore(private val store: Store) {
    interface Store {
        fun read(connectionId: String): String?
        fun write(connectionId: String, value: String?)
    }

    class MemoryStore : Store {
        private val values = LinkedHashMap<String, String>()
        @Synchronized override fun read(connectionId: String): String? = values[connectionId]
        @Synchronized override fun write(connectionId: String, value: String?) {
            if (value == null) values.remove(connectionId) else values[connectionId] = value
        }
    }

    /** The segments of this connection in storage; segments that cannot be read or are not objects are dropped. */
    fun stored(connectionId: String): Map<String, JsonObject> {
        val raw = store.read(connectionId) ?: return emptyMap()
        val root = runCatching { Json.parseToJsonElement(raw) as? JsonObject }.getOrNull() ?: return emptyMap()
        return root.mapNotNull { (transport, value) -> (value as? JsonObject)?.let { transport to it } }.toMap()
    }

    /** Store one segment: validate against the fixture's validateCases first, and do not write if it fails. */
    @Synchronized
    fun save(connectionId: String, transport: RelayTransport, raw: String): RelayWebFragments.Validation {
        val result = RelayWebFragments.validate(raw)
        if (result is RelayWebFragments.Validation.Ok) write(connectionId, stored(connectionId) + (transport.value to result.fragment))
        return result
    }

    @Synchronized
    fun clear(connectionId: String, transport: RelayTransport) {
        write(connectionId, stored(connectionId) - transport.value)
    }

    /** Settings page save: replace the whole set, empty = delete the whole key. */
    @Synchronized
    fun replace(connectionId: String, fragments: Map<RelayTransport, JsonObject>) {
        write(connectionId, fragments.mapKeys { it.key.value })
    }

    fun remove(connectionId: String) = store.write(connectionId, null)

    private fun write(connectionId: String, fragments: Map<String, JsonObject>) {
        store.write(connectionId, fragments.takeIf { it.isNotEmpty() }?.let { JsonObject(it).toString() })
    }

    /**
     * Effective fragments: if storage has any segment use storage only; otherwise map from the legacy fields in memory (not written back).
     * Local-engine connections and non-relay connections do not read fragments.
     */
    fun effective(
        provider: Provider,
        profileMergeParams: (String) -> JsonObject? = MetadataClient::webSearchDeclaredMergeParams,
    ): Map<String, JsonObject> {
        if (provider.kind != ProviderKind.Relay || !provider.relayRequested?.engineProfile.isNullOrBlank()) return emptyMap()
        return stored(provider.id).ifEmpty { provider.relayRequested.legacyWebFragments(profileMergeParams) }
    }

    /** Before startup and in unit tests there is no Context: fall back to in-process memory, same semantics but not persisted. */
    private object DefaultStore : Store {
        @Volatile var context: Context? = null
        private val memory = MemoryStore()

        private fun prefs() = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        override fun read(connectionId: String): String? {
            val prefs = prefs() ?: return memory.read(connectionId)
            return prefs.getString(connectionId, null)
        }

        override fun write(connectionId: String, value: String?) {
            val prefs = prefs() ?: return memory.write(connectionId, value)
            prefs.edit().apply { if (value == null) remove(connectionId) else putString(connectionId, value) }.apply()
        }
    }

    companion object {
        const val PREFS_NAME = "relay_web_fragments.v1"

        val shared: RelayWebFragmentStore = RelayWebFragmentStore(DefaultStore)

        fun configure(context: Context) {
            DefaultStore.context = context.applicationContext
        }
    }
}
