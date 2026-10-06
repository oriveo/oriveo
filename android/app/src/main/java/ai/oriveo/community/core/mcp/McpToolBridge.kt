package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.tools.ToolCallLoop
import ai.oriveo.community.core.tools.ToolCallRejection
import ai.oriveo.community.core.tools.ToolExecutionContext
import ai.oriveo.community.core.tools.ToolExecutionOutcome
import ai.oriveo.community.core.tools.ToolFailureDisposition
import ai.oriveo.community.core.tools.ToolLoopMessage
import ai.oriveo.community.core.tools.ToolLoopToolCall
import ai.oriveo.community.core.tools.ToolLoopToolDefinition
import ai.oriveo.community.core.tools.ToolLoopToolFunction
import ai.oriveo.community.core.tools.ToolRegistryEntry
import ai.oriveo.community.core.tools.ToolScope
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// Wires remote MCP tools into the generic tool loop.
//
// This layer turns "which servers are enabled for this conversation" into registry entries of the generic loop:
// it assembles the usable tools, generates the names sent to the model and the lookup table, runs the
// confirmation gate, performs the call and feeds the result back. UI (the confirmation dialog, step blocks)
// does not live here: the confirmation gate is an injectable interface and step changes are handed out through a
// callback.

// ── Confirmation gate ───────────────────────────────────────

/** The user's choice on the confirmation dialog. */
enum class McpConfirmationChoice {
    /** Allow once. */
    Once,

    /** Allow for the rest of this conversation (only the same tool on the same server, and only in memory). */
    Conversation,

    /** Deny: `tools/call` is not sent and `user_denied` is fed back. */
    Deny,
}

/** What the confirmation dialog shows. The arguments are the raw top-level object from the model (keys verbatim); the dialog itself takes the first 4 and clips them to two lines. */
data class McpConfirmationRequest(
    val conversationId: String,
    val serverId: String,
    val serverName: String,
    /** Host of the server URL (for display; the full URL of a localOnly server never appears here). */
    val serverHost: String,
    val toolName: String,
    val toolTitle: String,
    val arguments: JsonElement,
    val inputSchema: JsonElement,
)

/**
 * Confirmation gate: a suspension point inside the loop; time spent waiting does not count toward the call
 * timeout. Several tools in one leg that need confirmation are executed serially by the loop, so they are
 * naturally asked one at a time in proposal order. When the user taps Stop the launching coroutine is cancelled,
 * and implementations let that cancellation propagate unchanged.
 */
fun interface McpConfirmationGate {
    suspend fun requestConfirmation(request: McpConfirmationRequest): McpConfirmationChoice
}

/** Gate used when there is no UI to ask: always denies (fail closed). Used in production wherever no confirmation dialog is attached. */
object McpDenyingConfirmationGate : McpConfirmationGate {
    override suspend fun requestConfirmation(request: McpConfirmationRequest): McpConfirmationChoice = McpConfirmationChoice.Deny
}

/**
 * "Allow for the rest of this conversation": kept in memory only, keyed by conversation + server + original tool
 * name. It is gone when the process ends and is never persisted.
 *
 * It **can be revoked**: a single tap must not outlive a later permission tightening or definition change.
 * Revocation happens in the storage layer ([McpServerStore] calls [revoke] when a permission changes, a tool catalog
 * is saved or a server is removed), so user actions and re-reading tools all go through one place instead of
 * relying on every call site to remember.
 */
class McpConversationGrants {
    private data class Key(val conversationId: String, val serverId: String, val toolName: String)

    private val granted = ConcurrentHashMap.newKeySet<Key>()

    fun grant(conversationId: String, serverId: String, toolName: String) {
        granted += key(conversationId, serverId, toolName)
    }

    fun isGranted(conversationId: String, serverId: String, toolName: String): Boolean {
        return key(conversationId, serverId, toolName) in granted
    }

    /** Revokes one tool of a server in every conversation; the whole server when [toolName] is null. The next call asks again. */
    fun revoke(serverId: String, toolName: String? = null) {
        val id = serverId.lowercase()
        granted.removeIf { it.serverId == id && (toolName == null || it.toolName == toolName) }
    }

    // Ids identify the same row case-insensitively (NOCASE) in the database, so the same rule applies here;
    // original tool names are case-sensitive.
    private fun key(conversationId: String, serverId: String, toolName: String) =
        Key(conversationId.lowercase(), serverId.lowercase(), toolName)
}

// ── Assembly ────────────────────────────────────────────────

/** One enabled server's input for this request. Read from local storage by [McpToolBridge.plan]. */
data class McpBridgeServerInput(
    val record: McpServerRecord,
    val endpoint: McpServerEndpointResolution,
    val connectionStatus: McpConnectionStatus?,
    val snapshots: List<McpToolSnapshot>,
    val permissions: Map<String, McpToolPermission>,
)

/** One lookup table entry: the name sent to the model -> the server and the original tool name. */
data class McpToolBinding(val outboundName: String, val serverId: String, val toolName: String)

/** One MCP tool usable in this request. */
class McpPlannedTool(
    val binding: McpToolBinding,
    val server: McpServerRecord,
    /** The full URL requests are sent to (the result of [McpServerEndpoint.resolve]; for localOnly it comes from the credential store). */
    val endpoint: String,
    val snapshot: McpToolSnapshot,
    /** Only ever `Auto` or `Ask`: `Off` is already excluded during assembly. */
    val permission: McpToolPermission,
    val definition: ToolLoopToolDefinition,
) {
    /** The full URL may carry a secret, so it stays out of the string representation. */
    override fun toString(): String = "McpPlannedTool(${binding.outboundName})"
}

/** The MCP tools of this request and the lookup table. Empty = the request carries no MCP tool. */
class McpToolPlan(
    val tools: List<McpPlannedTool>,
    /** More tools were usable than `maxToolsPerRequest`, so the ones left after sharing the budget across servers were cut off. */
    val truncated: Boolean,
) {
    val isEmpty: Boolean get() = tools.isEmpty()

    /** The lookup table. A name coming back from the model is looked up only here; a miss means "not in the registry". */
    val nameTable: Map<String, McpToolBinding>
        get() = LinkedHashMap<String, McpToolBinding>().also { table ->
            tools.forEach { table.putIfAbsent(it.binding.outboundName, it.binding) }
        }

    companion object {
        val Empty = McpToolPlan(emptyList(), truncated = false)
    }
}

object McpToolBridge {
    /** Error code fed back for calls skipped once the loop stops proposing tools. */
    const val STOPPED_ERROR_CODE = "tool_loop_stopped"

    /**
     * Assembles the tools usable this time: enabled servers (in enable order) whose connection is usable, minus
     * tools that are "do not use" / quarantined / oversized;
     * beyond `maxToolsPerRequest` the budget is shared across servers one tool per server per round, so a
     * server with a large catalog cannot crowd out the servers enabled after it.
     *
     * A whole server is excluded in two cases: it needs a new sign-in (`needsAuth`), or the full URL of a
     * localOnly server is not on this device
     * (`NeedsAddress`). In the latter case the display URL from the database is never used to send requests.
     */
    fun plan(servers: List<McpBridgeServerInput>, runtimeConfig: McpRuntimeConfig): McpToolPlan {
        if (!runtimeConfig.enabled) return McpToolPlan.Empty
        val tools = mutableListOf<McpPlannedTool>()
        val taken = mutableSetOf<String>()
        val groups = mutableListOf<List<McpPlannedTool>>()
        for (server in servers) {
            val endpoint = server.endpoint.urlOrNull ?: continue
            if (server.connectionStatus == McpConnectionStatus.NeedsAuth) continue
            val outbound = McpToolCatalog.outboundSnapshots(server.snapshots, server.permissions)
            val names = outbound.map { it.toolName }
            val group = mutableListOf<McpPlannedTool>()
            for (snapshot in outbound) {
                val name = McpToolNaming.outboundName(
                    slug = server.record.slug,
                    serverId = server.record.id,
                    toolName = snapshot.toolName,
                    collidesWith = names.filter { it != snapshot.toolName },
                ).name
                // Slugs are unique across servers, so this normally cannot collide; if it does, only the server
                // enabled first keeps the name, because one name must not point to two places.
                if (!taken.add(name)) continue
                group += McpPlannedTool(
                    binding = McpToolBinding(name, server.record.id, snapshot.toolName),
                    server = server.record,
                    endpoint = endpoint,
                    snapshot = snapshot,
                    permission = server.permissions[snapshot.toolName] ?: McpToolPermission.defaultFor(snapshot.readOnly),
                    definition = ToolLoopToolDefinition(
                        function = ToolLoopToolFunction(
                            name = name,
                            // The description is sent as is, with nothing prepended.
                            description = snapshot.description.orEmpty(),
                            parameters = snapshot.inputSchema as? JsonObject ?: EMPTY_OBJECT_SCHEMA,
                        ),
                    ),
                )
            }
            if (group.isNotEmpty()) groups += group
        }
        // Each round takes one tool from every server; name collisions are still resolved in server enable order.
        val eligibleCount = groups.sumOf { it.size }
        var round = 0
        while (tools.size < minOf(eligibleCount, runtimeConfig.maxToolsPerRequest)) {
            for (group in groups) {
                val tool = group.getOrNull(round) ?: continue
                if (tools.size >= runtimeConfig.maxToolsPerRequest) break
                tools += tool
            }
            round += 1
        }
        return McpToolPlan(tools, eligibleCount > tools.size)
    }

    /** Reads the servers enabled for this conversation from local storage and assembles them (switches are per conversation and stored on this device only). Empty when the conversation has no server enabled. */
    suspend fun plan(
        conversationId: String,
        store: McpServerStore,
        credentialStore: McpCredentialStore,
        uid: String,
        runtimeConfig: McpRuntimeConfig,
    ): McpToolPlan {
        if (!runtimeConfig.enabled) return McpToolPlan.Empty
        val enabled = store.fetchEnabledServerIds(conversationId)
        if (enabled.isEmpty()) return McpToolPlan.Empty
        val inputs = enabled.mapNotNull { serverId ->
            val record = store.fetchServer(serverId) ?: return@mapNotNull null
            McpBridgeServerInput(
                record = record,
                endpoint = McpServerEndpoint.resolve(record, uid, credentialStore),
                connectionStatus = store.fetchConnectionState(serverId)?.status,
                snapshots = store.fetchToolSnapshots(serverId),
                permissions = store.fetchToolPermissions(serverId),
            )
        }
        return plan(inputs, runtimeConfig)
    }

    /** Registry entries (registration order = the order sent to the model). */
    fun entries(plan: McpToolPlan, executor: McpToolExecutor): List<ToolRegistryEntry> =
        plan.tools.map { McpToolEntry(it, executor) }

    /** Messages of the first leg: the system prompt (the user's + the safety notice) comes first, followed by the conversation history. */
    fun initialMessages(history: List<ToolLoopMessage>, systemPrompt: String?): List<ToolLoopMessage> =
        listOf(ToolLoopMessage("system", systemPrompt(systemPrompt))) + history

    /** Fixed text appended to the system prompt when MCP tools are enabled (fixture `safety-prompt.txt`). */
    fun systemPrompt(appendingTo: String?): String {
        val trimmed = appendingTo.orEmpty().trim()
        return if (trimmed.isEmpty()) McpSafetyPrompt.TEXT else trimmed + "\n\n" + McpSafetyPrompt.TEXT
    }

    /**
     * Loop limits when MCP tools are attached. The consecutive-failure circuit breaker is turned off: an error
     * from one third-party server must not blow up the whole answer, and the only whole-run abort is the user
     * tapping Stop. The step count is still bounded by `maxSteps`, so errors are not fed back forever.
     */
    fun limits(runtimeConfig: McpRuntimeConfig): ToolCallLoop.Limits = ToolCallLoop.Limits(
        maxSteps = ToolCallLoop.Limits.effectiveMaxSteps(runtimeConfig.effectiveMaxSteps),
        maxConsecutiveToolFailures = Int.MAX_VALUE,
    )

    /** Fixed phrases the loop feeds back to the model, in neutral wording. */
    val prompts: ToolCallLoop.Prompts = ToolCallLoop.Prompts(
        stepLimitReached = "The tool call limit was reached. Answer now from the tool results you already have. Do not call another tool.",
        tokenBudgetReached = "The token budget for tool use was reached. Answer now from the tool results you already have. Do not call another tool.",
        stoppedByStepLimit = "The tool call limit was reached.",
        stoppedByTokenBudget = "The token budget for tool use was reached.",
        stoppedCode = STOPPED_ERROR_CODE,
    )

    private val EMPTY_OBJECT_SCHEMA = buildJsonObject { put("type", "object") }
}

// ── Execution ───────────────────────────────────────────────

/** A call that did not succeed. [code] is one of the closed set of error codes; the model only gets that code and one fixed sentence, never the server's own text. */
class McpToolFailure(val code: McpErrorCode) : Exception(code.wireValue)

/** Per-step payload: the raw arguments and the beginning of the returned result. Stored apart from the message. */
data class McpToolStepPayload(
    /** Raw arguments from the model (canonical JSON). The storage layer caps them at 16 KB. */
    val arguments: String? = null,
    /** Beginning of the returned result (capped at 2 KB by the storage layer); on failure it is the server's error text, capped at 200 characters. */
    val resultPrefix: String? = null,
) {
    companion object {
        const val MAX_FAILURE_TEXT_LENGTH = 200
    }
}

/**
 * A step's state change (the fields of `toolSteps`). The message model takes the summary stored on the message
 * from it; [payload] does not go into the message: it is stored separately.
 */
data class McpToolStepUpdate(
    val id: String,
    val serverId: String,
    val serverName: String,
    val toolName: String,
    val title: String,
    val argsSummary: String,
    val status: Status,
    val errorCode: McpErrorCode? = null,
    val step: Int,
    val durationMs: Int? = null,
    /** The raw arguments come with the first callback, the result / failure text with the terminal state. */
    val payload: McpToolStepPayload? = null,
    /**
     * This step is parked waiting for the user to re-authorize (the status is `needsAuth` but not terminal yet:
     * after authorization it continues, or it is skipped).
     * Not part of the message; the UI uses it to tell "parked, waiting" from "ended because authorization
     * expired".
     */
    val awaitingAuth: Boolean = false,
) {
    enum class Status(val wireValue: String) {
        Running("running"),
        Done("done"),
        Failed("failed"),
        Denied("denied"),
        NeedsAuth("needsAuth"),
        Interrupted("interrupted"),
    }
}

/**
 * Verdict of re-checking local state before execution. Assembly ([McpToolBridge.plan]) reads the database only
 * once, at send time,
 * while an answer can run for a long time and even pause to wait for the user. Meanwhile the user may have
 * changed a permission, turned a switch off or removed the server, and a new sign-in
 * may have changed the tool definitions. So the state is re-read before every call and before every resume.
 */
sealed class McpToolRevalidation {
    /** Still usable. [permission] is the permission in effect right now (only ever `Auto` or `Ask`). */
    data class Usable(
        val permission: McpToolPermission,
        /** The server is marked as needing a new sign-in: the cached client and the token it carries are discarded, and the next call reconnects. */
        val discardClient: Boolean = false,
    ) : McpToolRevalidation()

    /**
     * No longer usable: the server is gone, the conversation's switch is off, the tool is missing or quarantined,
     * the definition differs from the one assembled, or the permission became "do not use".
     * No request is sent and `tool_unavailable` is fed back.
     */
    data object Unavailable : McpToolRevalidation()
}

/** The MCP executor for one answer: holds this run's clients (one connection per server), the confirmation gate and the in-memory grants. */
class McpToolExecutor(
    private val conversationId: String,
    private val gate: McpConfirmationGate,
    private val grants: McpConversationGrants,
    /** Returns a usable access token for this server (refreshing it first when it is about to expire); null when there is none. */
    private val tokenProvider: suspend (serverId: String) -> String?,
    private val makeClient: (endpoint: String) -> McpClient,
    private val onStep: suspend (McpToolStepUpdate) -> Unit = {},
    private val now: () -> Long = System::currentTimeMillis,
    /**
     * Pause gate for authorization expiring mid-run. When null there is no pause: the step simply ends as
     * `needsAuth` and the answer continues.
     */
    private val authPause: McpAuthPauseGate? = null,
    /** Called when a server turns out to need a new sign-in (records the connection state, so the panel shows "authorization expired"). */
    private val onNeedsAuth: suspend (serverId: String) -> Unit = {},
    /**
     * Re-reads local state before a call (see [McpToolRevalidation]). When null the assembly-time verdict is
     * reused; that is meant only for focused tests without storage,
     * and production always wires it through `McpChatToolRunner.executor`. A failed database read counts as
     * "not usable" (fail closed).
     */
    private val revalidate: (suspend (McpPlannedTool) -> McpToolRevalidation)? = null,
) {
    private val clientsLock = Mutex()
    private val clients = mutableMapOf<String, McpClient>()

    /** Servers for which the user already tapped "skip this step" during this answer: later calls in the same run no longer stop to ask one by one. */
    private val authSkippedServers = mutableSetOf<String>()

    suspend fun execute(tool: McpPlannedTool, call: ToolLoopToolCall, context: ToolExecutionContext): ToolExecutionOutcome {
        val arguments = validatedArguments(call.function.arguments, tool.snapshot.inputSchema)
        var step = McpToolStepUpdate(
            id = "${context.stepNumber}:${call.id}",
            serverId = tool.server.id,
            serverName = tool.server.name,
            toolName = tool.snapshot.toolName,
            title = tool.snapshot.title,
            argsSummary = McpArgsSummary.summary(tool.snapshot.inputSchema, arguments),
            status = McpToolStepUpdate.Status.Running,
            step = context.stepNumber,
            payload = McpToolStepPayload(arguments = McpJson.canonical(arguments)),
        )

        // The step is running from the moment it is proposed: the step block and the activity status line are
        // both present while waiting for the user's confirmation (that is waiting for a person, not silence).
        // The raw arguments are handed out only with this first callback.
        onStep(step)
        step = step.copy(payload = null)

        // Re-check + confirmation gate before the call. Non-null means the step already has a result (the user
        // denied it) and no request is sent.
        val clearance = Clearance()
        clear(tool, arguments, step, clearance)?.let { return it }

        // The user already tapped Skip for this server in this run: send no request and do not stop to ask again.
        if (authPause != null && clientsLock.withLock { tool.server.id.lowercase() in authSkippedServers }) {
            finish(step.copy(status = McpToolStepUpdate.Status.Failed, errorCode = McpErrorCode.AuthSkipped))
            throw McpToolFailure(McpErrorCode.AuthSkipped)
        }

        var started = now()
        // After re-authorization the step resumes only once: if authorization expires again it ends as needsAuth
        // instead of pausing repeatedly on the same step.
        var resumedAfterAuth = false
        while (true) {
            try {
                return attempt(tool, arguments, step, started)
            } catch (failure: McpToolFailure) {
                val serverKey = tool.server.id.lowercase()
                val gate = authPause
                if (failure.code != McpErrorCode.NeedsAuth || gate == null) throw failure
                if (resumedAfterAuth) {
                    finish(step.copy(status = McpToolStepUpdate.Status.NeedsAuth, errorCode = McpErrorCode.NeedsAuth))
                    throw failure
                }
                // Park on this step: it shows "authorization expired" and the block offers "Re-authorize / Skip
                // this step". The wait does not count toward the call timeout.
                onStep(step.copy(status = McpToolStepUpdate.Status.NeedsAuth, errorCode = McpErrorCode.NeedsAuth, awaitingAuth = true))
                val decision = try {
                    gate.awaitDecision(
                        McpAuthPauseRequest(conversationId, tool.server.id, tool.server.name, step.id),
                    ).also { currentCoroutineContext().ensureActive() }
                } catch (error: CancellationException) {
                    // The user tapped Stop while parked: the step never ran, so it is recorded as interrupted.
                    finish(step.copy(status = McpToolStepUpdate.Status.Interrupted, errorCode = McpErrorCode.Cancelled))
                    throw error
                }
                when (decision) {
                    McpAuthPauseDecision.Resume -> {
                        // Reconnect with the new credentials; results of earlier steps are in the loop history and
                        // need not be redone.
                        clientsLock.withLock { clients.remove(serverKey) }
                        resumedAfterAuth = true
                        // Re-read before resuming: a new sign-in refreshes the tool catalog along the way, so this
                        // tool may just have been quarantined,
                        // and the user may have changed a permission or removed the server while the step was parked.
                        clear(tool, arguments, step, clearance)?.let { return it }
                        started = now()
                        onStep(step.copy(status = McpToolStepUpdate.Status.Running))
                    }
                    McpAuthPauseDecision.Skip -> {
                        clientsLock.withLock { authSkippedServers += serverKey }
                        finish(step.copy(status = McpToolStepUpdate.Status.Failed, errorCode = McpErrorCode.AuthSkipped))
                        throw McpToolFailure(McpErrorCode.AuthSkipped)
                    }
                }
            }
        }
    }

    /** Per-step memory of "the user already allowed this call": resuming does not ask the same thing twice. */
    private class Clearance {
        var approved = false
        var permission: McpToolPermission = McpToolPermission.Ask
    }

    /**
     * Re-checks local state and runs the confirmation gate. Not usable -> emits the `tool_unavailable` terminal
     * state and throws [McpToolFailure]; the user denies -> emits the terminal state and
     * returns the result fed back to the model; the call may proceed -> returns null.
     */
    private suspend fun clear(
        tool: McpPlannedTool,
        arguments: JsonElement,
        step: McpToolStepUpdate,
        clearance: Clearance,
    ): ToolExecutionOutcome? {
        clearance.permission = currentPermission(tool, step)
        // "Ask every time" never sends tools/call without the user's approval. A tool that was "run
        // automatically" at assembly time and is "ask every time" by now has to ask as well.
        val needsConfirmation = clearance.permission != McpToolPermission.Auto && !clearance.approved &&
            !grants.isGranted(conversationId, tool.server.id, tool.snapshot.toolName)
        if (!needsConfirmation) return null
        val choice = try {
            gate.requestConfirmation(
                McpConfirmationRequest(
                    conversationId = conversationId,
                    serverId = tool.server.id,
                    serverName = tool.server.name,
                    serverHost = McpOrigin.parse(tool.endpoint)?.host.orEmpty(),
                    toolName = tool.snapshot.toolName,
                    toolTitle = tool.snapshot.title,
                    arguments = arguments,
                    inputSchema = tool.snapshot.inputSchema,
                ),
            ).also { currentCoroutineContext().ensureActive() }
        } catch (error: CancellationException) {
            // The user tapped Stop while the confirmation was pending: the step never ran, so it is recorded as interrupted.
            finish(step.copy(status = McpToolStepUpdate.Status.Interrupted, errorCode = McpErrorCode.Cancelled))
            throw error
        } catch (error: Exception) {
            // The gate itself failed: without approval nothing is let through (fail closed); degrade and feed it
            // back as one failure.
            finish(step.copy(status = McpToolStepUpdate.Status.Failed, errorCode = McpErrorCode.ServerError))
            throw McpToolFailure(McpErrorCode.ServerError)
        }
        when (choice) {
            McpConfirmationChoice.Deny -> {
                finish(step.copy(status = McpToolStepUpdate.Status.Denied, errorCode = McpErrorCode.UserDenied))
                // A denial is not a server failure: it is fed back as a normal result and does not advance the
                // consecutive-failure count.
                return ToolExecutionOutcome(
                    ToolCallLoop.errorContent(
                        McpErrorCode.UserDenied.wireValue,
                        "The user declined this tool call. Do not call it again for this request; continue without it.",
                    ),
                )
            }
            McpConfirmationChoice.Conversation -> {
                // The tool may have been changed while the user was looking at the dialog: re-check first, and
                // record "allow all" only if it is still usable.
                clearance.permission = currentPermission(tool, step)
                grants.grant(conversationId, tool.server.id, tool.snapshot.toolName)
            }
            // The dialog may have been open for a long time: take one more look before letting the call through.
            McpConfirmationChoice.Once -> clearance.permission = currentPermission(tool, step)
        }
        clearance.approved = true
        return null
    }

    /** The permission in effect right now; when the tool is no longer usable it emits the `tool_unavailable` terminal state and throws (no request is sent). */
    private suspend fun currentPermission(tool: McpPlannedTool, step: McpToolStepUpdate): McpToolPermission {
        val check = revalidate ?: return tool.permission
        val result = try {
            check(tool)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            McpToolRevalidation.Unavailable
        }
        val serverKey = tool.server.id.lowercase()
        return when (result) {
            is McpToolRevalidation.Usable -> {
                if (result.discardClient) clientsLock.withLock { clients.remove(serverKey) }
                result.permission
            }
            McpToolRevalidation.Unavailable -> {
                // The server may have been removed: drop the cached client together with the token it carries.
                clientsLock.withLock { clients.remove(serverKey) }
                finish(step.copy(status = McpToolStepUpdate.Status.Failed, errorCode = McpErrorCode.ToolUnavailable))
                throw McpToolFailure(McpErrorCode.ToolUnavailable)
            }
        }
    }

    /**
     * Connects and calls once. Success, a tool error and cancellation all emit the terminal state here; only
     * "needs a new sign-in" with a pause gate present
     * emits none, leaving [execute] to decide whether to park or to end.
     */
    private suspend fun attempt(
        tool: McpPlannedTool,
        arguments: JsonElement,
        initial: McpToolStepUpdate,
        started: Long,
    ): ToolExecutionOutcome {
        var step = initial
        try {
            val client = connectedClient(tool)
            val result = try {
                client.callTool(tool.snapshot.toolName, arguments)
            } catch (error: McpClientException) {
                throw failure(error)
            }
            step = step.copy(durationMs = elapsedMs(started))
            val code = result.errorCode
            if (code == McpErrorCode.ToolError || code == McpErrorCode.NeedsInputUnsupported) {
                // The failure text goes only into the local per-step payload, never into `toolSteps` or back to the model.
                val text = result.text.take(McpToolStepPayload.MAX_FAILURE_TEXT_LENGTH)
                step = step.copy(payload = text.takeIf { it.isNotEmpty() }?.let { McpToolStepPayload(resultPrefix = it) })
                throw McpToolFailure(code)
            }
            finish(
                step.copy(
                    status = McpToolStepUpdate.Status.Done,
                    errorCode = code,
                    payload = result.text.takeIf { it.isNotEmpty() }?.let { McpToolStepPayload(resultPrefix = it) },
                ),
            )
            return ToolExecutionOutcome(
                buildJsonObject {
                    put("ok", true)
                    put("result", JsonPrimitive(result.text.ifEmpty { "The tool returned no content." }))
                }.toString(),
            )
        } catch (failure: McpToolFailure) {
            if (failure.code == McpErrorCode.NeedsAuth) {
                withContext(NonCancellable) { onNeedsAuth(tool.server.id) }
                // A pause gate is present: emit no terminal state yet; execute decides whether to park and how to end.
                if (authPause != null) throw failure
            }
            finish(
                step.copy(
                    durationMs = step.durationMs ?: elapsedMs(started),
                    status = if (failure.code == McpErrorCode.NeedsAuth) McpToolStepUpdate.Status.NeedsAuth else McpToolStepUpdate.Status.Failed,
                    errorCode = failure.code,
                ),
            )
            throw failure
        } catch (error: CancellationException) {
            finish(step.copy(durationMs = elapsedMs(started), status = McpToolStepUpdate.Status.Interrupted, errorCode = McpErrorCode.Cancelled))
            throw error
        }
    }

    /** The terminal state must always be emitted, even if the launching coroutine was already cancelled (otherwise the step block would stay on running forever). */
    private suspend fun finish(step: McpToolStepUpdate) = withContext(NonCancellable) { onStep(step) }

    /** Each server is connected only once per run; the token comes from the credential store (the address of a localOnly server was resolved during assembly). */
    private suspend fun connectedClient(tool: McpPlannedTool): McpClient = clientsLock.withLock {
        clients[tool.server.id.lowercase()]?.let { return@withLock it }
        val token = try {
            tokenProvider(tool.server.id)
        } catch (error: CancellationException) {
            throw error
        } catch (error: McpAuthorizerException) {
            throw McpToolFailure(if (error.isTransient) McpErrorCode.Unreachable else McpErrorCode.NeedsAuth)
        } catch (error: Exception) {
            throw McpToolFailure(McpErrorCode.Unreachable)
        }
        val client = makeClient(tool.endpoint)
        when (val outcome = client.connect(token)) {
            is McpConnectOutcome.Connected -> client.also { clients[tool.server.id.lowercase()] = it }
            McpConnectOutcome.NeedsAuth -> throw McpToolFailure(McpErrorCode.NeedsAuth)
            McpConnectOutcome.Unreachable -> {
                currentCoroutineContext().ensureActive()
                throw McpToolFailure(McpErrorCode.Unreachable)
            }
            McpConnectOutcome.NotMcp -> throw McpToolFailure(McpErrorCode.ServerError)
            is McpConnectOutcome.Failed -> throw failure(outcome.error)
        }
    }

    /** A cancellation must be restored as a cancellation, so the loop winds the whole run down as "the user tapped Stop" instead of feeding it back as a failure. */
    private suspend fun failure(error: McpClientException): Exception =
        if (error.code == McpErrorCode.Cancelled && !currentCoroutineContext().isActive) {
            CancellationException("mcp tool call cancelled")
        } else {
            McpToolFailure(error.code)
        }

    private fun elapsedMs(started: Long): Int = (now() - started).coerceIn(0, Int.MAX_VALUE.toLong()).toInt()

    companion object {
        /** The arguments must be a JSON object carrying every `required` key; otherwise the loop counts it as a model self-correction. */
        fun validatedArguments(raw: String, schema: JsonElement): JsonElement {
            val trimmed = raw.trim()
            val parsed = if (trimmed.isEmpty()) JsonObject(emptyMap()) else McpJson.parseOrNull(trimmed)
            val arguments = parsed as? JsonObject
                ?: throw ToolCallRejection("invalid_arguments", "Tool arguments must be a JSON object.")
            val required = schema["required"].jsonArrayOrNull.orEmpty().mapNotNull { it.stringOrNull }
            val missing = required.filter { it !in arguments }
            if (missing.isNotEmpty()) {
                throw ToolCallRejection("missing_required_arguments", "Missing required arguments: ${missing.joinToString(", ")}.")
            }
            return arguments
        }
    }
}

/** One MCP tool = one registry entry. */
class McpToolEntry(private val tool: McpPlannedTool, private val executor: McpToolExecutor) : ToolRegistryEntry {
    override val name: String get() = tool.binding.outboundName
    override val scope: ToolScope get() = ToolScope.Mcp
    override val definition: ToolLoopToolDefinition get() = tool.definition

    override suspend fun execute(call: ToolLoopToolCall, context: ToolExecutionContext): ToolExecutionOutcome =
        executor.execute(tool, call, context)

    /** Always degrades; only the user tapping Stop aborts the whole run (cancellation does not pass through here, the loop propagates it as is). */
    override fun failureDisposition(error: Throwable): ToolFailureDisposition {
        if (error is CancellationException) return ToolFailureDisposition.Fatal
        val code = (error as? McpToolFailure)?.code ?: McpErrorCode.ServerError
        return ToolFailureDisposition.Degrade(
            code = code.wireValue,
            message = "The tool call did not succeed. Do not invent its result; continue with what you have.",
        )
    }
}

/** An authorizer used only for refreshing tokens needs no browser: actually opening one (a new sign-in) is a UI flow and never happens inside the chat loop. */
object McpNoBrowserSession : McpBrowserSession {
    override suspend fun authorize(url: String, redirectUri: String): String =
        throw McpAuthorizerException.of(McpAuthorizerException.Kind.Cancelled)
}
