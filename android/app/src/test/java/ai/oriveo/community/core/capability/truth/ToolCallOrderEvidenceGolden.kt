package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.data.remote.MetadataClient
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put

/**
 * Server golden sample `shared/test-fixtures/capability/tool-call-order-evidence.v1.json`: the tool_call evidence is
 * produced by the server production path (TestToolCallOrderEvidenceGolden); the payloads are minimal catalog payloads with the evidence view embedded.
 * The whole sample is handed to the production decode / publish boundary; the evidence view is never written and candidates are never changed.
 * The time window is judged only by the injected clock [nowMs], so no truth is fabricated.
 */
internal object ToolCallOrderEvidenceGolden {
    private val json = Json { ignoreUnknownKeys = true }

    private val golden: JsonObject by lazy {
        json.parseToJsonElement(File(repoRoot(), "shared/test-fixtures/capability/tool-call-order-evidence.v1.json").readText()).jsonObject
    }
    private val subject: JsonObject get() = golden.getValue("subject").jsonObject

    val nowMs: Long get() = golden.getValue("clock").jsonObject.getValue("nowMs").jsonPrimitive.long
    val providerKey: String get() = subject.getValue("providerKind").jsonPrimitive.content
    val modelId: String get() = subject.getValue("modelId").jsonPrimitive.content
    val transport: String get() = subject.getValue("transport").jsonPrimitive.content

    /** expiresAt of the golden tool_call candidate (read-only, used to push the injected clock past the evidence window). */
    fun toolCallExpiresAt(variant: String): Long =
        golden.getValue("views").jsonObject.getValue(variant).jsonObject.getValue("full").jsonObject
            .getValue("candidates").jsonArray
            .first { it.jsonObject["key"]?.jsonPrimitive?.content == "tool_call" }
            .jsonObject.getValue("expiresAt").jsonPrimitive.long

    /**
     * Hands the whole golden payload (variant = supported / unsupported / missing, shape = full / lean) to the production decode / publish entry.
     * The top-level toolCall of the subject entry is rewritten only when [topLevelToolCall] is non-null; [modelFacts] are appended to the root by model id;
     * the root capability contract version is rewritten when [capabilityContractVersion] is non-null (below 2 means an old server).
     */
    fun client(
        variant: String,
        topLevelToolCall: JsonElement? = null,
        modelFacts: Map<String, Boolean> = emptyMap(),
        shape: String = "full",
        capabilityContractVersion: Int? = null,
        etag: String = "\"tool-call-order-golden\"",
    ): MetadataClient {
        var payload = golden.getValue("payloads").jsonObject.getValue(variant).jsonObject.getValue(shape).jsonObject
        if (topLevelToolCall != null) {
            val providers = payload.getValue("providers").jsonObject
            val provider = providers.getValue(providerKey).jsonObject
            val models = provider.getValue("models").jsonObject
            val entry = JsonObject(models.getValue(modelId).jsonObject + ("toolCall" to topLevelToolCall))
            val editedProvider = JsonObject(provider + ("models" to JsonObject(models + (modelId to entry))))
            payload = JsonObject(payload + ("providers" to JsonObject(providers + (providerKey to editedProvider))))
        }
        if (capabilityContractVersion != null) {
            payload = JsonObject(payload + ("capabilityContractVersion" to JsonPrimitive(capabilityContractVersion)))
        }
        if (modelFacts.isNotEmpty()) {
            payload = JsonObject(
                payload + mapOf(
                    "modelFactsRevision" to JsonPrimitive("sha256:tool-call-order-golden"),
                    "modelFacts" to buildJsonObject {
                        modelFacts.forEach { (id, toolCall) ->
                            put("$providerKey/${MetadataClient.normalizeModelFactsID(id)}", buildJsonObject { put("toolCall", toolCall) })
                        }
                    },
                ),
            )
        }
        return MetadataClient().apply { loadNetworkPayloadForTesting(payload.toString(), etag) }
    }

    private fun repoRoot(): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            if (File(dir, "shared/test-fixtures/capability").isDirectory) return dir
            dir = dir.parentFile
        }
        throw IllegalStateException("repository root not found")
    }
}
