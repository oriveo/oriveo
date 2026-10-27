package ai.oriveo.community.core.search

import ai.oriveo.community.core.model.RequestPreferenceResolver

/*
 * External web search: tool host table for ordinary chat (external search service).
 * Ported line by line from scripts/lib/search-tool-host.mjs (same names, same semantics); fixture shared/search-contracts/tool-host.v1.json.
 * Continuation steps are read only from this platform's continuation table RequestPreferenceResolver.CONTINUATION_KINDS, not copied again here.
 */

/** Same semantics as ToolCallLoop.Limits: effective value = min(Server-provided, 8), default 6. */
object SearchLoopLimits {
    const val HARD_CAP = 8
    const val DEFAULT_MAX_STEPS = 6
}

/** Continuation kind → maximum tool steps per send (none 0 / previous_id 1 / others 8). */
val CONTINUATION_MAX_STEPS: Map<String, Int> =
    RequestPreferenceResolver.CONTINUATION_KINDS.mapValues { it.value.maxSteps }

/**
 * Protocol rules for using tools in thinking mode.
 * thinkingWithTools: tool_loop = tools can run while thinking is on; presearch = switch to pre-search when thinking is on.
 */
data class ThinkingToolRule(val thinkingWithTools: String, val replay: String)

val THINKING_TOOL_RULES: Map<String, ThinkingToolRule> = linkedMapOf(
    "openai_chat" to ThinkingToolRule("presearch", "Since GPT-5.4, Chat does not support calling tools when reasoning_effort ≠ none"),
    "openai_responses" to ThinkingToolRule("tool_loop", "reasoning items and function_call / output are all passed back; with store=false, pass back encrypted_content"),
    "anthropic_messages" to ThinkingToolRule("tool_loop", "thinking / redacted_thinking blocks are passed back verbatim with their signature"),
    "gemini_generate_content" to ThinkingToolRule("tool_loop", "thoughtSignature goes back into the original part, needed at every step of this turn"),
    "deepseek_chat" to ThinkingToolRule("tool_loop", "with tools, reasoning_content of all historical turns must be passed back"),
    "moonshot_chat" to ThinkingToolRule("tool_loop", "reasoning_content must be passed back, across turns depending on the model"),
    "zhipu_chat" to ThinkingToolRule("tool_loop", "pass back reasoning_content within the loop, across turns see clear_thinking"),
    "qwen_chat" to ThinkingToolRule("tool_loop", "with preserve_thinking, history carries reasoning_content; tool_choice must not be required"),
)

/** Stop error codes for each host copy tier: neutral tier when only search is on; when enabled together with the library / MCP, that loop's existing copy is kept. */
val HOST_PROMPTS: Map<String, String> = linkedMapOf(
    "neutral" to "tool_loop_stopped",
    "library" to "research_stopped",
    "mcp" to "tool_loop_stopped",
)

/** Input of resolveSearchToolHost; planSearchTurn uses copy(path = …) to match `{ ...host, path }` in the reference implementation. */
data class SearchToolHostInput(
    val path: String = "",
    val library: Boolean = false,
    val mcp: Boolean = false,
    val memoryTools: Boolean = false,
    val nativeMoonshotLoop: Boolean = false,
    val serverMaxSteps: Int? = null,
    val continuationKind: String? = null,
)

/**
 * Tool host. When unchanged = true (not an external tool path) only host / tools / webSearchRegistered are meaningful, the rest are null.
 * consecutiveFailureBreaker: consecutive failure breaker threshold; null with webSearchRegistered = breaker off ('off' in the reference implementation).
 */
data class SearchToolHost(
    val host: String,
    val tools: List<String>,
    val webSearchRegistered: Boolean,
    val unchanged: Boolean = false,
    val maxSteps: Int? = null,
    val prompts: String? = null,
    val consecutiveFailureBreaker: Int? = null,
    val webSearchDisposition: String? = null,
    val writeToolConfirm: String? = null,
    val memoryTailLeg: String? = null,
)

fun resolveSearchToolHost(input: SearchToolHostInput): SearchToolHost {
    val path = input.path
    if (path != "external_tool") {
        if (input.nativeMoonshotLoop && path == "native") {
            return SearchToolHost(host = "moonshot_loop", tools = emptyList(), webSearchRegistered = false, unchanged = true)
        }
        return SearchToolHost(host = "none", tools = emptyList(), webSearchRegistered = false, unchanged = true)
    }
    val server = input.serverMaxSteps?.takeIf { it > 0 }?.let { minOf(it, SearchLoopLimits.HARD_CAP) }
        ?: SearchLoopLimits.DEFAULT_MAX_STEPS
    val continuation = CONTINUATION_MAX_STEPS[input.continuationKind]
        ?: throw IllegalArgumentException("unknown continuationKind: ${input.continuationKind}")
    val tools = buildList {
        if (input.library) add("library")
        if (input.mcp) add("mcp")
        if (input.memoryTools) add("memory")
        add("web_search")
    }
    val shared = input.library || input.mcp
    return SearchToolHost(
        host = if (shared) "shared_tool_loop" else "generic_tool_loop",
        tools = tools,
        webSearchRegistered = true,
        maxSteps = minOf(server, continuation),
        prompts = if (input.library) "library" else if (input.mcp) "mcp" else "neutral",
        // Breaker off when MCP is present; web_search failures are always fed back at the neutral tier and do not count toward consecutive failures
        consecutiveFailureBreaker = if (input.mcp) null else 3,
        webSearchDisposition = "neutral",
        // When web results enter the context this turn, MCP write tools force "this time only" confirmation
        writeToolConfirm = if (input.mcp) "once_when_web_results_present" else "n/a",
        // The memory tool joins the same loop and takes one tool step, with no separate tail leg anymore (context pipeline.1)
        memoryTailLeg = if (input.memoryTools) "in_loop" else "n/a",
    )
}
