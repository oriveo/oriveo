package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.tools.OpenAIChatToolAdapter
import ai.oriveo.community.core.tools.ProviderToolLegRunner
import ai.oriveo.community.core.tools.ToolCallLoop
import ai.oriveo.community.core.tools.ToolLoopLegRunning
import ai.oriveo.community.core.tools.ToolLoopToolCall
import ai.oriveo.community.core.tools.ToolLoopTransportAvailability
import ai.oriveo.community.core.tools.ToolRegistry
import ai.oriveo.community.core.tools.ToolRegistryEntry
import ai.oriveo.community.core.tools.toolLoopMessagesFrom
import io.ktor.client.HttpClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.Json

/**
 * Entry point that wires remote MCP into the chat send path:
 *
 * 1. [plan]: the MCP tools available to this send (empty = the request carries no MCP tools and takes the usual path).
 * 2. [run]: drives the generic tool loop with a leg runner that speaks the connection's wire protocol.
 *
 * The confirmation gate defaults to [McpDenyingConfirmationGate]: with no UI to ask, a tool set to "ask every time" never
 * sends `tools/call` without the user's consent; it is denied rather than let through. Production wiring replaces
 * [confirmationGate] with the chat screen's confirmation dialog ([McpConfirmationCoordinator]).
 */
class McpChatToolRunner(
    private val httpClient: HttpClient,
    private val json: Json,
    private val store: McpServerStore,
    private val credentialStore: McpCredentialStore,
    private val grants: McpConversationGrants = McpConversationGrants(),
    /**
     * MCP runtime limits. Production passes `MetadataClient.mcpRuntimeConfig()` (read from the model catalog, with
     * built-in defaults when it is absent); focused tests that do not wire it use the fallback.
     */
    private val runtimeConfig: () -> McpRuntimeConfig = { McpRuntimeConfig.fallback },
    /** The loop only refreshes tokens; it never signs in again (that opens a browser and belongs to the UI flow). */
    private val authorizer: McpAuthorizer = McpAuthorizer(McpHttpAuthTransport(), McpNoBrowserSession, credentialStore),
    mcpTransport: (() -> McpRawTransport)? = null,
    /**
     * Conversation switch writes run here (production passes an application-level scope): when the user flips a switch and
     * leaves the chat screen, or flips it again right away, the write must not be cancelled together with the UI coroutine.
     * Otherwise the UI shows it on while nothing was persisted, and the next message goes out without tools.
     */
    private val writeScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    /** The confirmation gate. Production wires it to [McpConfirmationCoordinator]. */
    @Volatile var confirmationGate: McpConfirmationGate = McpDenyingConfirmationGate

    /** The steps paused on an authorization that expired mid-run. Step blocks read it to draw "Re-authorize / Skip this step". */
    val authPauses = McpAuthPauseCoordinator()

    /** Entry point for re-authorization, wired by the setup and management UI; the default is a no-op placeholder. */
    @Volatile var reauthorizer: McpReauthorizer = McpUnavailableReauthorizer

    private val _stepLimitReachedMessageIds = MutableStateFlow<Set<String>>(emptySet())

    /** Messages whose tool loop hit the step limit (shown as a trailing line). Known only to this process; not persisted. */
    val stepLimitReachedMessageIds: StateFlow<Set<String>> = _stepLimitReachedMessageIds.asStateFlow()

    fun markStepLimitReached(messageId: String) {
        _stepLimitReachedMessageIds.update { it + messageId.lowercase() }
    }

    /** The same message is regenerated: the previous run's "limit reached" flag does not carry over. */
    fun clearStepLimitReached(messageId: String) {
        _stepLimitReachedMessageIds.update { it - messageId.lowercase() }
    }

    private val mcpTransport: McpRawTransport by lazy { mcpTransport?.invoke() ?: KtorMcpRawTransport() }

    /**
     * Whether this connection and model can carry MCP tools: the tool_call capability projection permits it and the
     * outbound protocol has a tool adapter.
     */
    fun connectionSupportsTools(
        provider: Provider,
        model: AIModel,
        memoryVerdict: Boolean?,
        /**
         * The local identity of this connection (the generation / epoch held by the repository). A relay's tool call
         * declaration and its connection memory are both scoped by it; without it the projection stays "pending" and never
         * permits. The send path passes `requestOptions.capabilityEvidenceIdentity`,
         * the UI passes `ProviderRepository.capabilityEvidenceIdentity`. Official connections do not need it.
         */
        localIdentity: CapabilityEvidenceIdentity? = null,
    ): Boolean {
        val projection = CapabilityEvidenceProductionAdapter.toolCallProjection(
            provider = provider,
            model = model,
            identity = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(provider, model, localIdentity),
            memoryVerdict = memoryVerdict,
        )
        return projection.permitsOutbound("tool_call") && ToolLoopTransportAvailability.supportsToolTransport(provider, model)
    }

    /** Availability for the entry point and the panel. Nothing is reported as unavailable before a model is chosen. */
    fun availability(
        provider: Provider?,
        model: AIModel?,
        memoryVerdict: Boolean?,
        localIdentity: CapabilityEvidenceIdentity? = null,
    ): McpToolAvailability = when {
        provider == null || model == null -> McpToolAvailability.Available
        connectionSupportsTools(provider, model, memoryVerdict, localIdentity) -> McpToolAvailability.Available
        else -> McpToolAvailability.ModelUnsupported
    }

    /** Master switch (`mcpRuntimeConfig.enabled`): when false the entry point is hidden and stored servers are kept. */
    val isFeatureEnabled: Boolean get() = runtimeConfig().enabled

    /**
     * Data for the tool panel. `conversationId` is a draft id until a new conversation sends its first message. When
     * local storage cannot be read, the panel is presented as having no servers.
     */
    suspend fun loadPanel(conversationId: String, availability: McpToolAvailability): McpToolPanelState = try {
        McpToolPanelModel.load(conversationId, store, credentialStore, LOCAL_PARTITION_ID, runtimeConfig(), availability)
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        McpToolPanelState.Empty.copy(availability = availability)
    }

    /** This conversation's switch for one server (remembered per conversation). */
    suspend fun setServerEnabled(enabled: Boolean, conversationId: String, serverId: String) =
        store.setServerEnabled(enabled, conversationId, serverId)

    private val switchWriteLock = Any()
    private var lastSwitchWrite: Job? = null

    /**
     * Persisting a switch flip: independent of the caller's coroutine and not cancellable by the UI; repeated flips are
     * written serially in call order. The returned Job is only for awaiting the write (the UI re-reads the panel);
     * cancelling the coroutine that awaits it does not affect the write. A failed write does not throw: the re-read panel
     * shows what storage holds.
     */
    fun enqueueServerEnabled(enabled: Boolean, conversationId: String, serverId: String): Job = synchronized(switchWriteLock) {
        val previous = lastSwitchWrite
        writeScope.launch {
            previous?.join()
            runCatching { store.setServerEnabled(enabled, conversationId, serverId) }
        }.also { lastSwitchWrite = it }
    }

    /** Waits for in-flight switch writes. The send path must await this before reading conversation switches ([plan] and [adoptDraftSwitches] already do). */
    suspend fun awaitSwitchWrites() {
        synchronized(switchWriteLock) { lastSwitchWrite }?.join()
    }

    /** A new conversation sends its first message: switches under the draft id move to the real conversation id. A failure does not block the send (it just goes out without tools). */
    suspend fun adoptDraftSwitches(draftConversationId: String, conversationId: String) {
        awaitSwitchWrites()
        try {
            store.moveConversationSwitches(draftConversationId, conversationId)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            // Ignored.
        }
    }

    /** Discards a draft (another new conversation is started): its switches are cleared too, so a new conversation starts with everything off. */
    suspend fun discardDraftSwitches(draftConversationId: String) {
        awaitSwitchWrites()
        try {
            store.clearConversationSwitches(draftConversationId)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            // Ignored.
        }
    }

    /** Step details read the stored payload; null when there is none (for example it was cleared with its server). */
    suspend fun fetchStepPayload(messageId: String, stepId: String): McpStepPayload? = try {
        store.fetchStepPayload(messageId, stepId)
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        null
    }

    /**
     * The MCP tools available to this send. Empty when the connection cannot carry tools (known to be unsupported),
     * the conversation has no server switched on, or local storage cannot be read. All of these fall back
     * to a plain send without tools; an unreadable MCP configuration never fails the whole message.
     */
    suspend fun plan(
        conversationId: String,
        provider: Provider,
        model: AIModel?,
        memoryVerdict: Boolean?,
        localIdentity: CapabilityEvidenceIdentity? = null,
    ): McpToolPlan {
        if (model == null) return McpToolPlan.Empty
        // A switch the user just flipped in the tool panel may still be persisting: wait for it so this send carries what the user sees.
        awaitSwitchWrites()
        return try {
            // Check the conversation switches first (one local query): most sends have no server on, so the capability projection is not needed.
            val plan = McpToolBridge.plan(conversationId, store, credentialStore, LOCAL_PARTITION_ID, runtimeConfig())
            if (plan.isEmpty || !connectionSupportsTools(provider, model, memoryVerdict, localIdentity)) McpToolPlan.Empty else plan
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            McpToolPlan.Empty
        }
    }

    /**
     * Stores a step's payload (raw arguments / the head of the result) next to the message. A failed write does not
     * affect the answer: the step details simply have less to show.
     */
    suspend fun saveStepPayload(messageId: String, update: McpToolStepUpdate) {
        val payload = update.payload ?: return
        try {
            store.saveStepPayload(messageId, update.id, payload.arguments, payload.resultPrefix, serverId = update.serverId)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            // Ignored: the payload is a local viewing aid, not part of the answer.
        }
    }

    fun executor(conversationId: String, onStep: suspend (McpToolStepUpdate) -> Unit = {}): McpToolExecutor {
        val config = runtimeConfig()
        return McpToolExecutor(
            conversationId = conversationId,
            gate = McpConfirmationGate { request -> confirmationGate.requestConfirmation(request) },
            grants = grants,
            tokenProvider = { serverId -> authorizer.validAccessToken(serverId, LOCAL_PARTITION_ID) },
            makeClient = { endpoint -> McpClient(endpoint, config, mcpTransport) },
            onStep = onStep,
            authPause = authPauses,
            onNeedsAuth = ::markNeedsAuth,
            revalidate = { tool -> revalidate(conversationId, tool) },
        )
    }

    /**
     * Re-reads local state right before a call: the plan reads storage only once at send time, and afterwards the user may
     * have changed a permission, turned the switch off or removed the server, and a re-login may have changed the tool
     * definition. If anything no longer matches, no request is sent.
     */
    private suspend fun revalidate(conversationId: String, tool: McpPlannedTool): McpToolRevalidation {
        val serverId = tool.server.id
        val record = store.fetchServer(serverId) ?: return McpToolRevalidation.Unavailable
        // The address changed: the token was issued for the original address, so nothing more is sent to it in this run.
        if (record.url != tool.server.url) return McpToolRevalidation.Unavailable
        if (store.fetchEnabledServerIds(conversationId).none { it.equals(serverId, ignoreCase = true) }) return McpToolRevalidation.Unavailable
        val snapshot = store.fetchToolSnapshots(serverId).firstOrNull { it.toolName == tool.snapshot.toolName }
            ?: return McpToolRevalidation.Unavailable
        // Quarantined, oversized, or the content hash / display title differs from what was sent to the model.
        if (snapshot.pendingReview || snapshot.oversized ||
            snapshot.contentHash != tool.snapshot.contentHash || snapshot.title != tool.snapshot.title
        ) {
            return McpToolRevalidation.Unavailable
        }
        val permission = store.fetchToolPermissions(serverId)[snapshot.toolName] ?: McpToolPermission.defaultFor(snapshot.readOnly)
        if (permission == McpToolPermission.Off) return McpToolRevalidation.Unavailable
        return McpToolRevalidation.Usable(
            permission = if (permission == McpToolPermission.Auto) McpToolPermission.Auto else McpToolPermission.Ask,
            discardClient = store.fetchConnectionState(serverId)?.status == McpConnectionStatus.NeedsAuth,
        )
    }

    /** A server's credential was rejected inside the loop: record it so the tool panel and the management screen show "authorization expired". */
    private suspend fun markNeedsAuth(serverId: String) {
        try {
            val current = store.fetchConnectionState(serverId)
            if (current?.status == McpConnectionStatus.NeedsAuth) return
            store.saveConnectionState(
                (current ?: McpConnectionState(serverId = serverId)).copy(status = McpConnectionStatus.NeedsAuth),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            // Ignored: a missing state record only affects the panel hint, not this answer.
        }
    }

    /** Runs the tool loop for one answer. */
    suspend fun run(
        conversationId: String,
        provider: Provider,
        model: AIModel,
        modelId: String,
        messages: List<ChatMessage>,
        systemPrompt: String?,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
        plan: McpToolPlan,
        onStep: suspend (McpToolStepUpdate) -> Unit = {},
        onUnhandledToolCalls: suspend (List<ToolLoopToolCall>) -> Unit = {},
        onProgress: suspend (ToolCallLoop.ProgressEvent) -> Unit = {},
    ): ToolCallLoop.Result {
        val legRunner = ProviderToolLegRunner(
            client = httpClient,
            provider = provider,
            model = model,
            modelId = modelId,
            reasoningMode = reasoningMode,
            json = json,
            requestOptions = requestOptions,
        )
        return makeLoop(plan, executor(conversationId, onStep), legRunner, runtimeConfig(), onUnhandledToolCalls)
            .run(McpToolBridge.initialMessages(toolLoopMessagesFrom(messages, provider, model, json), systemPrompt), onProgress)
    }

    companion object {
        /** Builds the loop (production and tests share this single construction site). */
        fun makeLoop(
            plan: McpToolPlan,
            executor: McpToolExecutor,
            legRunner: ToolLoopLegRunning,
            runtimeConfig: McpRuntimeConfig,
            // Names outside the lookup table are not executed; the caller shows them with the existing notice card.
            onUnhandledToolCalls: suspend (List<ToolLoopToolCall>) -> Unit,
        ): ToolCallLoop = ToolCallLoop(
            registry = ToolRegistry(McpToolBridge.entries(plan, executor)),
            legRunner = legRunner,
            // Neutral shape; each protocol's wire shape is translated by the protocol adapter in the leg runner.
            adapter = OpenAIChatToolAdapter(),
            limits = McpToolBridge.limits(runtimeConfig),
            prompts = McpToolBridge.prompts,
            onUnhandledToolCalls = onUnhandledToolCalls,
        )
    }
}
