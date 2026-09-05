package ai.oriveo.community.core.provider.grok

import ai.oriveo.community.core.provider.openai.codexReasoningEffort
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/** Request builder for the Responses endpoint of the Grok subscription proxy. */
object GrokSubscriptionOutbound {
    private val json = Json { ignoreUnknownKeys = true }

    fun buildResponsesBody(
        modelID: String,
        inputElementsJson: String,
        systemPrompt: String?,
        supportsWebSearch: Boolean,
        reasoningMode: String?,
        declaredReasoningLevels: List<String>,
        defaultReasoningLevel: String?,
        stream: Boolean = true,
    ): String {
        val input = runCatching {
            json.parseToJsonElement("[$inputElementsJson]") as? JsonArray
        }.getOrNull() ?: JsonArray(emptyList())
        val effort = if (reasoningMode == "automatic") {
            defaultReasoningLevel?.takeIf { it in declaredReasoningLevels }
        } else {
            codexReasoningEffort(reasoningMode, declaredReasoningLevels)
        }

        return buildJsonObject {
            put("model", modelID)
            put("input", input)
            if (stream) put("stream", true)
            put("store", false)
            systemPrompt?.trim()?.takeIf { it.isNotEmpty() }?.let { put("instructions", it) }

            // The proxy advertises web search to its model harness. Omitting the real tool makes
            // the model emit fake <web_search> text, so this capability is always-on when declared.
            if (supportsWebSearch) {
                putJsonArray("tools") { addJsonObject { put("type", "web_search") } }
            }
            effort?.let {
                putJsonObject("reasoning") {
                    put("effort", it)
                    put("summary", "auto")
                }
            }
        }.toString()
    }
}
