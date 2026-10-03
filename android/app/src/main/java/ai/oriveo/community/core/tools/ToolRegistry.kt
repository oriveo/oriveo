package ai.oriveo.community.core.tools

// Execution-side contract of the generic tool loop: registry entries and the registry.
// Neutral messages / tool definitions / leg events are in `ToolLoopContracts.kt`; the loop itself is in `ToolCallLoop.kt`.

/** Tool scope. */
enum class ToolScope { Web, Mcp }

/** A registry entry refusing a call (argument validation failed, i.e. the model got it wrong). The loop encodes it as `ok:false`, feeds it back and counts it toward self-correction. */
class ToolCallRejection(val code: String, override val message: String) : Exception(message)

/** What the loop does after a tool fails. Decided by the entry per error type (an account-level failure fails the whole run, a failure tied to one argument only loses that call). */
sealed interface ToolFailureDisposition {
    /** A failure that would hold for every later call: the whole run throws. */
    data object Fatal : ToolFailureDisposition

    /** A one-off failure: fed back as structured `ok:false` and the run continues; counts toward consecutive failures, and the run throws at the threshold. */
    data class Degrade(val code: String, val message: String) : ToolFailureDisposition

    /**
     * Neutral result: also fed back as structured `ok:false` and also uses a step, but **neither counts toward consecutive failures nor resets them**.
     *
     * For "nothing came back this time, but that says nothing about the health of the pipeline" (a lookup for an item that
     * does not exist): counted as a failure, three stale references would be mistaken for the source being down; counted as a
     * success, a real run of failures (fail, fail, missing, fail) would restart its count and the circuit breaker would never trip.
     */
    data class Neutral(val code: String, val message: String) : ToolFailureDisposition
}

/**
 * Tool execution timed out. The loop swaps the `TimeoutCancellationException` thrown by a tool's internal `withTimeout` for this
 * before deciding: the original is a `CancellationException` subclass and, rethrown as is, would be swallowed above as "user cancelled".
 */
class ToolExecutionTimeout(val toolName: String, cause: Throwable) :
    Exception("Tool call timed out: $toolName", cause)

/**
 * The result of one successful execution.
 *
 * When [stopReason] is non-null the loop appends it as a system message, feeds "stopped" back to the remaining tool_calls of the leg
 * (error code from `ToolCallLoop.Prompts.stoppedCode`) and then runs the tool-free synthesis leg (e.g. a cap on consecutive empty results).
 * [stoppedMessage] is the explanation fed back to those skipped calls; it defaults to [stopReason]. They are separate because the
 * system prompt instructs the model, while a skipped call's tool result only needs to state the reason.
 */
data class ToolExecutionOutcome(
    val content: String,
    val stopReason: String? = null,
    val stoppedMessage: String? = null,
)

/** Execution context the loop hands to an entry. */
data class ToolExecutionContext(
    /** Call id used for the echo (a cross-leg unique fallback made up by the loop when upstream gave none). */
    val callId: String,
    /** Which tool step of this run this is, counting only calls that **actually entered execution** (from 1). */
    val stepNumber: Int,
    /** Current leg index (from 0). */
    val legIndex: Int,
)

/** Registry entry = one tool the generic loop can run. `name` is the only allowlist key. */
interface ToolRegistryEntry {
    val name: String
    val scope: ToolScope

    /** Definition sent to the model; null for server-side builtin tools (Moonshot `$web_search`), whose definition the recipe injects into the request body. */
    val definition: ToolLoopToolDefinition?

    /** Wire type used when echoing assistant `tool_calls[].type`. */
    val wireType: String get() = "function"

    /**
     * Execute. Throwing [ToolCallRejection] means the model got the arguments wrong; other errors go to [failureDisposition]
     * (a tool's internal timeout is first swapped for [ToolExecutionTimeout] by the loop). Real cancellation skips the decision and propagates as is.
     */
    suspend fun execute(call: ToolLoopToolCall, context: ToolExecutionContext): ToolExecutionOutcome

    fun failureDisposition(error: Throwable): ToolFailureDisposition = ToolFailureDisposition.Fatal
}

/**
 * Tool registry: the generic loop's only allowlist. Unregistered tool names always take the "no executor" path
 * (`ToolCallLoop.onUnhandledToolCalls`).
 */
class ToolRegistry(entries: List<ToolRegistryEntry>) {
    private val entriesByName: Map<String, ToolRegistryEntry>

    /** Registration order = order of the tools sent to the model. */
    private val orderedNames: List<String>

    init {
        val table = LinkedHashMap<String, ToolRegistryEntry>()
        entries.forEach { entry -> table.putIfAbsent(entry.name, entry) }
        entriesByName = table
        orderedNames = table.keys.toList()
    }

    fun entry(name: String): ToolRegistryEntry? = entriesByName[name]

    val isEmpty: Boolean get() = entriesByName.isEmpty()

    val names: List<String> get() = orderedNames

    /** All entries, in registration order. Used to merge registries from several sources into one loop. */
    val entries: List<ToolRegistryEntry> get() = orderedNames.mapNotNull { entriesByName[it] }

    /** Tool definitions sent to the model, in registration order. */
    val definitions: List<ToolLoopToolDefinition>
        get() = orderedNames.mapNotNull { entriesByName[it]?.definition }

    companion object {
        val Empty = ToolRegistry(emptyList())
    }
}
