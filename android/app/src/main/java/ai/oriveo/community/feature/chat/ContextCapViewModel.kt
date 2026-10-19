package ai.oriveo.community.feature.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.context.ContextWindowInput
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.ChatContextProjector
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationParameterProfileFingerprint
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.provider.GenerationParameterLifecycleRules
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** Inputs of the panel cap rows for one conversation (contract P9·U7 rule 3). */
data class ContextCapInputs(
    /** Window of the chat send: provider, model, user max output, price line T. */
    val window: ContextWindowInput,
    /** null = follows the global default. */
    val conversationCap: ContextBudgetCap?,
    val globalCap: ContextBudgetCap,
    /** Base and long-context prices; null without a price line or catalog prices. */
    val pricing: ContextCapPricing?,
    /** Model display name for the picker head line. */
    val modelName: String = "",
) {
    /** The cap in effect: the conversation's own, otherwise the global default. */
    val effectiveCap: ContextBudgetCap get() = conversationCap ?: globalCap

    /** Usable input U of the model (cap independent); null for an unknown window. */
    val usable: Int? get() = ContextBudget.window(window).U

    /** Picker state (contract P9·U7 rule 1). */
    fun picker(): ContextCapPicker = ContextCapPresentation.picker(window, conversationCap, globalCap)

    /** [used] unknown: no distance to the price line (the ring caption falls back to measured / estimated). */
    fun panel(used: Int?): ContextCapPanel = ContextCapPresentation.panel(
        window = window,
        conversationCap = conversationCap,
        globalCap = globalCap,
        used = used ?: 0,
        pricing = pricing,
    ).let { if (used == null) it.copy(priceLineDistance = null) else it }
}

/**
 * Per-conversation cap inputs for the context panel: the conversation's cap, the global default and the
 * same window the chat send builds. Drafts and conversations without a known provider have no cap rows.
 * The picker writes through [updateCap] (null = follow the global default) and reads the result back from
 * [conversation].
 */
class ContextCapViewModel(
    conversation: Flow<Conversation?>,
    defaultCap: Flow<ContextBudgetCap>,
    providers: Flow<List<Provider>>,
    private val requestOptions: (Conversation, Provider) -> ChatRequestOptions,
    private val updateCap: suspend (ContextBudgetCap?) -> Unit = {},
) : ViewModel() {

    val inputs: StateFlow<ContextCapInputs?> = combine(conversation, defaultCap, providers) { c, global, list ->
        assemble(c, global, list)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    /** Option rows write right away; null = follow the global default. */
    fun select(cap: ContextBudgetCap?) {
        if (inputs.value == null) return
        viewModelScope.launch { updateCap(cap) }
    }

    /** Choosing Custom stores the picker's custom start right away. */
    fun selectCustom() {
        val current = inputs.value ?: return
        select(ContextBudgetCap.Custom(current.picker().customStart))
    }

    /**
     * Slider released on tick [index] after being pressed on [pressedIndex]. A tap that leaves the index
     * unchanged writes nothing, so a stored value between ticks is not snapped to the nearest one.
     */
    fun releaseSlider(pressedIndex: Int, index: Int) {
        if (index == pressedIndex) return
        val ticks = inputs.value?.picker()?.ticks ?: return
        ticks.getOrNull(index)?.let { select(ContextBudgetCap.Custom(it)) }
    }

    /**
     * Commits the typed custom number against the model's U; unreadable text restores the previous value
     * (the stored custom count, otherwise the custom start) and writes nothing. null without cap inputs.
     */
    fun commitCustom(text: String): ContextCapCommit? {
        val current = inputs.value ?: return null
        val stored = current.conversationCap as? ContextBudgetCap.Custom
        val previous = stored?.tokens ?: current.picker().customStart
        val result = ContextCapPresentation.commit(text, u = current.usable, previous = previous)
        if (!result.restored) select(ContextBudgetCap.Custom(result.value))
        return result
    }

    private fun assemble(
        conversation: Conversation?,
        globalCap: ContextBudgetCap,
        providers: List<Provider>,
    ): ContextCapInputs? {
        if (conversation == null || conversation.isDraft) return null
        val provider = providers.firstOrNull { it.id == conversation.providerID } ?: return null
        val options = requestOptions(conversation, provider)
        val model = options.activeModel ?: ProviderSelectionSnapshot.selectedModel(provider, conversation.modelID)
        val window = ChatContextProjector.window(provider, model, options, conversation.contextCap ?: globalCap)
        return ContextCapInputs(
            window = window,
            conversationCap = conversation.contextCap,
            globalCap = globalCap,
            pricing = pricing(provider.kind, model?.id),
            modelName = model?.name?.takeIf { it.isNotBlank() } ?: conversation.modelID,
        )
    }

    companion object {
        private const val PER_MILLION = 1_000_000.0

        /**
         * The panel view model of [conversationId] as the DI graph binds it: the conversation's metadata flow,
         * the global default cap, the providers, the send's request options, and the picker writing through
         * [ConversationRepository.updateContextCap].
         */
        fun forConversation(
            conversationId: String,
            conversations: ConversationRepository,
            preferences: AppPreferencesRepository,
            providers: ProviderRepository,
            generationParameters: GenerationParameterSettingsStore,
        ): ContextCapViewModel = ContextCapViewModel(
            conversation = conversations.observeMetadata(conversationId),
            defaultCap = preferences.contextDefaultCap,
            providers = providers.observeAll(),
            requestOptions = { conversation, provider -> sendRequestOptions(generationParameters, conversation, provider) },
            updateCap = { cap -> conversations.updateContextCap(conversationId, cap) },
        )

        /**
         * Request options as the chat send resolves them, shared by the panel window and the manual compaction
         * (ChatSendCoordinator.manualCompactionRequestOptions): the conversation's resolved generation parameters
         * (user max output) and the selected model. Values the final dispatch would not send (dormant under the
         * current profile) are filtered with the same activeParameterIds as the send; no profile = no filter.
         */
        fun sendRequestOptions(
            store: GenerationParameterSettingsStore,
            conversation: Conversation,
            provider: Provider,
        ): ChatRequestOptions {
            val selectedModel = ProviderSelectionSnapshot.selectedModel(provider, conversation.modelID)
            val profile = selectedModel?.let { GenerationParameterAvailability.profile(provider, it) }
            return ChatRequestOptions(
                generationParameters = store.resolve(
                    transient = null,
                    providerID = provider.id,
                    modelID = conversation.modelID,
                    conversationID = conversation.id,
                    profileFingerprint = selectedModel?.let { GenerationParameterProfileFingerprint.make(provider, it) },
                    activeParameterIds = profile?.let { GenerationParameterLifecycleRules.declaredParameterIdsForFinalDispatch(it) },
                ),
                activeModel = selectedModel,
            )
        }

        /**
         * Whether the send would resolve a model for [conversation] on [provider]; when it does not, the usage
         * ring keeps the ledger's B instead of reporting an unknown window (usage.v1 currentB key absent).
         */
        fun resolvesModel(store: GenerationParameterSettingsStore, conversation: Conversation, provider: Provider): Boolean =
            sendRequestOptions(store, conversation, provider).activeModel != null ||
                ProviderSelectionSnapshot.selectedModel(provider, conversation.modelID) != null

        /**
         * Limit B of [conversation] under its cap (otherwise [globalCap]) and the window the chat send builds;
         * the window is the server-provided one only, so an unknown window gives null instead of a guess,
         * unless a custom cap applies (then B is that cap).
         */
        fun currentB(
            store: GenerationParameterSettingsStore,
            conversation: Conversation,
            provider: Provider,
            globalCap: ContextBudgetCap,
        ): Int? {
            val options = sendRequestOptions(store, conversation, provider)
            val model = options.activeModel ?: ProviderSelectionSnapshot.selectedModel(provider, conversation.modelID)
            val budget = ContextBudget.window(
                ChatContextProjector.window(provider, model, options, conversation.contextCap ?: globalCap),
            )
            return budget.B
        }

        /**
         * Catalog base and long-context prices per million tokens; only where the window uses a price line.
         * Internal so the debug context shots reuse the same assembly.
         */
        internal fun pricing(kind: ProviderKind, modelId: String?): ContextCapPricing? {
            if (modelId == null || ChatContextProjector.priceLineTokens(kind, modelId) == null) return null
            val resolved = MetadataClient.resolveCatalogModel(modelId, kind) ?: return null
            val long = resolved.longContext ?: return null
            return ContextCapPricing(
                basePrompt = resolved.promptPerToken?.let { it * PER_MILLION },
                baseCompletion = resolved.completionPerToken?.let { it * PER_MILLION },
                longPrompt = long.promptPerMToken,
                longCompletion = long.completionPerMToken,
            )
        }
    }
}
