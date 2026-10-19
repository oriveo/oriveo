package ai.oriveo.community.core.context

import ai.oriveo.community.core.model.ChatRole
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Request-body families of wire-system.v1; `wire` is the fixture key. */
enum class ContextWireFamily(val wire: String) {
    OPENAI_CHAT("openai_chat"),
    OPENAI_CHAT_STRING_ONLY("openai_chat_string_only"),
    FREE("free"),
    LLAMACPP("llamacpp"),
    MANAGED("managed"),
    OPENAI_RESPONSES("openai_responses"),
    ANTHROPIC("anthropic"),
    GEMINI("gemini"),
    ;

    companion object {
        fun fromWire(wire: String): ContextWireFamily =
            entries.firstOrNull { it.wire == wire } ?: throw IllegalArgumentException("unknown wire family: $wire")
    }
}

/** One tool call of a host-loop leg; `arguments` is the raw JSON string the model produced. */
data class ContextToolCall(val id: String, val name: String, val arguments: String)

data class ContextToolResult(val callId: String, val name: String, val output: String)

/** Tool round appended after the last user message: assistant calls, their results, then the optional host notice. */
data class ContextToolLeg(
    val calls: List<ContextToolCall>,
    val results: List<ContextToolResult>,
    val notice: String? = null,
)

/**
 * WireAdapter: projects a plan into each family's request-body subset (system carrier + messages).
 * Pure function; attachments keep each provider's own part builders and are not handled here.
 */
object ContextWireAdapter {

    private const val BLOCK_SEPARATOR = "\n\n"

    /** Throws for plans without messages (rejected / image generation). */
    fun project(plan: ContextPlan, family: ContextWireFamily, toolLeg: ContextToolLeg? = null): JsonObject {
        val messages = plan.messages ?: throw IllegalArgumentException("plan has no messages to send")
        return project(plan.system, messages, family, toolLeg)
    }

    fun project(
        system: String?,
        messages: List<ContextPlanMessage>,
        family: ContextWireFamily,
        toolLeg: ContextToolLeg? = null,
    ): JsonObject {
        require(messages.isNotEmpty()) { "plan has no messages to send" }
        return when (family) {
            ContextWireFamily.OPENAI_CHAT, ContextWireFamily.MANAGED -> chat(system, messages, toolLeg, stringOnly = false)
            ContextWireFamily.OPENAI_CHAT_STRING_ONLY, ContextWireFamily.LLAMACPP ->
                chat(system, messages, toolLeg, stringOnly = true)
            ContextWireFamily.FREE -> {
                require(toolLeg == null) { "Free sends no tools" }
                chat(system, messages, null, stringOnly = true)
            }
            ContextWireFamily.OPENAI_RESPONSES -> responses(system, messages, toolLeg)
            ContextWireFamily.ANTHROPIC -> anthropic(system, messages, toolLeg)
            ContextWireFamily.GEMINI -> gemini(system, messages, toolLeg)
        }
    }

    // ---- chat-shaped: OpenAI Chat, string-only, Free, llama.cpp, managed ----

    private fun chat(system: String?, messages: List<ContextPlanMessage>, toolLeg: ContextToolLeg?, stringOnly: Boolean) =
        buildJsonObject {
            put("messages", buildJsonArray {
                system?.let { add(roleContent("system", JsonPrimitive(it))) }
                messages.forEach { m ->
                    val content = if (stringOnly) JsonPrimitive(joined(m)) else textContent(m, "text")
                    add(roleContent(m.role.rawValue, content))
                }
                toolLeg?.let { leg ->
                    add(buildJsonObject {
                        put("role", "assistant")
                        put("content", JsonNull)
                        put("tool_calls", JsonArray(leg.calls.map { call ->
                            buildJsonObject {
                                put("id", call.id)
                                put("type", "function")
                                put("function", buildJsonObject {
                                    put("name", call.name)
                                    put("arguments", call.arguments)
                                })
                            }
                        }))
                    })
                    leg.results.forEach { r ->
                        add(buildJsonObject {
                            put("role", "tool")
                            put("tool_call_id", r.callId)
                            put("content", r.output)
                        })
                    }
                    leg.notice?.let { add(roleContent("user", JsonPrimitive(it))) }
                }
            })
        }

    // ---- OpenAI Responses ----

    private fun responses(system: String?, messages: List<ContextPlanMessage>, toolLeg: ContextToolLeg?) =
        buildJsonObject {
            system?.let { put("instructions", it) }
            put("input", buildJsonArray {
                messages.forEach { m ->
                    val partType = if (m.role == ChatRole.Assistant) "output_text" else "input_text"
                    add(roleContent(m.role.rawValue, textContent(m, partType)))
                }
                toolLeg?.let { leg ->
                    leg.calls.forEach { call ->
                        add(buildJsonObject {
                            put("type", "function_call")
                            put("call_id", call.id)
                            put("name", call.name)
                            put("arguments", call.arguments)
                        })
                    }
                    leg.results.forEach { r ->
                        add(buildJsonObject {
                            put("type", "function_call_output")
                            put("call_id", r.callId)
                            put("output", r.output)
                        })
                    }
                    leg.notice?.let { add(roleContent("user", JsonPrimitive(it))) }
                }
            })
        }

    // ---- Anthropic Messages: single block-level breakpoint ----

    /** One content block plus whether it may carry the breakpoint ([D] blocks may not). */
    private class AnthropicBlock(val body: JsonObject, val cacheable: Boolean)

    private class AnthropicMessage(val role: String, val blocks: List<AnthropicBlock>)

    private fun anthropic(system: String?, messages: List<ContextPlanMessage>, toolLeg: ContextToolLeg?): JsonObject {
        val all = messages.map { m ->
            AnthropicMessage(m.role.rawValue, m.blocks.map { b ->
                AnthropicBlock(textBlock(b.text), cacheable = b.kind != ContextBlockKind.DYNAMIC)
            })
        }.toMutableList()
        toolLeg?.let { leg ->
            all += AnthropicMessage("assistant", leg.calls.map { call ->
                AnthropicBlock(buildJsonObject {
                    put("type", "tool_use")
                    put("id", call.id)
                    put("name", call.name)
                    put("input", decodeArguments(call.arguments))
                }, cacheable = true)
            })
            val turn = leg.results.map { r ->
                AnthropicBlock(buildJsonObject {
                    put("type", "tool_result")
                    put("tool_use_id", r.callId)
                    put("content", r.output)
                }, cacheable = true)
            } + listOfNotNull(leg.notice?.let { AnthropicBlock(textBlock(it), cacheable = true) })
            all += AnthropicMessage("user", turn)
        }
        val lastUser = all.indexOfLast { it.role == ChatRole.User.rawValue }
        val breakpoint = if (lastUser >= 0) all[lastUser].blocks.indexOfLast { it.cacheable } else -1
        return buildJsonObject {
            system?.let { put("system", it) }
            put("messages", JsonArray(all.mapIndexed { mi, m ->
                roleContent(m.role, JsonArray(m.blocks.mapIndexed { bi, b ->
                    if (mi == lastUser && bi == breakpoint) withCacheControl(b.body) else b.body
                }))
            }))
        }
    }

    private fun textBlock(text: String): JsonObject = buildJsonObject {
        put("type", "text")
        put("text", text)
    }

    private fun withCacheControl(block: JsonObject): JsonObject =
        JsonObject(block + ("cache_control" to buildJsonObject { put("type", "ephemeral") }))

    // ---- Gemini ----

    private fun gemini(system: String?, messages: List<ContextPlanMessage>, toolLeg: ContextToolLeg?) = buildJsonObject {
        system?.let { s -> put("systemInstruction", buildJsonObject { put("parts", JsonArray(listOf(textPart(s)))) }) }
        put("contents", buildJsonArray {
            messages.forEach { m -> add(geminiContent(m.role, m.blocks.map { textPart(it.text) })) }
            toolLeg?.let { leg ->
                add(geminiContent(ChatRole.Assistant, leg.calls.map { call ->
                    buildJsonObject {
                        put("functionCall", buildJsonObject {
                            put("name", call.name)
                            put("args", decodeArguments(call.arguments))
                        })
                    }
                }))
                val parts = leg.results.map { r ->
                    buildJsonObject {
                        put("functionResponse", buildJsonObject {
                            put("name", r.name)
                            put("response", buildJsonObject { put("content", r.output) })
                        })
                    }
                } + listOfNotNull(leg.notice?.let(::textPart))
                add(geminiContent(ChatRole.User, parts))
            }
        })
    }

    private fun geminiContent(role: ChatRole, parts: List<JsonObject>): JsonObject = buildJsonObject {
        put("role", if (role == ChatRole.Assistant) "model" else role.rawValue)
        put("parts", JsonArray(parts))
    }

    private fun textPart(text: String): JsonObject = buildJsonObject { put("text", text) }

    // ---- shared ----

    private fun roleContent(role: String, content: JsonElement): JsonObject = buildJsonObject {
        put("role", role)
        put("content", content)
    }

    /** One block → string; more blocks → typed text parts. */
    private fun textContent(m: ContextPlanMessage, partType: String): JsonElement =
        if (m.blocks.size == 1) {
            JsonPrimitive(m.blocks[0].text)
        } else {
            JsonArray(m.blocks.map { b ->
                buildJsonObject {
                    put("type", partType)
                    put("text", b.text)
                }
            })
        }

    private fun joined(m: ContextPlanMessage): String = m.blocks.joinToString(BLOCK_SEPARATOR) { it.text }

    /** Empty / all-white-space → {}; invalid JSON or a non-object value is an error. */
    private fun decodeArguments(arguments: String): JsonObject {
        if (arguments.trimWhiteSpace().isEmpty()) return JsonObject(emptyMap())
        val parsed = try {
            Json.parseToJsonElement(arguments)
        } catch (e: IllegalArgumentException) {
            throw IllegalArgumentException("tool arguments are not valid JSON", e)
        }
        return parsed as? JsonObject ?: throw IllegalArgumentException("tool arguments are not a JSON object")
    }
}
