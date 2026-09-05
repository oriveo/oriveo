package ai.oriveo.community.core.provider

import android.content.Context
import io.ktor.client.HttpClient
import io.ktor.client.request.post
import io.ktor.client.request.get
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.client.request.header
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

@Serializable
data class LocalRuntimeSettings(
    val contextLength: Int? = null,
    val keepAlive: String? = null,
    val speculativeModel: String? = null,
    val cacheReuseTokens: Int? = null,
)

class LocalRuntimeSettingsStore private constructor(private val context: Context, private val json: Json) {
    private val preferences = context.applicationContext.getSharedPreferences("local_runtime_settings", Context.MODE_PRIVATE)

    fun load(endpointFingerprint: String): LocalRuntimeSettings = preferences.getString(endpointFingerprint, null)?.let {
        runCatching { json.decodeFromString(LocalRuntimeSettings.serializer(), it) }.getOrNull()
    } ?: LocalRuntimeSettings()

    fun save(endpointFingerprint: String, settings: LocalRuntimeSettings) {
        preferences.edit().putString(endpointFingerprint, json.encodeToString(LocalRuntimeSettings.serializer(), settings)).apply()
    }

    fun remove(endpointFingerprint: String) { preferences.edit().remove(endpointFingerprint).apply() }

    companion object {
        fun from(context: Context, json: Json = Json { ignoreUnknownKeys = true }) = LocalRuntimeSettingsStore(context, json)
        fun fingerprint(endpoint: String, engine: LocalEngineKind): String =
            (engine.name + "|" + endpoint).fold(0xcbf29ce484222325UL) { hash, char -> (hash xor char.code.toULong()) * 0x100000001b3UL }.toString(16)
    }
}

data class LocalRuntimeSnapshot(
    val health: LocalEngineState? = null,
    val loadedModelIDs: List<String> = emptyList(),
    val ttftMilliseconds: Double? = null,
    val tokensPerSecond: Double? = null,
    val contextUsed: Int? = null,
    val contextLimit: Int? = null,
    val queueDepth: Int? = null,
    val cpuPercent: Double? = null,
    val gpuPercent: Double? = null,
)

sealed interface LocalPromptPreflight {
    data class Supported(val tokens: Int, val contextLimit: Int?, val exceedsContext: Boolean) : LocalPromptPreflight
    data object Unavailable : LocalPromptPreflight
}

/** Parses real engine responses; missing measurements remain null and are rendered as unavailable. */
object LocalRuntimeParser {
    fun snapshot(status: JsonElement?, metricsText: String? = null, timings: JsonObject? = null): LocalRuntimeSnapshot {
        val root = status as? JsonObject ?: JsonObject(emptyMap())
        val slots = (root["slots"] as? JsonArray) ?: (status as? JsonArray) ?: JsonArray(emptyList())
        val models = (root["models"] as? JsonArray) ?: (root["data"] as? JsonArray) ?: JsonArray(emptyList())
        val loaded = models.mapNotNull { row ->
            val objectValue = row as? JsonObject ?: return@mapNotNull null
            listOf("name", "model", "id").firstNotNullOfOrNull { objectValue[it]?.jsonPrimitive?.content }
        }.distinct().sorted()
        val timing = timings ?: (root["timings"] as? JsonObject) ?: JsonObject(emptyMap())
        val predictedMilliseconds = timing.number("predicted_ms") ?: timing.durationMilliseconds("eval_duration")
        val predictedTokens = timing.number("predicted_n") ?: timing.number("eval_count")
        val metrics = parsePrometheus(metricsText)
        val contextUsed = root.integer("n_past") ?: slots.mapNotNull { (it as? JsonObject)?.integer("n_past") }.maxOrNull()
        val contextLimit = root.integer("n_ctx") ?: root.integer("context_length")
            ?: slots.mapNotNull { (it as? JsonObject)?.integer("n_ctx") }.maxOrNull()
        return LocalRuntimeSnapshot(
            health = if (root.isEmpty() && slots.isEmpty()) null else LocalEngineState.Ready,
            loadedModelIDs = loaded,
            ttftMilliseconds = timing.number("prompt_ms") ?: timing.durationMilliseconds("prompt_eval_duration"),
            tokensPerSecond = timing.number("predicted_per_second") ?: timing.number("tokens_per_second")
                ?: if (predictedMilliseconds != null && predictedMilliseconds > 0 && predictedTokens != null) predictedTokens / predictedMilliseconds * 1_000 else null,
            contextUsed = contextUsed,
            contextLimit = contextLimit,
            queueDepth = root.integer("queue") ?: root.integer("queue_depth") ?: metrics.firstSuffix("requests_waiting")?.toInt(),
            cpuPercent = root.number("cpu_percent") ?: metrics.firstSuffix("cpu_percent"),
            gpuPercent = root.number("gpu_percent") ?: metrics.firstSuffix("gpu_percent"),
        )
    }

    fun tokenCount(value: JsonElement?): Int? = when (value) {
        is JsonArray -> value.size
        is JsonObject -> (value["tokens"] as? JsonArray)?.size
            ?: value["count"]?.jsonPrimitive?.intOrNull
            ?: value["n_tokens"]?.jsonPrimitive?.intOrNull
        else -> null
    }

    private fun JsonObject.number(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull
    private fun JsonObject.integer(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
    private fun JsonObject.durationMilliseconds(key: String): Double? = number(key)?.let { if (it > 1_000_000) it / 1_000_000 else it }
    private fun parsePrometheus(text: String?): Map<String, Double> = text.orEmpty().lineSequence().mapNotNull { line ->
        if (line.startsWith('#')) return@mapNotNull null
        val parts = line.trim().split(Regex("\\s+"))
        if (parts.size < 2) null else parts.first() to (parts.last().toDoubleOrNull() ?: return@mapNotNull null)
    }.toMap()
    private fun Map<String, Double>.firstSuffix(suffix: String): Double? = entries.firstOrNull { it.key.endsWith(suffix) }?.value
}

class LocalEngineRuntimeClient(private val client: HttpClient, private val json: Json) {
    suspend fun status(endpoint: String, engine: LocalEngineKind, apiKey: String = ""): LocalRuntimeSnapshot {
        val path = when (engine) {
            LocalEngineKind.LlamaCpp -> "/slots"
            LocalEngineKind.Ollama -> "/api/ps"
            LocalEngineKind.LmStudio -> "/api/v1/models"
            LocalEngineKind.Vllm -> "/v1/models"
            LocalEngineKind.OpenWebUI -> "/api/models"
        }
        val status = getBody(endpoint, path, apiKey)?.let { runCatching { json.parseToJsonElement(it) }.getOrNull() }
        val metrics = if (engine == LocalEngineKind.LlamaCpp || engine == LocalEngineKind.Vllm) getBody(endpoint, "/metrics", apiKey) else null
        return LocalRuntimeParser.snapshot(status, metrics)
    }

    suspend fun preflight(endpoint: String, engine: LocalEngineKind, prompt: String, contextLimit: Int?): LocalPromptPreflight {
        if (engine != LocalEngineKind.LlamaCpp) return LocalPromptPreflight.Unavailable
        return runCatching {
            val templated = postJSON(endpoint, "/apply-template", buildJsonObject {
                put("prompt", prompt)
                put("add_generation_prompt", true)
            })
            val finalPrompt = (templated as? JsonObject)?.get("prompt")?.jsonPrimitive?.content ?: prompt
            val tokenized = postJSON(endpoint, "/tokenize", buildJsonObject { put("content", finalPrompt) })
            val count = LocalRuntimeParser.tokenCount(tokenized) ?: return@runCatching LocalPromptPreflight.Unavailable
            val observedLimit = contextLimit ?: status(endpoint, engine).contextLimit
            LocalPromptPreflight.Supported(count, observedLimit, observedLimit?.let { count > it } ?: false)
        }.getOrDefault(LocalPromptPreflight.Unavailable)
    }

    suspend fun promptCache(endpoint: String, slotID: Int, action: String, cacheName: String) {
        require(slotID >= 0 && action in setOf("save", "restore"))
        postJSON(endpoint, "/slots/$slotID?action=$action&filename=${java.net.URLEncoder.encode(cacheName, Charsets.UTF_8.name())}", JsonObject(emptyMap()))
    }

    private suspend fun postJSON(endpoint: String, path: String, body: JsonObject): JsonElement? {
        val response = client.post(endpoint.trimEnd('/') + path) {
            header(HttpHeaders.ContentType, ContentType.Application.Json)
            setBody(body.toString())
        }
        if (response.status.value !in 200..299) error("local runtime request rejected")
        return response.bodyAsText().takeIf(String::isNotBlank)?.let(json::parseToJsonElement)
    }

    private suspend fun getBody(endpoint: String, path: String, apiKey: String = ""): String? = runCatching {
        val response = client.get(endpoint.trimEnd('/') + path) {
            if (apiKey.isNotEmpty()) header(HttpHeaders.Authorization, "Bearer $apiKey")
        }
        if (response.status.value !in 200..299) return@runCatching null
        response.bodyAsText()
    }.getOrNull()
}
