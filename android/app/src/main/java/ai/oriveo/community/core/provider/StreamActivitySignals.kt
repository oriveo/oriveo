package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.StreamActivity
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * The closed set of "an activity has started" signals.
 *
 * Only a structured frame observed on the wire counts. The user having web search switched on,
 * the model declaring search support, the provider kind or model id, and an HTTP 200 are not
 * observations and must not be turned into one here. An unknown value always returns null; it is
 * never downgraded to some known activity.
 */
internal object StreamActivitySignals {
    private const val MOONSHOT_BUILTIN_WEB_SEARCH = "\$web_search"

    /**
     * Anthropic Messages: a server tool block opens. A client `tool_use` block is not a waiting
     * state; it ends up in a result card instead.
     */
    fun anthropicMessages(eventType: String?, root: JsonObject): StreamActivity? {
        if ((eventType ?: primitive(root, "type")) != "content_block_start") return null
        val block = root["content_block"] as? JsonObject ?: return null
        if (primitive(block, "type") != "server_tool_use") return null
        return if (primitive(block, "name") == "web_search") StreamActivity.WebSearch else null
    }

    /**
     * OpenAI Responses: only `output_item.added` counts. `output_item.done` means the search has
     * already finished, so using it as the start signal would light the label after the results
     * are back.
     */
    fun openAIResponses(eventType: String?, root: JsonObject): StreamActivity? {
        if ((eventType?.takeIf { it.isNotBlank() } ?: primitive(root, "type")) != "response.output_item.added") {
            return null
        }
        val item = root["item"] as? JsonObject ?: return null
        return if (primitive(item, "type") == "web_search_call") StreamActivity.WebSearch else null
    }

    /** Moonshot's client-side tool loop: the name of a tool call accumulated in this leg. */
    fun moonshotToolCall(name: String?): StreamActivity? =
        if (name == MOONSHOT_BUILTIN_WEB_SEARCH) StreamActivity.WebSearch else null

    private fun primitive(objectValue: JsonObject, key: String): String? =
        (objectValue[key] as? JsonPrimitive)?.contentOrNull
}
