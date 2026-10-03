package ai.oriveo.community.feature.chat

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import ai.oriveo.community.core.mcp.McpAuthPauseDecision
import ai.oriveo.community.core.mcp.McpChatToolRunner
import ai.oriveo.community.core.mcp.McpConfirmationCoordinator
import ai.oriveo.community.core.mcp.McpToolAvailability
import ai.oriveo.community.core.mcp.McpToolPanelState
import ai.oriveo.community.core.mcp.McpToolStep
import ai.oriveo.community.core.mcp.PendingMcpAuthPause
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.feature.chat.mcp.McpStepDetailState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Chat-side orchestration of remote MCP: the state of the composer's "Tools" pill, the tool panel, the step detail,
 * and "Re-authorize / Skip this step" when authorization expires mid-run.
 *
 * The VM only wires things up and exposes state; MCP is a domain of its own. The real
 * tool loop runs in `ChatRepository`; this class handles the UI side only: read local storage, flip conversation toggles, pass the user's choices back to the gate.
 *
 * Toggles are remembered per conversation. A new conversation has no id until its first message is sent, so [draftConversationId]
 * is the key until then; on first send [adoptDraft] moves its toggles under the real conversation id.
 */
class ChatMcpCoordinator(
    private val scope: CoroutineScope,
    private val runner: McpChatToolRunner?,
    private val confirmationCoordinator: McpConfirmationCoordinator?,
    private val draftConversationId: String,
    private val currentConversationId: () -> String?,
    private val activeProvider: () -> Provider?,
    private val activeModel: () -> AIModel?,
    private val toolCallMemoryVerdict: (Provider, AIModel) -> Boolean? = { _, _ -> null },
    /** Local identity of this connection (scopes the tool-call verdict for relays); production passes `ProviderRepository.capabilityEvidenceIdentity`. */
    private val capabilityEvidenceIdentity: suspend (Provider, String) -> CapabilityEvidenceIdentity? = { _, _ -> null },
) {
    /** The single state shared by the panel and the pill. Read from local storage; fresh only after [refresh]. */
    var panelState: McpToolPanelState by mutableStateOf(McpToolPanelState.Empty)
        private set

    var showToolPanel: Boolean by mutableStateOf(false)
        private set

    var stepDetail: McpStepDetailState? by mutableStateOf(null)
        private set

    /** Master switch (`mcpRuntimeConfig.enabled`): when false the entry point is hidden entirely and existing configuration is kept. Also hidden when not wired up. */
    val isEntryVisible: Boolean get() = runner?.isFeatureEnabled == true

    private var refreshJob: Job? = null

    /** A server's own icon, taken from the panel data; null when it has none or is no longer in the list (the UI falls back to the initial tile). */
    fun serverIconUrl(serverId: String): String? =
        panelState.rows.firstOrNull { it.id.equals(serverId, ignoreCase = true) }?.iconURL

    /** Steps where the loop is parked waiting for re-authorization (all conversations). Compose state: only the step blocks reading it recompose. */
    private var authPauses: List<PendingMcpAuthPause> by mutableStateOf(emptyList())

    private var stepLimitReachedMessageIds: Set<String> by mutableStateOf(emptySet())

    /**
     * Subscribes to the loop's transient state: steps parked waiting for re-authorization, messages that hit the step limit. Called once
     * from the VM's init: whoever owns the scope starts it.
     */
    fun observeLoopState() {
        val runner = runner ?: return
        scope.launch { runner.authPauses.pending.collect { authPauses = it } }
        scope.launch { runner.stepLimitReachedMessageIds.collect { stepLimitReachedMessageIds = it } }
    }

    /** Ids of the steps in the current conversation that are parked waiting for re-authorization. */
    fun pausedStepIds(): Set<String> {
        val conversationId = currentConversationId() ?: return emptySet()
        return authPauses
            .filter { it.request.conversationId.equals(conversationId, ignoreCase = true) }
            .mapTo(mutableSetOf()) { it.request.stepId }
    }

    /** Whether this message's tool loop hit the step limit. */
    fun isStepLimitReached(messageId: String): Boolean = messageId.lowercase() in stepLimitReachedMessageIds

    /**
     * Re-authorizes a server ("Re-authorize" in the step block and the tool panel). On success, the steps of the current conversation
     * parked on that server resume where they stopped; otherwise (cancelled, failed, entry point not wired up) nothing changes and the user can retry or skip.
     */
    fun reauthorize(serverId: String) {
        val runner = runner ?: return
        scope.launch {
            val succeeded = runCatching { runner.reauthorizer.reauthorize(serverId) }.getOrDefault(false)
            if (!succeeded) return@launch
            val conversationId = currentConversationId()
            authPauses
                .filter {
                    it.request.serverId.equals(serverId, ignoreCase = true) &&
                        it.request.conversationId.equals(conversationId, ignoreCase = true)
                }
                .forEach { runner.authPauses.resolve(it.id, McpAuthPauseDecision.Resume) }
            panelState = runner.loadPanel(panelConversationId(), availability())
        }
    }

    /** Skips the parked step: it is recorded as skipped and the answer carries on. */
    fun skipStep(stepId: String) {
        val runner = runner ?: return
        val conversationId = currentConversationId()
        authPauses
            .filter { it.request.stepId == stepId && it.request.conversationId.equals(conversationId, ignoreCase = true) }
            .forEach { runner.authPauses.resolve(it.id, McpAuthPauseDecision.Skip) }
    }

    private fun panelConversationId(): String = currentConversationId() ?: draftConversationId

    private suspend fun availability(): McpToolAvailability {
        val provider = activeProvider()
        val model = activeModel()
        if (provider == null || model == null) return McpToolAvailability.Available
        return runner?.availability(
            provider = provider,
            model = model,
            memoryVerdict = toolCallMemoryVerdict(provider, model),
            localIdentity = capabilityEvidenceIdentity(provider, model.id),
        ) ?: McpToolAvailability.Available
    }

    /** Reloads the panel data. Called when the conversation / connection / model changes, when the panel opens, and on return from the management screen. */
    fun refresh() {
        val runner = runner ?: return
        refreshJob?.cancel()
        refreshJob = scope.launch {
            // Let in-flight toggle writes land before reading, otherwise the panel flashes back to the pre-write state.
            runner.awaitSwitchWrites()
            panelState = runner.loadPanel(panelConversationId(), availability())
        }
    }

    fun openToolPanel() {
        showToolPanel = true
        refresh()
    }

    fun dismissToolPanel() {
        showToolPanel = false
    }

    /**
     * Flips a server's toggle for this conversation: update the UI first, then persist, then reload from storage as the source of truth (tool count and token estimate follow).
     *
     * The write goes to the runner's app-level queue, **not into the cancellable [refreshJob]**: another flip right after, a [refresh], or leaving
     * the chat screen only cancel the panel reload, never the write. The send path waits for in-flight writes before reading the toggles (`McpChatToolRunner.plan`).
     */
    fun setServerEnabled(serverId: String, enabled: Boolean) {
        val runner = runner ?: return
        panelState = panelState.copy(
            rows = panelState.rows.map { if (it.id.equals(serverId, ignoreCase = true)) it.copy(isEnabled = enabled) else it },
        )
        val conversationId = panelConversationId()
        val write = runner.enqueueServerEnabled(enabled, conversationId, serverId)
        refreshJob?.cancel()
        refreshJob = scope.launch {
            write.join()
            panelState = runner.loadPanel(conversationId, availability())
        }
    }

    /** First message of a new conversation: the draft's toggles move under the real conversation id. Suspending because it must finish before sending reads the toggles. */
    suspend fun adoptDraft(conversationId: String) {
        runner?.adoptDraftSwitches(draftConversationId, conversationId)
    }

    /** Starts another new conversation: toggles from the previous unsent draft are not carried over (a new conversation starts with everything off). */
    fun resetDraft() {
        val runner = runner ?: return
        scope.launch {
            runner.discardDraftSwitches(draftConversationId)
            panelState = runner.loadPanel(panelConversationId(), availability())
        }
    }

    // ── Confirmation sheet (hosted at the navigation root, see `McpConfirmationHost`; only the wrap-up on "stop" lives here) ──

    /** The user hit stop: confirmations still waiting are resolved as cancelled (the step is recorded as interrupted). */
    fun cancelPending(conversationId: String) {
        confirmationCoordinator?.cancelConversation(conversationId)
        runner?.authPauses?.cancelConversation(conversationId)
    }

    // ── Step detail ──

    fun openStepDetail(messageId: String, step: McpToolStep) {
        stepDetail = McpStepDetailState(messageId = messageId, step = step, payload = null, loading = true)
        val runner = runner
        scope.launch {
            val payload = runner?.fetchStepPayload(messageId, step.id)
            // The user may have closed the sheet or switched steps while storage was being read: only fill in the one still shown.
            val current = stepDetail
            if (current != null && current.messageId == messageId && current.step.id == step.id) {
                stepDetail = current.copy(payload = payload, loading = false)
            }
        }
    }

    fun dismissStepDetail() {
        stepDetail = null
    }
}
