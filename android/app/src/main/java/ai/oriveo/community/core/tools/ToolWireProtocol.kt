package ai.oriveo.community.core.tools

import ai.oriveo.community.core.model.ToolCallDelta
import ai.oriveo.community.core.model.RequestPreferenceResolver
import ai.oriveo.community.core.provider.NativeToolCallParser
import ai.oriveo.community.core.provider.NativeToolProtocol
import ai.oriveo.community.core.provider.ProviderRecipeExecution
import ai.oriveo.community.core.model.ProviderServiceError
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

internal enum class ToolWireProtocol(val wireValue: String) {
    OpenAIChat("openai_chat"),
    OpenAIResponses("openai_responses"),
    AnthropicMessages("anthropic_messages"),
    GeminiGenerate("gemini_generate"),
    ;

    companion object {
        fun fromWireValue(value: String?): ToolWireProtocol? = entries.firstOrNull {
            it.wireValue == value
        }
    }
}

/** Maps the loop's neutral messages and tool definitions onto four native provider wire protocols. */
internal object ToolWireProtocolAdapter {
    val supportedTransports: Set<String> = ToolWireProtocol.entries.mapTo(linkedSetOf()) { it.wireValue }

    fun supports(transport: String?): Boolean = transport in supportedTransports

    fun buildBody(
        protocol: ToolWireProtocol,
        modelId: String,
        request: ToolLoopLegRequest,
        original: JsonObject = JsonObject(emptyMap()),
    ): JsonObject = when (protocol) {
        ToolWireProtocol.OpenAIChat -> JsonObject(original + buildJsonObject {
            put("model", modelId)
            put("messages", openAIChatMessages(request.messages))
            put("stream", true)
            put("stream_options", buildJsonObject { put("include_usage", true) })
            put("tools", JsonArray(request.tools.map(::openAIChatTool)))
            put("tool_choice", request.toolChoice.wireValue)
        })
        ToolWireProtocol.OpenAIResponses -> {
            val mapped = responsesInput(request.messages)
            JsonObject(original + buildJsonObject {
                put("model", modelId)
                put("input", mapped.input)
                put("stream", true)
                mapped.instructions?.let { put("instructions", it) }
                mapped.previousResponseId?.let { put("previous_response_id", it) }
                put("tools", JsonArray(request.tools.map(::responsesTool)))
                put("tool_choice", request.toolChoice.wireValue)
            })
        }
        ToolWireProtocol.AnthropicMessages -> {
            val mapped = anthropicMessages(request.messages)
            JsonObject(original + buildJsonObject {
                put("model", modelId)
                put("messages", mapped.messages)
                put("stream", true)
                put("max_tokens", 8192)
                mapped.system?.let { put("system", it) }
                put("tools", JsonArray(request.tools.map(::anthropicTool)))
                put("tool_choice", buildJsonObject {
                    put("type", if (request.toolChoice == ToolLoopToolChoice.None) "none" else "auto")
                })
            })
        }
        ToolWireProtocol.GeminiGenerate -> {
            val mapped = geminiContents(request.messages)
            JsonObject(original + buildJsonObject {
                put("contents", mapped.contents)
                mapped.systemInstruction?.let { put("systemInstruction", it) }
                put("tools", buildJsonArray {
                    add(buildJsonObject {
                        put("functionDeclarations", JsonArray(request.tools.map(::geminiDeclaration)))
                    })
                })
                put("toolConfig", buildJsonObject {
                    put("functionCallingConfig", buildJsonObject {
                        put("mode", if (request.toolChoice == ToolLoopToolChoice.None) "NONE" else "AUTO")
                    })
                })
            })
        }
    }

    private fun openAIChatMessages(messages: List<ToolLoopMessage>): JsonArray = JsonArray(
        messages.map { message ->
            openAIReasoningReplay(message) ?: buildJsonObject {
                put("role", message.role)
                message.content?.let { put("content", it) }
                message.toolCalls?.let { calls ->
                    put("tool_calls", JsonArray(calls.map(::openAIChatToolCall)))
                }
                message.toolCallId?.let { put("tool_call_id", it) }
            }
        },
    )

    private fun openAIReasoningReplay(message: ToolLoopMessage): JsonObject? {
        if (message.role != "assistant" || message.toolCalls.isNullOrEmpty()) return null
        val state = continuationState(message, ToolWireProtocol.OpenAIChat.wireValue) ?: return null
        val assistantMessages = state["assistantMessages"] as? JsonArray ?: return null
        val intent = RequestPreferenceResolver.ContinuationIntent(
            kind = "replay_reasoning",
            variant = null,
            step = 1,
            state = state,
        )
        if (!RequestPreferenceResolver.validateContinuation(intent).accepted || assistantMessages.size != 1) return null
        val replay = assistantMessages.single() as? JsonObject ?: return null
        val expectedCalls = JsonArray(message.toolCalls.map(::openAIChatToolCall))
        return replay.takeIf {
            it["role"]?.jsonPrimitive?.contentOrNull == "assistant" && it["tool_calls"] == expectedCalls
        }
    }

    private fun openAIChatToolCall(call: ToolLoopToolCall) = buildJsonObject {
        put("id", call.id)
        put("type", call.type)
        put("function", buildJsonObject {
            put("name", call.function.name)
            put("arguments", call.function.arguments)
        })
    }

    private data class ResponsesInput(
        val input: JsonArray,
        val instructions: String?,
        val previousResponseId: String?,
    )

    private fun responsesInput(messages: List<ToolLoopMessage>): ResponsesInput {
        val instructions = messages.filter { it.role == "system" }.mapNotNull(::textContent)
            .takeIf { it.isNotEmpty() }?.joinToString("\n\n")
        val previousIndex = messages.indexOfLast {
            continuationState(it, "openai_responses")
                ?.get("previousResponseId")?.jsonPrimitive?.contentOrNull?.isNotBlank() == true
        }
        val previousId = messages.getOrNull(previousIndex)
            ?.let { continuationState(it, "openai_responses") }
            ?.get("previousResponseId")?.jsonPrimitive?.contentOrNull
        val source = if (previousIndex >= 0) messages.drop(previousIndex + 1) else messages
        val input = buildJsonArray {
            source.forEach { message ->
                when (message.role) {
                    "system" -> Unit
                    "tool" -> add(buildJsonObject {
                        put("type", "function_call_output")
                        put("call_id", message.toolCallId.orEmpty())
                        put("output", textContent(message).orEmpty())
                    })
                    else -> {
                        continuationBlocks(message, "openai_responses")?.forEach(::add)
                        textContent(message)?.takeIf { it.isNotEmpty() }?.let { text ->
                            add(buildJsonObject {
                                put("role", message.role)
                                put("content", buildJsonArray {
                                    add(buildJsonObject {
                                        put("type", if (message.role == "assistant") "output_text" else "input_text")
                                        put("text", text)
                                    })
                                })
                            })
                        }
                        message.toolCalls.orEmpty().forEach { call ->
                            add(buildJsonObject {
                                put("type", "function_call")
                                put("call_id", call.id)
                                put("name", call.function.name)
                                put("arguments", call.function.arguments)
                            })
                        }
                    }
                }
            }
        }
        return ResponsesInput(input, instructions, previousId)
    }

    private data class AnthropicInput(val messages: JsonArray, val system: String?)

    private fun anthropicMessages(messages: List<ToolLoopMessage>): AnthropicInput {
        val system = messages.filter { it.role == "system" }.mapNotNull(::textContent)
            .takeIf { it.isNotEmpty() }?.joinToString("\n\n")
        val output = mutableListOf<JsonElement>()
        messages.filterNot { it.role == "system" }.forEach { message ->
            if (message.role == "tool") {
                val block = buildJsonObject {
                    put("type", "tool_result")
                    put("tool_use_id", message.toolCallId.orEmpty())
                    put("content", textContent(message).orEmpty())
                }
                val previous = output.lastOrNull() as? JsonObject
                if (previous?.get("role")?.jsonPrimitive?.contentOrNull == "user" &&
                    (previous["content"] as? JsonArray)?.all {
                        (it as? JsonObject)?.get("type")?.jsonPrimitive?.contentOrNull == "tool_result"
                    } == true
                ) {
                    output[output.lastIndex] = JsonObject(previous + (
                        "content" to JsonArray((previous["content"] as JsonArray) + block)
                    ))
                } else {
                    output += buildJsonObject { put("role", "user"); put("content", JsonArray(listOf(block))) }
                }
            } else {
                val replay = continuationBlocks(message, "anthropic_messages")
                val content = replay ?: buildJsonArray {
                    textContent(message)?.takeIf { it.isNotEmpty() }?.let { text ->
                        add(buildJsonObject { put("type", "text"); put("text", text) })
                    }
                    message.toolCalls.orEmpty().forEach { call ->
                        add(buildJsonObject {
                            put("type", "tool_use")
                            put("id", call.id)
                            put("name", call.function.name)
                            put("input", jsonObject(call.function.arguments))
                        })
                    }
                }
                output += buildJsonObject { put("role", message.role); put("content", content) }
            }
        }
        return AnthropicInput(JsonArray(output), system)
    }

    private data class GeminiInput(val contents: JsonArray, val systemInstruction: JsonObject?)

    private fun geminiContents(messages: List<ToolLoopMessage>): GeminiInput {
        val system = messages.filter { it.role == "system" }.mapNotNull(::textContent)
            .takeIf { it.isNotEmpty() }?.joinToString("\n\n")
        val callNames = buildMap {
            messages.forEach { message -> message.toolCalls.orEmpty().forEach { put(it.id, it.function.name) } }
        }
        val contents = buildJsonArray {
            messages.filterNot { it.role == "system" }.forEach { message ->
                if (message.role == "tool") {
                    add(buildJsonObject {
                        put("role", "user")
                        put("parts", buildJsonArray {
                            add(buildJsonObject {
                                put("functionResponse", buildJsonObject {
                                    put("name", callNames[message.toolCallId] ?: "unknown_tool")
                                    put("response", jsonObject(textContent(message).orEmpty()))
                                })
                            })
                        })
                    })
                } else {
                    val replay = continuationBlocks(message, "gemini_generate")
                    if (replay != null) {
                        replay.forEach(::add)
                    } else {
                        add(buildJsonObject {
                            put("role", if (message.role == "assistant") "model" else "user")
                            put("parts", buildJsonArray {
                                textContent(message)?.takeIf { it.isNotEmpty() }?.let { add(buildJsonObject { put("text", it) }) }
                                message.toolCalls.orEmpty().forEach { call ->
                                    add(buildJsonObject {
                                        put("functionCall", buildJsonObject {
                                            put("name", call.function.name)
                                            put("args", jsonObject(call.function.arguments))
                                        })
                                    })
                                }
                            })
                        })
                    }
                }
            }
        }
        val systemInstruction = system?.let {
            buildJsonObject { put("parts", buildJsonArray { add(buildJsonObject { put("text", it) }) }) }
        }
        return GeminiInput(contents, systemInstruction)
    }

    private fun openAIChatTool(tool: ToolLoopToolDefinition) = buildJsonObject {
        put("type", "function")
        put("function", buildJsonObject {
            put("name", tool.function.name)
            put("description", tool.function.description)
            put("parameters", tool.function.parameters)
        })
    }

    private fun responsesTool(tool: ToolLoopToolDefinition) = buildJsonObject {
        put("type", "function")
        put("name", tool.function.name)
        put("description", tool.function.description)
        put("parameters", tool.function.parameters)
    }

    private fun anthropicTool(tool: ToolLoopToolDefinition) = buildJsonObject {
        put("name", tool.function.name)
        put("description", tool.function.description)
        put("input_schema", tool.function.parameters)
    }

    private fun geminiDeclaration(tool: ToolLoopToolDefinition) = buildJsonObject {
        put("name", tool.function.name)
        put("description", tool.function.description)
        put("parameters", normalizeGeminiSchema(tool.function.parameters))
    }

    private fun textContent(message: ToolLoopMessage): String? = when (val content = message.content) {
        is JsonPrimitive -> content.contentOrNull
        is JsonArray -> content.mapNotNull { (it as? JsonObject)?.get("text")?.jsonPrimitive?.contentOrNull }
            .joinToString("\n")
        else -> null
    }

    private fun continuationState(message: ToolLoopMessage, protocol: String): JsonObject? {
        val continuation = message.providerContinuation ?: return null
        if (continuation["protocol"]?.jsonPrimitive?.contentOrNull != protocol) return null
        return continuation["state"] as? JsonObject
    }

    private fun continuationBlocks(message: ToolLoopMessage, protocol: String): JsonArray? =
        continuationState(message, protocol)?.get("blocks") as? JsonArray

    private fun jsonObject(raw: String): JsonObject = runCatching {
        Json.parseToJsonElement(raw).jsonObject
    }.getOrElse { buildJsonObject { put("output", raw) } }

    private fun normalizeGeminiSchema(value: JsonElement): JsonElement = when (value) {
        is JsonArray -> JsonArray(value.map(::normalizeGeminiSchema))
        is JsonObject -> buildJsonObject {
            value.forEach { (key, item) ->
                when {
                    key == "additionalProperties" -> Unit
                    key == "type" && item is JsonArray && item.any { it.jsonPrimitive.contentOrNull == "null" } -> {
                        put("type", item.firstOrNull { it.jsonPrimitive.contentOrNull != "null" } ?: JsonPrimitive("string"))
                        put("nullable", true)
                    }
                    else -> put(key, normalizeGeminiSchema(item))
                }
            }
        }
        else -> value
    }
}

/** Stateful decoder for a single model leg. */
internal class ToolWireStreamDecoder(
    private val protocol: ToolWireProtocol,
    private val json: Json,
    openAIReasoningParserKind: String? = null,
) {
    private val native = NativeToolCallParser(
        when (protocol) {
            ToolWireProtocol.OpenAIChat -> NativeToolProtocol.OpenAIChat
            ToolWireProtocol.OpenAIResponses -> NativeToolProtocol.OpenAIResponses
            ToolWireProtocol.AnthropicMessages -> NativeToolProtocol.AnthropicMessages
            ToolWireProtocol.GeminiGenerate -> NativeToolProtocol.GeminiGenerate
        },
    )
    private val anthropicBlocks = mutableMapOf<Int, JsonObject>()
    private val anthropicInputs = mutableMapOf<Int, StringBuilder>()
    private val responsesReasoning = mutableMapOf<Int, JsonObject>()
    private var responsesPreviousId: String? = null
    private val openAIReasoning = openAIReasoningParserKind?.let {
        ProviderRecipeExecution.ReasoningAssistantAccumulator(it)
    }

    fun parse(eventType: String?, payload: String): List<ToolLoopLegEvent> {
        val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull() ?: return emptyList()
        val error = root["error"] as? JsonObject
        if (error != null || root["type"]?.jsonPrimitive?.contentOrNull == "error") {
            throw ProviderServiceError.Upstream(
                statusCode = 200,
                detail = error?.get("message")?.jsonPrimitive?.contentOrNull
                    ?: "The provider reported a streaming error.",
            )
        }
        val events = mutableListOf<ToolLoopLegEvent>()
        native.parse(eventType, root).takeIf { it.isNotEmpty() }?.let { deltas ->
            events += ToolLoopLegEvent.ToolCallDeltas(deltas.map(::toLoopDelta))
        }
        when (protocol) {
            ToolWireProtocol.OpenAIChat -> parseOpenAIChat(root, events)
            ToolWireProtocol.OpenAIResponses -> parseResponses(eventType, root, events)
            ToolWireProtocol.AnthropicMessages -> parseAnthropic(eventType, root, events)
            ToolWireProtocol.GeminiGenerate -> parseGemini(root, events)
        }
        return events
    }

    private fun parseOpenAIChat(root: JsonObject, events: MutableList<ToolLoopLegEvent>) {
        val choice = (root["choices"] as? JsonArray)?.firstOrNull() as? JsonObject
        val message = choice?.get("message") as? JsonObject
        val delta = choice?.get("delta") as? JsonObject
        (delta ?: message)?.let { openAIReasoning?.ingest(it, completeMessage = message != null) }
        when (val content = delta?.get("content")) {
            is JsonPrimitive -> content.contentOrNull?.takeIf { it.isNotEmpty() }
                ?.let { events += ToolLoopLegEvent.TextDelta(it) }
            is JsonArray -> content.mapNotNull { block ->
                val value = block as? JsonObject ?: return@mapNotNull null
                value["text"]?.jsonPrimitive?.contentOrNull
            }.joinToString("").takeIf { it.isNotEmpty() }
                ?.let { events += ToolLoopLegEvent.TextDelta(it) }
            else -> Unit
        }
        val finishReason = choice?.get("finish_reason")
        if ((finishReason != null && finishReason !is JsonNull) || message != null) {
            openAIReasoning?.stateOrNull()?.let { state ->
                events += ToolLoopLegEvent.ProviderContinuation(protocol.wireValue, state)
            }
        }
        (root["usage"] as? JsonObject)?.let { usage ->
            events += ToolLoopLegEvent.Usage(ToolLoopUsage(
                promptTokens = usage["prompt_tokens"]?.jsonPrimitive?.intOrNull,
                completionTokens = usage["completion_tokens"]?.jsonPrimitive?.intOrNull,
                totalTokens = usage["total_tokens"]?.jsonPrimitive?.intOrNull,
            ))
        }
    }

    private fun parseResponses(eventType: String?, root: JsonObject, events: MutableList<ToolLoopLegEvent>) {
        val type = eventType ?: root["type"]?.jsonPrimitive?.contentOrNull
        val response = root["response"] as? JsonObject
        val responseId = response?.get("id")?.jsonPrimitive?.contentOrNull
            ?: if (type == "response.created") root["id"]?.jsonPrimitive?.contentOrNull else null
        if (!responseId.isNullOrBlank()) responsesPreviousId = responseId
        if (type == "response.output_text.delta") {
            root["delta"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() }
                ?.let { events += ToolLoopLegEvent.TextDelta(it) }
        }
        if (type == "response.output_item.done") {
            val item = root["item"] as? JsonObject
            if (item?.get("type")?.jsonPrimitive?.contentOrNull == "reasoning") {
                val index = root["output_index"]?.jsonPrimitive?.intOrNull ?: responsesReasoning.size
                responsesReasoning[index] = buildJsonObject {
                    put("type", "reasoning")
                    item["id"]?.let { put("id", it) }
                    item["summary"]?.let { put("summary", it) }
                    item["encrypted_content"]?.let { put("encrypted_content", it) }
                }
            }
        }
        if (responsesPreviousId != null || responsesReasoning.isNotEmpty()) {
            events += ToolLoopLegEvent.ProviderContinuation(
                protocol.wireValue,
                buildJsonObject {
                    responsesPreviousId?.let { put("previousResponseId", it) }
                    if (responsesReasoning.isNotEmpty()) {
                        put("blocks", JsonArray(responsesReasoning.toSortedMap().values.toList()))
                    }
                },
            )
        }
        (response?.get("usage") as? JsonObject)?.let { usage ->
            events += ToolLoopLegEvent.Usage(ToolLoopUsage(
                promptTokens = usage["input_tokens"]?.jsonPrimitive?.intOrNull,
                completionTokens = usage["output_tokens"]?.jsonPrimitive?.intOrNull,
                totalTokens = usage["total_tokens"]?.jsonPrimitive?.intOrNull,
            ))
        }
    }

    private fun parseAnthropic(eventType: String?, root: JsonObject, events: MutableList<ToolLoopLegEvent>) {
        val type = eventType ?: root["type"]?.jsonPrimitive?.contentOrNull
        val index = root["index"]?.jsonPrimitive?.intOrNull ?: 0
        when (type) {
            "content_block_start" -> (root["content_block"] as? JsonObject)?.let { block ->
                anthropicBlocks[index] = block
                if (block["type"]?.jsonPrimitive?.contentOrNull == "tool_use") {
                    anthropicInputs[index] = StringBuilder(
                        (block["input"] as? JsonObject)?.takeIf { it.isNotEmpty() }?.toString().orEmpty(),
                    )
                }
            }
            "content_block_delta" -> (root["delta"] as? JsonObject)?.let { delta ->
                when (delta["type"]?.jsonPrimitive?.contentOrNull) {
                    "text_delta" -> delta["text"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() }
                        ?.let { events += ToolLoopLegEvent.TextDelta(it) }
                    "thinking_delta" -> appendAnthropicBlock(index, "thinking", delta["thinking"]?.jsonPrimitive?.contentOrNull)
                    "signature_delta" -> appendAnthropicBlock(index, "signature", delta["signature"]?.jsonPrimitive?.contentOrNull)
                    "input_json_delta" -> {
                        val partial = delta["partial_json"]?.jsonPrimitive?.contentOrNull.orEmpty()
                        anthropicInputs.getOrPut(index, ::StringBuilder).append(partial)
                        val parsed = runCatching { json.parseToJsonElement(anthropicInputs[index].toString()) }
                            .getOrNull() as? JsonObject
                        if (parsed != null) anthropicBlocks[index] = JsonObject(anthropicBlocks[index].orEmpty() + ("input" to parsed))
                    }
                }
            }
            "message_start" -> ((root["message"] as? JsonObject)?.get("usage") as? JsonObject)?.let { usage ->
                events += ToolLoopLegEvent.Usage(ToolLoopUsage(promptTokens = usage["input_tokens"]?.jsonPrimitive?.intOrNull))
            }
            "message_delta" -> (root["usage"] as? JsonObject)?.let { usage ->
                events += ToolLoopLegEvent.Usage(ToolLoopUsage(completionTokens = usage["output_tokens"]?.jsonPrimitive?.intOrNull))
            }
        }
        if (type == "content_block_start" || type == "content_block_delta" || type == "content_block_stop") {
            events += ToolLoopLegEvent.ProviderContinuation(
                protocol.wireValue,
                buildJsonObject { put("blocks", JsonArray(anthropicBlocks.toSortedMap().values.toList())) },
            )
        }
    }

    private fun appendAnthropicBlock(index: Int, key: String, fragment: String?) {
        if (fragment.isNullOrEmpty()) return
        val block = anthropicBlocks[index] ?: JsonObject(emptyMap())
        val previous = block[key]?.jsonPrimitive?.contentOrNull.orEmpty()
        anthropicBlocks[index] = JsonObject(block + (key to JsonPrimitive(previous + fragment)))
    }

    private fun parseGemini(root: JsonObject, events: MutableList<ToolLoopLegEvent>) {
        val candidate = (root["candidates"] as? JsonArray)?.firstOrNull() as? JsonObject
        val content = candidate?.get("content") as? JsonObject
        val parts = content?.get("parts") as? JsonArray
        parts.orEmpty().forEach { raw ->
            val part = raw as? JsonObject ?: return@forEach
            part["text"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() }
                ?.let { events += ToolLoopLegEvent.TextDelta(it) }
        }
        if (content != null) {
            events += ToolLoopLegEvent.ProviderContinuation(
                protocol.wireValue,
                buildJsonObject { put("blocks", JsonArray(listOf(content))) },
            )
        }
        (root["usageMetadata"] as? JsonObject)?.let { usage ->
            val prompt = usage["promptTokenCount"]?.jsonPrimitive?.intOrNull
            val completion = usage["candidatesTokenCount"]?.jsonPrimitive?.intOrNull
            events += ToolLoopLegEvent.Usage(ToolLoopUsage(
                promptTokens = prompt,
                completionTokens = completion,
                totalTokens = usage["totalTokenCount"]?.jsonPrimitive?.intOrNull,
            ))
        }
    }

    private fun toLoopDelta(delta: ToolCallDelta) = ToolLoopToolCallDelta(
        index = delta.index,
        id = delta.id,
        type = delta.type,
        name = delta.name,
        arguments = delta.arguments,
    )
}
