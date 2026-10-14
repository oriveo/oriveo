package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.EngineDeclaration
import ai.oriveo.community.core.model.RelayTransport
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/** The wire values of `RelayRequestedConfig.engineProfile`. */
internal val LocalEngineKind.wireName: String
    get() = when (this) {
        LocalEngineKind.LlamaCpp -> "llamacpp"
        LocalEngineKind.Ollama -> "ollama"
        LocalEngineKind.LmStudio -> "lmstudio"
        LocalEngineKind.Vllm -> "vllm"
        LocalEngineKind.OpenWebUI -> "openwebui"
    }

enum class LocalEngineFingerprintOutcome(val wireValue: String) {
    Engine("engine"),
    Generic("generic"),
    Manual("manual"),
}

/** Fingerprint result: engine carries engineProfile; engine / generic use the default channel chat; manual carries nothing. */
data class LocalEngineFingerprint(
    val outcome: LocalEngineFingerprintOutcome,
    val engineProfile: String? = null,
    val channel: RelayTransport? = null,
) {
    companion object {
        val manual = LocalEngineFingerprint(LocalEngineFingerprintOutcome.Manual)
    }
}

/**
 * Local-engine fingerprint rules. The status code itself never decides the result -- LM Studio answers an unknown path with
 * 200 + `{"error": ...}` -- only a 2xx with a correctly shaped JSON object is a hit.
 */
object LocalEngineFingerprintRules {
    val requests: List<String> = listOf("/props", "/api/tags", "/api/v0/models", "/version", "/v1/models")

    /** [responses] holds only paths that returned 2xx and parsed as a JSON object; the others (non-2xx, non-JSON, network failure) are not put in. */
    fun decide(responses: Map<String, JsonObject>): LocalEngineFingerprint {
        val hits = buildList {
            responses["/props"]?.let { body ->
                if (body["modalities"] is JsonObject || body["default_generation_settings"] is JsonObject) add(LocalEngineKind.LlamaCpp)
            }
            responses["/api/tags"]?.let { body ->
                if (body.rowsAll("models") { (it["name"] as? JsonPrimitive)?.isString == true }) add(LocalEngineKind.Ollama)
            }
            responses["/api/v0/models"]?.let { body ->
                if (body.rowsAll("data") { (it["type"] as? JsonPrimitive)?.isString == true }) add(LocalEngineKind.LmStudio)
            }
            responses["/version"]?.let { body ->
                if ((body["version"] as? JsonPrimitive)?.isString == true && "error" !in body) add(LocalEngineKind.Vllm)
            }
        }
        return when {
            hits.size == 1 -> LocalEngineFingerprint(
                LocalEngineFingerprintOutcome.Engine,
                engineProfile = hits.single().wireName,
                channel = RelayTransport.OpenAIChatCompletions,
            )
            hits.size > 1 -> LocalEngineFingerprint.manual
            responses["/v1/models"]?.get("data") is JsonArray ->
                LocalEngineFingerprint(LocalEngineFingerprintOutcome.Generic, channel = RelayTransport.OpenAIChatCompletions)
            else -> LocalEngineFingerprint.manual
        }
    }

    private fun JsonObject.rowsAll(key: String, predicate: (JsonObject) -> Boolean): Boolean {
        val rows = this[key] as? JsonArray ?: return false
        return rows.all { row -> (row as? JsonObject)?.let(predicate) == true }
    }
}

/**
 * Per-model capability declarations: read only the responses the connector already requests, sending no extra request.
 * A missing value = unknown (null); vLLM / Open WebUI declare nothing.
 */
object LocalEngineDeclarations {
    /** LM Studio embeddings models do not enter the chat catalog. */
    fun isChatModel(engine: LocalEngineKind, row: JsonObject): Boolean =
        !(engine == LocalEngineKind.LmStudio && row.string("type") == "embeddings")

    /**
     * [catalog] is the catalog response (Ollama `/api/tags`, LM Studio `/api/v0/models`), [props] is llama.cpp's
     * `/props`, which applies to every model of this connection. The returned map contains only models that made a declaration.
     */
    fun parse(
        engine: LocalEngineKind,
        catalog: JsonObject?,
        props: JsonObject?,
        modelIds: List<String>,
    ): Map<String, EngineDeclaration> {
        val declarations: Map<String, EngineDeclaration> = when (engine) {
            LocalEngineKind.Ollama -> catalog.rows("models").mapNotNull { row ->
                val id = row.string("name") ?: return@mapNotNull null
                val words = (row["capabilities"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
                    ?: return@mapNotNull id to EngineDeclaration()
                id to EngineDeclaration(image = "vision" in words, toolCall = "tools" in words, thinking = "thinking" in words)
            }.toMap()
            LocalEngineKind.LmStudio -> catalog.rows("data").filter { isChatModel(engine, it) }.mapNotNull { row ->
                val id = row.string("id") ?: return@mapNotNull null
                val image = when (row.string("type")) {
                    "vlm" -> true
                    "llm" -> false
                    else -> null
                }
                val toolCall = (row["capabilities"] as? JsonArray)?.let { caps ->
                    caps.any { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content == "tool_use" }
                }
                id to EngineDeclaration(image = image, toolCall = toolCall)
            }.toMap()
            LocalEngineKind.LlamaCpp -> {
                val image = ((props?.get("modalities") as? JsonObject)?.get("vision") as? JsonPrimitive)
                    ?.takeIf { !it.isString }?.booleanOrNull
                // supports_tools=false is not a negative declaration, treated only as unknown.
                val toolCall = ((props?.get("chat_template_caps") as? JsonObject)?.get("supports_tools") as? JsonPrimitive)
                    ?.takeIf { !it.isString }?.booleanOrNull?.takeIf { it }
                val declaration = EngineDeclaration(image = image, toolCall = toolCall)
                modelIds.associateWith { declaration }
            }
            LocalEngineKind.Vllm, LocalEngineKind.OpenWebUI -> emptyMap()
        }
        return declarations.filterKeys { it in modelIds }.filterValues { !it.isEmpty }
    }

    private fun JsonObject?.rows(key: String): List<JsonObject> =
        (this?.get(key) as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
}
