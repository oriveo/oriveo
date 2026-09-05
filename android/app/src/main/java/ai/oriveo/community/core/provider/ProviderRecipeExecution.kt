package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RequestPreferenceResolver
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

/** Protocol-aware continuation mapping and the boundary for lossless custom fragments.
 *
 * These functions only produce a wire delta. Where no recipe applies, the caller has to ignore the
 * result and send an ordinary chat request instead.
 */
internal object ProviderRecipeExecution {
    sealed interface ContinuationWire {
        data class Body(val delta: JsonObject) : ContinuationWire
        data class Messages(val append: JsonArray) : ContinuationWire
        data class Contents(val append: JsonArray) : ContinuationWire
        data class Rejected(val reason: String) : ContinuationWire
    }

    fun continuation(
        kind: String,
        variant: String?,
        protocol: String,
        responseParserKind: String? = null,
        intent: RequestPreferenceResolver.ContinuationIntent?,
    ): ContinuationWire {
        if (intent == null || intent.kind != kind || intent.variant != variant ||
            !RequestPreferenceResolver.validateContinuation(intent).accepted
        ) return ContinuationWire.Rejected("invalid_continuation")
        val state = intent.state
        return when (kind) {
            "none" -> ContinuationWire.Body(JsonObject(emptyMap()))
            "previous_id" -> {
                val id = (state["previousResponseId"] as? JsonPrimitive)?.contentOrNull
                    ?: return ContinuationWire.Rejected("invalid_continuation")
                when (protocol) {
                    "openai_responses" -> ContinuationWire.Body(JsonObject(mapOf("previous_response_id" to JsonPrimitive(id))))
                    "gemini_interactions" -> ContinuationWire.Body(JsonObject(mapOf("previous_interaction_id" to JsonPrimitive(id))))
                    else -> ContinuationWire.Rejected("unsupported_wire_mapping")
                }
            }
            "replay_blocks" -> {
                val blocks = state["blocks"] as? JsonArray ?: return ContinuationWire.Rejected("invalid_continuation")
                when (protocol) {
                    "anthropic_messages" -> ContinuationWire.Messages(JsonArray(listOf(JsonObject(mapOf("role" to JsonPrimitive("assistant"), "content" to blocks)))))
                    "gemini_generate_content" -> ContinuationWire.Contents(blocks)
                    else -> ContinuationWire.Rejected("unsupported_wire_mapping")
                }
            }
            "replay_reasoning" -> {
                val assistantMessages = state["assistantMessages"] as? JsonArray ?: return ContinuationWire.Rejected("invalid_continuation")
                if (protocol != "openai_chat") return ContinuationWire.Rejected("unsupported_wire_mapping")
                if (!isValidReasoningReplay(assistantMessages, responseParserKind)) {
                    return ContinuationWire.Rejected("invalid_continuation")
                }
                ContinuationWire.Messages(assistantMessages)
            }
            "tool_loop" -> {
                if (protocol != "openai_chat" || variant !in setOf("default", "fiber")) return ContinuationWire.Rejected("unsupported_wire_mapping")
                val messages = state["completedMessages"] as? JsonArray ?: return ContinuationWire.Rejected("invalid_continuation")
                // A local tool loop is atomic: assistant tool_calls and their tool replies must be
                // replayed as the exact saved message block, not reconstructed from identifiers.
                if (!isCompleteToolLoop(messages)) return ContinuationWire.Rejected("invalid_tool_loop_state")
                ContinuationWire.Messages(messages)
            }
            else -> ContinuationWire.Rejected("invalid_continuation")
        }
    }

    private fun isValidReasoningReplay(messages: JsonArray, parserKind: String?): Boolean {
        if (messages.isEmpty()) return false
        return messages.all { raw ->
            val message = raw as? JsonObject ?: return@all false
            if ((message["role"] as? JsonPrimitive)?.contentOrNull != "assistant") return@all false
            when (parserKind) {
                "openrouter_reasoning_v1" -> message["reasoning_details"] is JsonArray
                "moonshot_reasoning_v1" -> (message["reasoning_content"] as? JsonPrimitive)?.contentOrNull != null
                "deepseek_reasoning_v1" -> {
                    if ((message["reasoning_content"] as? JsonPrimitive)?.contentOrNull == null) return@all false
                    val calls = message["tool_calls"] as? JsonArray ?: return@all true
                    calls.all(::isValidToolCall)
                }
                "mistral_reasoning_v1" -> RequestPreferenceResolver.isMistralReasoningAssistantMessage(message)
                "minimax_reasoning_v1" -> isValidMiniMaxReasoningMessage(message)
                else -> false
            }
        }
    }

    private fun isValidToolCall(raw: JsonElement): Boolean {
        val call = raw as? JsonObject ?: return false
        val function = call["function"] as? JsonObject ?: return false
        return (call["id"] as? JsonPrimitive)?.contentOrNull?.isNotBlank() == true &&
            (call["type"] as? JsonPrimitive)?.contentOrNull in setOf("function", "builtin_function") &&
            (function["name"] as? JsonPrimitive)?.contentOrNull?.isNotBlank() == true &&
            (function["arguments"] as? JsonPrimitive)?.contentOrNull != null
    }

    private fun isValidMiniMaxReasoningMessage(message: JsonObject): Boolean {
        val content = message["content"]
        if (message.keys.any { it !in setOf("role", "content", "reasoning_details", "tool_calls") } ||
            "content" !in message ||
            (content != kotlinx.serialization.json.JsonNull && (content !is JsonPrimitive || !content.isString))
        ) return false
        val details = message["reasoning_details"] as? JsonArray ?: return false
        if (details.isEmpty() || details.any { it !is JsonObject }) return false
        val calls = message["tool_calls"] as? JsonArray ?: return true
        return calls.isNotEmpty() && calls.all { raw ->
            val call = raw as? JsonObject ?: return@all false
            val function = call["function"] as? JsonObject ?: return@all false
            call.keys.all { it in setOf("id", "type", "function") } &&
                function.keys.all { it in setOf("name", "arguments") } &&
                (call["id"] as? JsonPrimitive)?.contentOrNull?.isNotBlank() == true &&
                (call["type"] as? JsonPrimitive)?.contentOrNull == "function" &&
                (function["name"] as? JsonPrimitive)?.contentOrNull?.isNotBlank() == true &&
                (function["arguments"] as? JsonPrimitive)?.contentOrNull != null
        }
    }

    private fun isCompleteToolLoop(messages: JsonArray): Boolean {
        val calls = linkedSetOf<String>()
        val pending = ArrayDeque<String>()
        for (element in messages) {
            val message = element as? JsonObject ?: return false
            when ((message["role"] as? JsonPrimitive)?.contentOrNull) {
                "assistant" -> {
                    if (pending.isNotEmpty()) return false
                    val toolCalls = message["tool_calls"] as? JsonArray ?: return false
                    if (toolCalls.isEmpty()) return false
                    toolCalls.forEach { raw ->
                        val call = raw as? JsonObject ?: return false
                        val id = (call["id"] as? JsonPrimitive)?.contentOrNull ?: return false
                        if (!isValidToolCall(call) || !calls.add(id)) return false
                        pending.addLast(id)
                    }
                }
                "tool" -> {
                    val id = (message["tool_call_id"] as? JsonPrimitive)?.contentOrNull ?: return false
                    if ((message["content"] as? JsonPrimitive)?.contentOrNull == null ||
                        pending.removeFirstOrNull() != id
                    ) return false
                }
                else -> return false
            }
        }
        return calls.isNotEmpty() && pending.isEmpty()
    }

    data class CustomResult(val accepted: Boolean, val reason: String? = null, val delta: JsonObject? = null, val preview: JsonObject? = null)

    /** Losslessly accumulates the provider-owned assistant block used by replay_reasoning. */
    class ReasoningAssistantAccumulator(private val parserKind: String) {
        private val miniMaxAccumulator = if (parserKind == "minimax_reasoning_v1") MiniMaxReasoningAccumulator() else null
        private val content = StringBuilder()
        private var mistralContent: JsonElement? = null
        private var invalidMistralContent = false
        private val reasoning = StringBuilder()
        private var sawReasoning = false
        private val details = mutableListOf<JsonElement>()
        private data class Call(var id: String? = null, var type: String? = null, var name: String? = null, val arguments: StringBuilder = StringBuilder())
        private val calls = sortedMapOf<Int, Call>()

        fun ingest(delta: JsonObject, completeMessage: Boolean = false) {
            miniMaxAccumulator?.let {
                it.ingest(delta, completeMessage)
                return
            }
            if (parserKind == "mistral_reasoning_v1" && "content" in delta) {
                val incoming = delta["content"]
                if (completeMessage) {
                    if (incoming != null && isValidMistralContent(incoming)) mistralContent = incoming
                    else invalidMistralContent = true
                } else if (incoming == null || !mergeMistralContent(incoming)) {
                    invalidMistralContent = true
                }
            } else {
                (delta["content"] as? JsonPrimitive)?.contentOrNull?.let(content::append)
            }
            val reasoningFragment = (delta["reasoning_content"] ?: delta["reasoning"]) as? JsonPrimitive
            reasoningFragment?.contentOrNull?.let {
                sawReasoning = true
                reasoning.append(it)
            }
            (delta["reasoning_details"] as? JsonArray)?.let(details::addAll)
            (delta["tool_calls"] as? JsonArray)?.forEach { raw ->
                val objectCall = raw as? JsonObject ?: return@forEach
                val index = (objectCall["index"] as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 0
                val call = calls.getOrPut(index) { Call() }
                (objectCall["id"] as? JsonPrimitive)?.contentOrNull?.let { call.id = it }
                (objectCall["type"] as? JsonPrimitive)?.contentOrNull?.let { call.type = it }
                val function = objectCall["function"] as? JsonObject
                (function?.get("name") as? JsonPrimitive)?.contentOrNull?.let { call.name = it }
                (function?.get("arguments") as? JsonPrimitive)?.contentOrNull?.let(call.arguments::append)
            }
        }

        fun stateOrNull(): JsonObject? {
            miniMaxAccumulator?.let { return it.stateOrNull() }
            if (parserKind == "mistral_reasoning_v1" && (invalidMistralContent || mistralContent == null)) return null
            val message = linkedMapOf<String, JsonElement>(
                "role" to JsonPrimitive("assistant"),
                "content" to (mistralContent ?: JsonPrimitive(content.toString())),
            )
            when (parserKind) {
                "openrouter_reasoning_v1" -> if (details.isNotEmpty()) message["reasoning_details"] = JsonArray(details)
                "moonshot_reasoning_v1", "deepseek_reasoning_v1" -> if (sawReasoning) {
                    // Kimi may emit an explicit empty reasoning heartbeat before a tool call. The
                    // next leg still requires reasoning_content to be present; absence is a 400.
                    message["reasoning_content"] = JsonPrimitive(reasoning.toString())
                }
                "mistral_reasoning_v1" -> Unit
                else -> return null
            }
            if (calls.isNotEmpty()) {
                val finalized = calls.values.map { call ->
                    val id = call.id ?: return null
                    val type = call.type ?: return null
                    val name = call.name ?: return null
                    buildJsonObject {
                        put("id", JsonPrimitive(id)); put("type", JsonPrimitive(type))
                        put("function", buildJsonObject { put("name", JsonPrimitive(name)); put("arguments", JsonPrimitive(call.arguments.toString())) })
                    }
                }
                message["tool_calls"] = JsonArray(finalized)
            }
            val array = JsonArray(listOf(JsonObject(message)))
            return JsonObject(mapOf("assistantMessages" to array)).takeIf { isValidReasoningReplay(array, parserKind) }
        }

        private fun mergeMistralContent(incoming: JsonElement): Boolean {
            if (incoming is JsonPrimitive && incoming.isString) {
                mistralContent = when (val current = mistralContent) {
                    null -> JsonPrimitive(incoming.content)
                    is JsonPrimitive -> if (current.isString) JsonPrimitive(current.content + incoming.content) else return false
                    is JsonArray -> JsonArray(current.toMutableList().also { blocks ->
                        if (incoming.content.isNotEmpty()) appendMistralBlock(blocks, textBlock(incoming.content))
                    })
                    else -> return false
                }
                return true
            }
            if (incoming !is JsonArray || !isValidMistralContent(incoming)) return false
            val blocks = when (val current = mistralContent) {
                null -> mutableListOf()
                is JsonPrimitive -> if (current.isString) mutableListOf<JsonElement>().also {
                    if (current.content.isNotEmpty()) it += textBlock(current.content)
                } else return false
                is JsonArray -> current.toMutableList()
                else -> return false
            }
            incoming.forEach { appendMistralBlock(blocks, it) }
            mistralContent = JsonArray(blocks)
            return true
        }

        private fun appendMistralBlock(target: MutableList<JsonElement>, raw: JsonElement) {
            val block = raw as JsonObject
            val previous = target.lastOrNull() as? JsonObject
            when {
                block["type"]?.let { (it as? JsonPrimitive)?.contentOrNull } == "thinking" &&
                    previous?.get("type")?.let { (it as? JsonPrimitive)?.contentOrNull } == "thinking" -> {
                    val merged = previous.toMutableMap()
                    merged["thinking"] = JsonArray((previous["thinking"] as JsonArray) + (block["thinking"] as JsonArray))
                    block["closed"]?.let { merged["closed"] = it }
                    target[target.lastIndex] = JsonObject(merged)
                }
                block["type"]?.let { (it as? JsonPrimitive)?.contentOrNull } == "text" &&
                    previous?.get("type")?.let { (it as? JsonPrimitive)?.contentOrNull } == "text" -> {
                    val merged = previous.toMutableMap()
                    merged["text"] = JsonPrimitive(
                        (previous["text"] as JsonPrimitive).content + (block["text"] as JsonPrimitive).content,
                    )
                    target[target.lastIndex] = JsonObject(merged)
                }
                else -> target += block
            }
        }

        private fun textBlock(text: String): JsonObject = buildJsonObject {
            put("type", "text")
            put("text", text)
        }

        private fun isValidMistralContent(content: JsonElement): Boolean {
            val probe = JsonObject(mapOf("role" to JsonPrimitive("assistant"), "content" to content))
            return RequestPreferenceResolver.isMistralReasoningAssistantMessage(probe)
        }
    }

    /** Strict MiniMax `reasoning_split` assistant reconstruction; malformed fragments poison the leg. */
    private class MiniMaxReasoningAccumulator {
        private var content: JsonElement? = null
        private var contentSeen = false
        private var invalid = false
        private val details = sortedMapOf<Int, JsonObject>()
        private data class Call(
            var id: String? = null,
            var type: String? = null,
            var name: String? = null,
            val arguments: StringBuilder = StringBuilder(),
        )
        private val calls = sortedMapOf<Int, Call>()

        fun ingest(fragment: JsonObject, completeMessage: Boolean) {
            if ("content" in fragment) {
                val incoming = fragment["content"]
                if (completeMessage) {
                    if (incoming is JsonPrimitive && incoming.isString || incoming == kotlinx.serialization.json.JsonNull) {
                        content = incoming
                        contentSeen = true
                    } else invalid = true
                } else when {
                    incoming is JsonPrimitive && incoming.isString -> {
                        content = JsonPrimitive((content as? JsonPrimitive)?.contentOrNull.orEmpty() + incoming.content)
                        contentSeen = true
                    }
                    incoming != kotlinx.serialization.json.JsonNull -> invalid = true
                }
            }
            if ("reasoning_details" in fragment) {
                val incoming = fragment["reasoning_details"] as? JsonArray
                if (incoming == null || incoming.isEmpty() || !mergeDetails(incoming)) invalid = true
            }
            if ("tool_calls" in fragment) {
                val incoming = fragment["tool_calls"] as? JsonArray
                if (incoming == null || incoming.isEmpty() || !mergeCalls(incoming)) invalid = true
            }
        }

        fun stateOrNull(): JsonObject? {
            if (invalid || !contentSeen || content == null || details.isEmpty()) return null
            val message = linkedMapOf<String, JsonElement>(
                "role" to JsonPrimitive("assistant"),
                "content" to content!!,
                "reasoning_details" to JsonArray(details.values.toList()),
            )
            if (calls.isNotEmpty()) {
                message["tool_calls"] = JsonArray(calls.values.map { call ->
                    val id = call.id ?: return null
                    val type = call.type ?: return null
                    val name = call.name ?: return null
                    if (type != "function") return null
                    buildJsonObject {
                        put("id", id); put("type", type)
                        put("function", buildJsonObject {
                            put("name", name); put("arguments", call.arguments.toString())
                        })
                    }
                })
            }
            val array = JsonArray(listOf(JsonObject(message)))
            return JsonObject(mapOf("assistantMessages" to array))
                .takeIf { isValidReasoningReplay(array, "minimax_reasoning_v1") }
        }

        private fun mergeDetails(incoming: JsonArray): Boolean {
            incoming.forEachIndexed { fallbackIndex, raw ->
                val detail = raw as? JsonObject ?: return false
                if (detail.isEmpty()) return false
                val explicitIndex = detail["index"]
                val index = when {
                    explicitIndex == null -> fallbackIndex
                    explicitIndex is JsonPrimitive && !explicitIndex.isString -> explicitIndex.content.toIntOrNull()
                    else -> null
                } ?: return false
                if (index < 0) return false
                val current = details[index]?.toMutableMap() ?: linkedMapOf()
                for ((key, value) in detail) {
                    val previous = current[key]
                    if (key in setOf("text", "summary", "data") && previous is JsonPrimitive && value is JsonPrimitive && previous.isString && value.isString) {
                        current[key] = JsonPrimitive(previous.content + value.content)
                    } else if (previous == null) current[key] = value
                    else if (previous != value) return false
                }
                details[index] = JsonObject(current)
            }
            return true
        }

        private fun mergeCalls(incoming: JsonArray): Boolean {
            incoming.forEachIndexed { fallbackIndex, raw ->
                val objectCall = raw as? JsonObject ?: return false
                if (objectCall.keys.any { it !in setOf("index", "id", "type", "function") }) return false
                val explicitIndex = objectCall["index"]
                val index = when {
                    explicitIndex == null -> fallbackIndex
                    explicitIndex is JsonPrimitive && !explicitIndex.isString -> explicitIndex.content.toIntOrNull()
                    else -> null
                } ?: return false
                if (index < 0) return false
                val call = calls.getOrPut(index) { Call() }
                objectCall["id"]?.let { rawID ->
                    val id = (rawID as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
                        ?.takeIf { it.isNotBlank() } ?: return false
                    if (call.id != null && call.id != id) return false
                    call.id = id
                }
                objectCall["type"]?.let { rawType ->
                    val type = (rawType as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
                        ?: return false
                    if (type != "function" || call.type != null && call.type != type) return false
                    call.type = type
                }
                objectCall["function"]?.let { rawFunction ->
                    val function = rawFunction as? JsonObject ?: return false
                    if (function.keys.any { it !in setOf("name", "arguments") }) return false
                    function["name"]?.let { rawName ->
                        val name = (rawName as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
                            ?.takeIf { it.isNotBlank() } ?: return false
                        if (call.name != null && call.name != name) return false
                        call.name = name
                    }
                    function["arguments"]?.let { rawArguments ->
                        val arguments = (rawArguments as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
                            ?: return false
                        call.arguments.append(arguments)
                    }
                    if (function.isEmpty()) return false
                }
                if (objectCall.keys.none { it in setOf("id", "type", "function") }) return false
            }
            return true
        }
    }

    fun compileSafeCustom(raw: String, owner: String, declaredOwners: Map<String, String>, base: Map<String, List<JsonElement>> = emptyMap()): CustomResult {
        if (raw.encodeToByteArray().size > 65536) return CustomResult(false, "too_large")
        val parsed = try { LosslessJson(raw).parse() } catch (error: CustomParse) { return CustomResult(false, error.reason) }
        if (parsed.depth > 32) return CustomResult(false, "depth_exceeded")
        if (parsed.nodes > 2048) return CustomResult(false, "node_limit_exceeded")
        val root = parsed.value as? JsonObject ?: return CustomResult(false, "invalid_fragment")
        val forbiddenRoots = setOf("model", "messages", "input", "contents", "prompt", "attachments", "instructions", "system", "stream", "stream_options", "tools", "tool_choice", "plugins")
        val forbiddenChannels = setOf("auth", "headers", "query", "endpoint", "base_url", "transport_route", "model_route", "continuation_state")
        fun forbidden(value: JsonElement): String? = when (value) {
            is JsonObject -> value.entries.firstNotNullOfOrNull { (key, child) ->
                when (key) {
                    in forbiddenChannels -> "forbidden_channel"
                    in forbiddenRoots -> "forbidden_root"
                    else -> forbidden(child)
                }
            }
            is JsonArray -> value.firstNotNullOfOrNull(::forbidden)
            else -> null
        }
        forbidden(root)?.let { return CustomResult(false, it) }
        val leaves = mutableListOf<Pair<String, JsonElement>>()
        fun collect(value: JsonElement, pointer: String) {
            if (value is JsonObject && value.isNotEmpty()) value.forEach { (key, child) ->
                collect(child, "$pointer/${key.replace("~", "~0").replace("/", "~1")}")
            } else leaves += pointer to value
        }
        root.forEach { (key, value) -> collect(value, "/${key.replace("~", "~0").replace("/", "~1")}") }
        val ops = leaves.map { (pointer, value) ->
            if (pointer !in declaredOwners) return CustomResult(false, "unknown_path")
            if (declaredOwners[pointer] != owner) return CustomResult(false, "cross_owner")
            RequestPreferenceResolver.OverlayOperation(owner, "set", pointer, value)
        }
        val metrics = RequestPreferenceResolver.OverlayMetrics(raw.encodeToByteArray().size, parsed.depth, parsed.nodes)
        val compiled = RequestPreferenceResolver.compileOwnedPatches(
            RequestPreferenceResolver.OverlayIntent("body_fragment", metrics, declaredOwners, ops), emptyList(), base, emptyList(),
        )
        return if (compiled.accepted) CustomResult(true, delta = compiled.delta, preview = compiled.preview)
        else CustomResult(false, when (compiled.reason) { "unknown_pointer" -> "unknown_path"; else -> "invalid_fragment" })
    }

    private data class Parsed(val value: JsonElement, val depth: Int, val nodes: Int)
    private class CustomParse(val reason: String) : Exception()
    /** Small recursive parser: kotlinx JSON intentionally loses duplicate keys, so it cannot be used here. */
    private class LosslessJson(private val source: String) {
        private var at = 0; private var maxDepth = 0; private var nodes = 0
        fun parse(): Parsed { ws(); val value = value(0); ws(); if (at != source.length) fail("invalid_json"); return Parsed(value, maxDepth, nodes) }
        private fun value(depth: Int): JsonElement { if (depth > 32) fail("depth_exceeded"); maxDepth = maxOf(maxDepth, depth); if (++nodes > 2048) fail("node_limit_exceeded"); ws(); return when (source.getOrNull(at)) { '{' -> obj(depth + 1); '[' -> array(depth + 1); '"' -> JsonPrimitive(string()); 't' -> token("true", JsonPrimitive(true)); 'f' -> token("false", JsonPrimitive(false)); 'n' -> token("null", JsonPrimitive(null as String?)); else -> number() } }
        private fun obj(depth: Int): JsonObject { at++; ws(); val out = linkedMapOf<String, JsonElement>(); if (take('}')) return JsonObject(out); while (true) { ws(); if (source.getOrNull(at) != '"') fail("invalid_json"); val key = string(); if (key in setOf("__proto__", "prototype", "constructor")) fail("forbidden_key"); if (key in out) fail("duplicate_json_key"); ws(); if (!take(':')) fail("invalid_json"); out[key] = value(depth); ws(); if (take('}')) return JsonObject(out); if (!take(',')) fail("invalid_json") } }
        private fun array(depth: Int): JsonArray { at++; ws(); val out = mutableListOf<JsonElement>(); if (take(']')) return JsonArray(out); while (true) { out += value(depth); ws(); if (take(']')) return JsonArray(out); if (!take(',')) fail("invalid_json") } }
        private fun string(): String { val start = at++; var escape = false; while (at < source.length) { val c = source[at++]; if (escape) { escape = false; continue }; if (c == '\\') { escape = true; continue }; if (c == '"') return runCatching { kotlinx.serialization.json.Json.decodeFromString<String>(source.substring(start, at)) }.getOrElse { fail("invalid_json") }; if (c.code < 32) fail("invalid_json") }; fail("invalid_json") }
        private fun number(): JsonElement {
            val start = at
            while (source.getOrNull(at)?.let { it in "0123456789eE+-." } == true) at++
            val raw = source.substring(start, at)
            if (!Regex("-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?").matches(raw)) fail("invalid_json")
            if ('.' !in raw && 'e' !in raw && 'E' !in raw) {
                return JsonPrimitive(raw.toLongOrNull() ?: fail("invalid_json"))
            }
            val decimal = raw.toDoubleOrNull()?.takeIf { it.isFinite() } ?: fail("invalid_json")
            return JsonPrimitive(decimal)
        }
        private fun token(expected: String, value: JsonElement): JsonElement { if (!source.startsWith(expected, at)) fail("invalid_json"); at += expected.length; return value }
        private fun ws() { while (source.getOrNull(at)?.isWhitespace() == true) at++ }
        private fun take(c: Char): Boolean = (source.getOrNull(at) == c).also { if (it) at++ }
        private fun fail(reason: String): Nothing = throw CustomParse(reason)
    }
}
