package ai.oriveo.community.core.provider.openai

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Builds the `/responses` request body for Codex, the ChatGPT subscription sign-in path.
 *
 * This body is assembled here on its own instead of going through the capability-recipe
 * pipeline. That pipeline is keyed by models that appear in the metadata catalog, and it
 * drags along a chain of behaviours tied to them: recipe lookup, `previous_response_id`
 * threading, the 400 self-healing retry, the chat-completions fallback. Subscription models
 * are not in the catalog at all, so forcing them through it would both import a pile of
 * behaviour that does not belong on this path and silently drop fields whenever the recipe
 * lookup came back empty.
 *
 * The six hard constraints below were established by testing against the open-source Codex
 * client. They are not tuning knobs.
 */
object OpenAISubscriptionOutbound {

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * @param inputElementsJson The output of `MessageBuilder.buildOpenAIResponsesInput`: the
     *   element sequence *without* the enclosing square brackets. If it fails to parse we send
     *   an empty conversation rather than splicing malformed JSON into the body, because the
     *   upstream 400 that would come back names a cause unrelated to what actually went wrong.
     * @param webSearchRequested What the user asked for on this turn.
     * @param webSearchDeclared What upstream `/models` declares for *this particular model*.
     *   These are deliberately two parameters: collapsing them into one boolean loses the
     *   difference between "the user did not turn it on" and "upstream does not support it",
     *   and those are two completely different things to tell the user.
     * @param declaredReasoningLevels The effort levels upstream declares. Empty means never
     *   inject an effort at all.
     */
    fun buildResponsesBody(
        modelID: String,
        inputElementsJson: String,
        systemPrompt: String?,
        webSearchRequested: Boolean,
        webSearchDeclared: Boolean,
        reasoningMode: String?,
        declaredReasoningLevels: List<String>,
    ): String {
        val input = runCatching {
            json.parseToJsonElement("[$inputElementsJson]") as? JsonArray
        }.getOrNull() ?: JsonArray(emptyList())

        val body = buildJsonObject {
            put("model", modelID)
            put("input", input)
            put("stream", true)
            // Codex rejects store:true. This is a hard constraint, not a configurable option.
            put("store", false)
            // Encrypted reasoning has to be requested explicitly, otherwise the next turn has
            // nothing to continue from.
            putJsonArray("include") { add("reasoning.encrypted_content") }

            systemPrompt?.trim()?.takeIf { it.isNotEmpty() }?.let { put("instructions", it) }

            // Web search requires user intent AND an upstream declaration. If either is
            // missing we send no tool at all: attaching a tool upstream never declared gets
            // the whole request rejected, which is far worse than search quietly not running.
            if (webSearchRequested && webSearchDeclared) {
                putJsonArray("tools") { addJsonObject { put("type", "web_search") } }
            }

            codexReasoningEffort(reasoningMode, declaredReasoningLevels)?.let { effort ->
                // The Codex backend accepts summary:"auto" and streams reasoning summary
                // deltas in response to it.
                putJsonObject("reasoning") {
                    put("effort", effort)
                    put("summary", "auto")
                }
            }
        }
        return body.toString()
    }
}
