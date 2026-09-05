package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ToolCallDelta
import ai.oriveo.community.core.model.UnhandledToolCall
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

internal enum class NativeToolProtocol {
    OpenAIChat,
    OpenAIResponses,
    AnthropicMessages,
    GeminiGenerate,
}

/** Stateful structured-wire parser. Prose, code fences and pseudo-tags are never inspected. */
internal class NativeToolCallParser(private val protocol: NativeToolProtocol) {
    private var lastOpenAIChatIndex: Int? = null

    fun parse(eventType: String?, root: JsonObject): List<ToolCallDelta> = when (protocol) {
        NativeToolProtocol.OpenAIChat -> parseOpenAIChat(root)
        NativeToolProtocol.OpenAIResponses -> parseResponses(eventType, root)
        NativeToolProtocol.AnthropicMessages -> parseAnthropic(eventType, root)
        NativeToolProtocol.GeminiGenerate -> parseGemini(root)
    }

    private fun parseOpenAIChat(root: JsonObject): List<ToolCallDelta> {
        val choice = (root["choices"] as? JsonArray)?.firstOrNull() as? JsonObject ?: return emptyList()
        val message = (choice["delta"] ?: choice["message"]) as? JsonObject ?: return emptyList()
        val calls = message["tool_calls"] as? JsonArray ?: return emptyList()
        return calls.mapIndexedNotNull { fallbackIndex, raw ->
            val call = raw as? JsonObject ?: return@mapIndexedNotNull null
            val function = call["function"] as? JsonObject
            val explicit = primitive(call, "index")?.toIntOrNull()
            val index = explicit ?: if (calls.size == 1) lastOpenAIChatIndex ?: fallbackIndex else fallbackIndex
            lastOpenAIChatIndex = index
            val id = primitive(call, "id")
            val type = primitive(call, "type")
            val name = primitive(call, "name") ?: primitive(function, "name")
            val arguments = primitive(call, "arguments") ?: primitive(function, "arguments")
            if (id == null && type == null && name == null && arguments == null) null
            else ToolCallDelta(index, id, type, name, arguments)
        }
    }

    private fun parseResponses(eventType: String?, root: JsonObject): List<ToolCallDelta> {
        val type = eventType ?: primitive(root, "type")
        val index = primitive(root, "output_index")?.toIntOrNull()
            ?: primitive(root, "index")?.toIntOrNull() ?: 0
        return when (type) {
            "response.output_item.added" -> {
                val item = root["item"] as? JsonObject ?: return emptyList()
                if (primitive(item, "type") != "function_call") return emptyList()
                listOf(ToolCallDelta(
                    index = index,
                    id = primitive(item, "call_id") ?: primitive(item, "id"),
                    type = "function",
                    name = primitive(item, "name"),
                    arguments = primitive(item, "arguments"),
                ))
            }
            "response.function_call_arguments.delta" -> primitive(root, "delta")
                ?.let { listOf(ToolCallDelta(index = index, arguments = it)) }
                .orEmpty()
            else -> emptyList()
        }
    }

    private fun parseAnthropic(eventType: String?, root: JsonObject): List<ToolCallDelta> {
        val type = eventType ?: primitive(root, "type")
        val index = primitive(root, "index")?.toIntOrNull() ?: 0
        return when (type) {
            "content_block_start" -> {
                val block = root["content_block"] as? JsonObject ?: return emptyList()
                if (primitive(block, "type") != "tool_use") return emptyList()
                val input = block["input"] as? JsonObject
                listOf(ToolCallDelta(
                    index = index,
                    id = primitive(block, "id"),
                    type = "function",
                    name = primitive(block, "name"),
                    arguments = input?.takeIf { it.isNotEmpty() }?.toString(),
                ))
            }
            "content_block_delta" -> {
                val delta = root["delta"] as? JsonObject ?: return emptyList()
                if (primitive(delta, "type") != "input_json_delta") return emptyList()
                primitive(delta, "partial_json")?.let {
                    listOf(ToolCallDelta(index = index, arguments = it))
                }.orEmpty()
            }
            else -> emptyList()
        }
    }

    private fun parseGemini(root: JsonObject): List<ToolCallDelta> {
        val candidate = (root["candidates"] as? JsonArray)?.firstOrNull() as? JsonObject ?: return emptyList()
        val content = candidate["content"] as? JsonObject ?: return emptyList()
        val parts = content["parts"] as? JsonArray ?: return emptyList()
        return parts.mapIndexedNotNull { index, raw ->
            val part = raw as? JsonObject ?: return@mapIndexedNotNull null
            val call = part["functionCall"] as? JsonObject ?: return@mapIndexedNotNull null
            val name = primitive(call, "name")?.takeIf { it.isNotBlank() } ?: return@mapIndexedNotNull null
            ToolCallDelta(
                index = index,
                id = primitive(call, "id"),
                type = "function",
                name = name,
                arguments = (call["args"] as? JsonObject)?.toString() ?: "{}",
            )
        }
    }

    private fun primitive(objectValue: JsonObject?, key: String): String? =
        (objectValue?.get(key) as? JsonPrimitive)?.contentOrNull
}

internal object NativeToolCallAccumulator {
    fun merge(target: MutableMap<Int, ToolCallDelta>, deltas: List<ToolCallDelta>) {
        deltas.forEach { delta ->
            val previous = target[delta.index] ?: ToolCallDelta(delta.index)
            target[delta.index] = ToolCallDelta(
                index = delta.index,
                id = delta.id?.takeIf { it.isNotBlank() } ?: previous.id,
                type = delta.type?.takeIf { it.isNotBlank() } ?: previous.type,
                name = previous.name?.takeIf { it.isNotBlank() } ?: delta.name?.takeIf { it.isNotBlank() },
                arguments = previous.arguments.orEmpty() + delta.arguments.orEmpty(),
            )
        }
    }

    fun finalize(target: Map<Int, ToolCallDelta>, namespace: String): List<UnhandledToolCall> =
        target.toSortedMap().values.mapIndexed { offset, call ->
            UnhandledToolCall(
                id = call.id?.takeIf { it.isNotBlank() } ?: "${namespace}_${offset + 1}",
                name = call.name?.takeIf { it.isNotBlank() } ?: "?",
                arguments = call.arguments.orEmpty(),
            )
        }
}
