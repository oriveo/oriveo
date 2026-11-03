package ai.oriveo.community.feature.chat.composer

import androidx.annotation.StringRes
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.text.BasicTextField
import ai.oriveo.community.ui.util.userContentTextStyle
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.SoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterProfileFingerprint
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.displayedForUi
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.feature.chat.ChatModelCapabilityResolver
import ai.oriveo.community.feature.chat.RestoredImageState
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.core.provider.CapabilityControlPresentationResolver
import ai.oriveo.community.core.provider.CapabilityWebPreferenceLiveness
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.provider.GenerationParameterLifecycleRules
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.core.provider.ModelControlRejectionCache
import ai.oriveo.community.feature.chat.ChatCapabilityOutboundDecision
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.feature.chat.components.QuoteContextChip
import ai.oriveo.community.feature.chat.components.QuoteContextChipPresentation
import ai.oriveo.community.feature.chat.attachments.AttachmentImportPolicy
import ai.oriveo.community.core.util.ExternalActivityLaunchOutcome
import ai.oriveo.community.core.util.launchExternalActivitySafely
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.component.ComposerSelectionProbe
import ai.oriveo.community.ui.component.rememberComposerLengthLimitedField
import ai.oriveo.community.ui.theme.OriveoTheme
import dev.chrisbanes.haze.ExperimentalHazeApi
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.materials.ExperimentalHazeMaterialsApi
import kotlinx.coroutines.flow.StateFlow
import org.koin.compose.koinInject

@OptIn(
    ExperimentalMaterial3Api::class,
    ExperimentalFoundationApi::class,
    ExperimentalLayoutApi::class,
    ExperimentalHazeApi::class,
    ExperimentalHazeMaterialsApi::class,
)
@Composable
internal fun EnhancedComposer(
    /**
     * Reads the composer text **lazily**: only the composable that calls it subscribes to text
     * changes.
     *
     * Deliberately not `inputText: String` -- a changing parameter makes this function non
     * skippable, so its thousand-plus line body (capability resolution, attachment counting, a pile
     * of `stringResource` lookups) would run on every keystroke. [ComposerTextField] is now the
     * only caller, which confines per-keystroke recomposition to that one composable.
     */
    inputTextProvider: () -> String,
    /**
     * Whether the text is non-blank. The body only needs this boolean (send button enablement,
     * draft highlight); the caller derives it with `derivedStateOf`, so it flips only when the text
     * crosses between empty and non-empty.
     */
    hasComposerText: Boolean,
    onInputChange: (String) -> Unit,
    pendingAttachments: List<Attachment>,
    /** Images restored from an edit that are still downloading or failed to download (by attachment id). */
    restoredImageStates: Map<String, RestoredImageState> = emptyMap(),
    pendingQuoteContext: QuoteContext?,
    onRemoveQuote: () -> Unit,
    onAttachmentRemove: (String) -> Unit,
    currentModel: AIModel?,
    generationParameterProvider: Provider?,
    generationParameterConversationId: String,
    isExistingConversation: Boolean,
    /**
     * Skill ids of the shown conversation (skill_sync_fields.v1). The first one is the legacy skillId that
     * the skill_agent capability scope resolves against (`ChatSendCoordinator.launchSend`); hard-coding null
     * would hide that scope's web / reasoning preference while the request still sends it.
     */
    skillIds: List<String>,
    /** Exact transport that the selected official model will use; null intentionally fails closed. */
    modelControlsFinalTransport: String?,
    /** Attachment menu model: media items that cannot be used are visibly disabled with a reason. */
    attachmentEntry: ComposerAttachmentEntryModel,
    onSelectReasoningMode: (ReasoningMode) -> Unit,
    /** The next send's outbound history contains video (ChatViewModel.outboundHistoryHasVideo); the file card of the model panel uses it to predict the route. */
    outboundHistoryHasVideo: Boolean = false,

    onSelectModel: (providerId: String, modelId: String) -> Unit,
    onOpenModelSwitcher: () -> Unit,
    /** The "Tools" chip of remote MCP. Visible while the `mcpRuntimeConfig.enabled` master switch is on. */
    mcpEntryVisible: Boolean = false,
    /** Whether this connection and model can use MCP tools; when not, the chip is dimmed and opens a panel explaining why. */
    mcpToolsAvailable: Boolean = true,
    /** Servers switched on and usable in this conversation; at 0 there is no number and no highlight. */
    mcpEnabledServerCount: Int = 0,
    onOpenMcpTools: () -> Unit = {},
    showAttachmentSizeLimitDialog: Boolean,
    onDismissAttachmentSizeLimitDialog: () -> Unit,
    onProcessImageUri: (android.net.Uri) -> Unit,
    onProcessFileUri: (android.net.Uri) -> Unit,
    onSendClick: () -> Unit,
    onStopGeneration: () -> Unit,
    /** Composer gained focus (starts background pre-compaction). */
    onComposerFocused: () -> Unit = {},
    providerKind: ProviderKind?,
    onNavigateToProviderSetup: () -> Unit,

    onNavigateToProviderDetail: (providerId: String) -> Unit = {},
    onNavigateToWebSearchFromChat: (conversationId: String?, oneTap: ai.oriveo.community.core.search.OneTapReuseTarget?) -> Unit = { _, _ -> },
    /** Relay web search settings page (Detail > Web search). */
    onNavigateToConnectionWebSearch: (providerId: String) -> Unit = {},
    /** "Test capability" for a rejected web template: opens this model's advanced page in this connection. */
    onNavigateToRelayModelAdvanced: (providerId: String, modelId: String) -> Unit = { _, _ -> },
    onNavigateToSkillEdit: () -> Unit = {},
    isGenerating: Boolean,
    isReadOnly: Boolean,
    /** Blocks sending only; the input stays editable (the relay conversation's model was removed). */
    isSendBlocked: Boolean = false,
    /** The selected model answers in text, so an empty draft offers the waveform key instead of a grey up arrow. */
    voiceConversationAvailable: Boolean = false,
    onStartVoiceConversation: () -> Unit = {},
    /** Realtime voice model in typing mode: the ≋ slot returns to the voice stage instead. */
    voiceBackToStage: Boolean = false,
    onBackToVoiceStage: () -> Unit = {},
    /** Voice catalog not ready and the session model may be realtime: the main key shows a spinner. */
    isAwaitingVoiceCatalog: Boolean = false,
    hazeState: HazeState,
    trueTransparentBlurEnabled: Boolean,

    attachedNotes: List<ai.oriveo.community.core.model.Note> = emptyList(),
    relatedNotes: List<ai.oriveo.community.core.model.Note> = emptyList(),
    onAttachNote: (ai.oriveo.community.core.model.Note) -> Unit = {},
    onDismissRelatedNote: (ai.oriveo.community.core.model.Note) -> Unit = {},
    onDetachNote: (ai.oriveo.community.core.model.Note) -> Unit = {},
    onPreviewNote: (ai.oriveo.community.core.model.Note) -> Unit = {},
    /** Usage summary of the shown conversation; the ring shows only for percent display. */
    contextUsage: ai.oriveo.community.feature.chat.ContextUsageSummary? = null,
    onOpenContextUsage: () -> Unit = {},
    /** Dictation handle from rememberDictationHost; null hides the mic and keeps the normal input row. */
    dictation: DictationHostCoordinator? = null,
    /** Selection probe of the composer field, so dictated text lands at the caret. */
    selectionProbe: ComposerSelectionProbe? = null,
    /** Availability of the recording bar's send action; null falls back to the send button's own gate. */
    canSendDictation: (() -> Boolean)? = null,
) {
    val conversationSkillId = skillIds.firstOrNull()
    val keyboardController = LocalSoftwareKeyboardController.current
    val composerFocusRequester = remember { FocusRequester() }
    // The quote focus effect lives in its own small function: the composer has more than 256 dex registers,
    // and the D8 bundled with AGP 9.4.1 (9.4.24) compiles the null check on pendingQuoteContext?.x into the
    // wrong register, so getSourceMessageId throws an NPE with no quote and the chat page crashes on open.
    ComposerQuoteFocusEffect(
        quote = pendingQuoteContext,
        enabled = !isReadOnly && !isGenerating,
        focusRequester = composerFocusRequester,
        keyboardController = keyboardController,
    )
    val controlsEnabled = !isGenerating && !isReadOnly
    val context = LocalContext.current
    val generationSettingsStore = remember(context) { GenerationParameterSettingsStore.from(context) }
    val capabilityPreferenceStore = remember(context) { CapabilityPreferenceStore.from(context) }
    val localCustomFragmentStore = remember(context) { LocalCapabilityCustomFragmentStore.from(context) }
    val metadataRevision = MetadataClient.instance.currentMetadataRevision()
    val modelControlRuntimeIdentity = generationParameterProvider?.let { provider ->
        currentModel?.let { model -> ModelControlRuntimeIdentityResolver.resolve(provider, model) }
    }
    // The fixed identity of the relay web switch: it does not change with the protocol or metadata version; the thinking tier still uses the protocol-bearing identity above.
    val relayWebIdentity = generationParameterProvider?.let { provider ->
        currentModel?.let { model -> ai.oriveo.community.core.provider.RelayWebPreferenceIdentity.resolve(provider, model) }
    }
    val providerRepository = koinInject<ProviderRepository>()
    val generationCapabilityPartition = providerRepository.currentCapabilityPartitionId()
    val capabilityObservationRevision by CapabilityEvidenceObservationBridge.revision.collectAsState()
    val runtimeModelControls = remember(
        generationParameterProvider,
        currentModel,
        modelControlsFinalTransport,
        metadataRevision,
        capabilityObservationRevision,
    ) {
        ChatModelCapabilityResolver().modelControls(
            generationParameterProvider,
            currentModel,
            modelControlsFinalTransport,
        )
    }
    val generationCapabilityScopeKey = generationParameterProvider?.let { provider ->
        currentModel?.let { model ->
            CapabilityEvidenceObservationBridge.uiIdentityScopeKey(
                provider = provider,
                model = model,
                partitionId = generationCapabilityPartition,
                revision = capabilityObservationRevision,
            )
        }
    }
    val latestGenerationCapabilityPartition by rememberUpdatedState(generationCapabilityPartition)
    val latestGenerationCapabilityScopeKey by rememberUpdatedState(generationCapabilityScopeKey)
    var generationLocalCapabilityIdentity by remember(
        generationCapabilityPartition,
        generationCapabilityScopeKey,
        currentModel,
    ) { mutableStateOf<ai.oriveo.community.core.model.CapabilityEvidenceIdentity?>(null) }
    LaunchedEffect(
        generationCapabilityPartition,
        generationCapabilityScopeKey,
        currentModel,
    ) {
        generationLocalCapabilityIdentity = null
        val provider = generationParameterProvider
        val model = currentModel
        val capturedPartition = generationCapabilityPartition
        val capturedScopeKey = generationCapabilityScopeKey
        if (provider?.kind == ProviderKind.Relay && model != null) {
            val identity = providerRepository.capabilityEvidenceIdentity(
                provider = provider,
                modelId = model.id,
                partitionId = capturedPartition,
            )
            if (
                latestGenerationCapabilityPartition == capturedPartition &&
                latestGenerationCapabilityScopeKey == capturedScopeKey
            ) {
                generationLocalCapabilityIdentity = identity
            }
        }
    }
    var showModelControls by remember { mutableStateOf(false) }
    /** This opening of model options lands directly on the "Search method" page (the external search error card's "Switch service"). */
    var modelControlsOpensSearchMethod by remember { mutableStateOf(false) }
    LaunchedEffect(generationParameterConversationId) {
        ai.oriveo.community.feature.chat.modelcontrols.WebSearchMethodOpenRequests.requests.collect { conversationId ->
            if (conversationId == generationParameterConversationId) {
                modelControlsOpensSearchMethod = true
                showModelControls = true
            }
        }
    }

    var modelBehaviorRevision by remember { mutableIntStateOf(0) }
    // The provider id is read once through a small function: the composer has over 300 dex registers, and
    // a `?.id` written inline gets compiled by D8 9.4.24 to test one register and call another.
    val generationParameterProviderId = composerProviderId(generationParameterProvider)
    var selectedControlWeb by remember(generationParameterProviderId, currentModel?.id, generationParameterConversationId) {
        mutableStateOf(CapabilityWebPreference.Off)
    }
    var selectedControlReasoning by remember(generationParameterProviderId, currentModel?.id, generationParameterConversationId) {
        mutableStateOf<String?>(null)
    }
    /**
     * "These owners are now in Custom mode." The criterion must come from the same source as the outbound side:
     * the request sends every owner in [LocalCapabilityCustomFragmentStore.fragmentsByOwner], so if the UI shows
     * even one owner fewer, the user sees custom as off while the request still carries it.
     */
    var developerCustomOwners by remember(generationParameterProviderId, currentModel?.id, generationParameterConversationId) {
        mutableStateOf<Set<String>>(emptySet())
    }

    fun restoredCapabilityPreferences(): CapabilityPreferenceValues {
        val provider = generationParameterProvider ?: return CapabilityPreferenceValues()
        currentModel ?: return CapabilityPreferenceValues()
        val relayWebDefault = currentModel?.let { ai.oriveo.community.core.provider.relay.RelayWebChat.of(provider, it)?.defaultPreference }
        // The relay web switch reads the fixed identity.
        val relayWeb = relayWebIdentity?.let { webIdentity ->
            capabilityPreferenceStore.displayedForUi(
                providerID = provider.id,
                providerKind = provider.kind,
                modelID = webIdentity.canonicalModelId,
                conversationID = generationParameterConversationId,
                skillID = conversationSkillId,
                transportIdentity = webIdentity.storageIdentity,
                isExistingConversation = isExistingConversation,
                webDefault = relayWebDefault,
            ).web
        }
        val identity = modelControlRuntimeIdentity
            ?: return CapabilityPreferenceValues(web = relayWeb ?: CapabilityWebPreference.Off)
        return capabilityPreferenceStore.displayedForUi(
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = identity.canonicalModelId,
            conversationID = generationParameterConversationId,
            skillID = conversationSkillId,
            transportIdentity = identity.storageIdentity,
            isExistingConversation = isExistingConversation,
            legacyModelID = identity.legacyModelId,
            // Default layer when relay web search is unset: the first-send protocol has a stored fragment -> on.
            webDefault = relayWebDefault,
        ).let { values -> relayWeb?.let { values.copy(web = it) } ?: values }
    }

    fun restoredCustomOwners(): Set<String> {
        val provider = generationParameterProvider ?: return emptySet()
        val model = currentModel ?: return emptySet()
        val identity = modelControlRuntimeIdentity ?: return emptySet()

        return localCustomFragmentStore.fragmentsByOwner(
            providerID = provider.id,
            modelID = identity.canonicalModelId,
            conversationID = generationParameterConversationId,
            transportIdentity = identity.storageIdentity,
            forwardPort = LocalCapabilityCustomFragmentStore.ForwardPortContext(
                providerKind = provider.kind,
                schemaModelID = model.id,
                activeProfile = GenerationParameterAvailability.profile(provider, model),
            ),
            legacyModelID = identity.legacyModelId,
        ).keys
    }

    fun persistCapabilityPreferences(values: CapabilityPreferenceValues) {
        val provider = generationParameterProvider ?: return
        currentModel ?: return
        // The relay web switch is stored under a separate fixed identity; the protocol-bearing one still stores the thinking tier.
        relayWebIdentity?.let { webIdentity ->
            val web = CapabilityPreferenceValues(web = values.web)
            if (isExistingConversation) {
                capabilityPreferenceStore.setConversation(
                    web, provider.id, webIdentity.canonicalModelId, generationParameterConversationId, webIdentity.storageIdentity,
                )
            } else {
                capabilityPreferenceStore.setDraftConversation(
                    web, provider.id, webIdentity.canonicalModelId, generationParameterConversationId, webIdentity.storageIdentity,
                )
            }
        }
        val identity = modelControlRuntimeIdentity ?: return
        if (isExistingConversation) {
            capabilityPreferenceStore.setConversation(
                values,
                provider.id,
                identity.canonicalModelId,
                generationParameterConversationId,
                identity.storageIdentity,
            )
        } else {
            capabilityPreferenceStore.setDraftConversation(
                values,
                provider.id,
                identity.canonicalModelId,
                generationParameterConversationId,
                identity.storageIdentity,
            )
        }
    }

    fun promoteCapabilityPreferencesToModelDefault(values: CapabilityPreferenceValues) {
        val provider = generationParameterProvider ?: return
        currentModel ?: return
        val identity = modelControlRuntimeIdentity ?: return
        // The relay web switch is stored separately under the fixed identity.
        relayWebIdentity?.let { webIdentity ->
            capabilityPreferenceStore.setConnectionModel(
                CapabilityPreferenceValues(web = values.web), provider.id, webIdentity.canonicalModelId, webIdentity.storageIdentity,
            )
        }
        capabilityPreferenceStore.setConnectionModel(
            values,
            provider.id,
            identity.canonicalModelId,
            identity.storageIdentity,
        )
    }

    val modelControlReadOnlyReasonRes = when {

        isGenerating -> R.string.ai_is_answering
        isReadOnly -> R.string.chat_read_only_placeholder
        else -> null
    }

    val webPresentation = remember(
        generationParameterProvider,
        currentModel,
        modelControlsFinalTransport,
        metadataRevision,
        capabilityObservationRevision,
    ) {
        val provider = generationParameterProvider
        val model = currentModel
        if (provider == null || model == null) {
            CapabilityControlPresentation.Unknown
        } else {
            CapabilityControlPresentationResolver.presentation(
                provider, model, "web", MetadataClient.instance, modelControlsFinalTransport,
            )
        }
    }

    LaunchedEffect(
        generationParameterProviderId,
        currentModel?.id,
        generationParameterConversationId,
        isExistingConversation,
        conversationSkillId,
        metadataRevision,

        capabilityObservationRevision,
        modelControlsFinalTransport,
    ) {

        developerCustomOwners = restoredCustomOwners()

        val restored = restoredCapabilityPreferences()
        selectedControlWeb = restored.web
        selectedControlReasoning = restored.reasoningIntent
    }

    LaunchedEffect(
        showModelControls,
        generationParameterProvider,
        currentModel,
        generationParameterConversationId,
        metadataRevision,
        modelBehaviorRevision,
        capabilityObservationRevision,
        modelControlsFinalTransport,
    ) {
        if (!showModelControls) return@LaunchedEffect
        val provider = generationParameterProvider ?: return@LaunchedEffect
        currentModel ?: return@LaunchedEffect
        modelControlRuntimeIdentity ?: return@LaunchedEffect

        developerCustomOwners = restoredCustomOwners()
        val values = restoredCapabilityPreferences()
        selectedControlWeb = values.web
        selectedControlReasoning = values.reasoningIntent
    }
    var composerGenerationOverrides by remember(
        generationParameterProviderId,
        currentModel?.id,
        generationParameterConversationId,
    ) { mutableStateOf(GenerationParameterOverrides()) }
    LaunchedEffect(
        generationParameterProvider,
        currentModel,
        generationParameterConversationId,
        modelBehaviorRevision,
    ) {

        composerGenerationOverrides = if (generationParameterProvider != null && currentModel != null) {
            val fingerprint = GenerationParameterProfileFingerprint.make(generationParameterProvider, currentModel)
            val modelDefaults = generationSettingsStore.modelDefaults(
                generationParameterProvider.id, currentModel.id, fingerprint,
            )?.values.orEmpty()
            val session = generationSettingsStore.sessionOverrides(
                generationParameterProvider.id,
                currentModel.id,
                generationParameterConversationId,
                fingerprint,
            )?.values.orEmpty()
            GenerationParameterOverrides(modelDefaults + session)
        } else {
            GenerationParameterOverrides()
        }
    }
    val composerGenerationProjection = remember(
        generationParameterProvider,
        currentModel,
        generationLocalCapabilityIdentity,
        composerGenerationOverrides,
        capabilityObservationRevision,
    ) {
        if (generationParameterProvider != null && currentModel != null) {
            CapabilityEvidenceProductionAdapter.generationParameterUiProjection(
                provider = generationParameterProvider,
                model = currentModel,
                localIdentity = generationLocalCapabilityIdentity,
                parameters = GenerationParameterAvailability
                    .profile(generationParameterProvider, currentModel)
                    ?.parameters
                    .orEmpty(),
                values = composerGenerationOverrides,
            )
        } else {
            null
        }
    }

    var modelBehaviorOverrideCount by remember(
        generationParameterProviderId,
        currentModel?.id,
        generationParameterConversationId,
    ) { mutableStateOf(0) }
    LaunchedEffect(
        generationParameterProvider,
        currentModel,
        composerGenerationOverrides,
        composerGenerationProjection,
    ) {

        modelBehaviorOverrideCount = if (
            generationParameterProvider != null && currentModel != null && composerGenerationProjection != null
        ) {
                GenerationParameterLifecycleRules.partition(
                    provider = generationParameterProvider,
                    model = currentModel,
                    values = composerGenerationOverrides,
                    capabilityProjection = composerGenerationProjection,
                )
                    .active.values.count { it.value.state != GenerationOverrideState.Inherit }
        } else 0
    }
    val hasModelBehaviorOverride = modelBehaviorOverrideCount > 0
    // When not registered (test hosts with only some dependencies), the web search card keeps its previous behavior.
    val koin = org.koin.compose.getKoin()
    val modelControlsWebSearch = remember(koin) { koin.getOrNull<ai.oriveo.community.feature.chat.modelcontrols.ModelControlsWebSearch>() }
    val webSearchStoreRevision = modelControlsWebSearch?.revision?.collectAsState()?.value
    // Back from the settings page opened by the web search card (one-tap enable / add a search service): return to the
    // model options panel whether the test passed, failed or was cancelled; a newly added service means setup succeeded,
    // so send pick_service (when arms is true). Consumed when the lifecycle resumes, no polling.
    val composerResumed = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle.currentStateFlow
        .collectAsState().value.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)
    val webSearchReturn by ai.oriveo.community.core.search.WebSearchChatReturn.changes.collectAsState()
    LaunchedEffect(composerResumed, webSearchReturn, generationParameterConversationId, generationParameterProviderId, currentModel?.id) {
        if (!composerResumed) return@LaunchedEffect
        val provider = generationParameterProvider ?: return@LaunchedEffect
        val model = currentModel ?: return@LaunchedEffect
        val back = ai.oriveo.community.core.search.WebSearchChatReturn.consume(generationParameterConversationId) ?: return@LaunchedEffect
        val webSearch = modelControlsWebSearch
        val added = back.addedServiceId
        if (webSearch != null && back.arms && added != null) {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                runCatching { webSearch.pickAdded(provider, model, generationParameterConversationId, !isExistingConversation, added) }
            }
        }
        showModelControls = true
    }
    // Composer web search chip preview: the same background read as sending (read-only) + resolveWebSearchState;
    // recomputed when the source, the service list (revision), the model or the conversation changes.
    val webSearchChipSnapshot by androidx.compose.runtime.produceState<ai.oriveo.community.feature.chat.modelcontrols.WebSearchPanelSnapshot?>(
        null, modelControlsWebSearch, generationParameterProviderId, currentModel?.id, generationParameterConversationId,
        showModelControls, webSearchStoreRevision,
    ) {
        val provider = generationParameterProvider
        val model = currentModel
        val webSearch = modelControlsWebSearch
        value = if (provider == null || model == null || webSearch == null) null else {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                runCatching { webSearch.snapshot(provider, model, generationParameterConversationId, !isExistingConversation) }.getOrNull()
            }
        }
    }
    if (showModelControls) {
        ComposerModelControlsSheetHost(
            generationParameterProvider = generationParameterProvider,
            currentModel = currentModel,
            generationParameterConversationId = generationParameterConversationId,
            modelControlsFinalTransport = modelControlsFinalTransport,
            metadataRevision = metadataRevision,
            capabilityObservationRevision = capabilityObservationRevision,
            controlsEnabled = controlsEnabled,
            modelControlReadOnlyReasonRes = modelControlReadOnlyReasonRes,
            selectedControlWeb = selectedControlWeb,
            selectedControlReasoning = selectedControlReasoning,
            developerCustomOwners = developerCustomOwners,
            modelBehaviorOverrideCount = modelBehaviorOverrideCount,
            attachmentEntry = attachmentEntry,
            outboundHistoryHasVideo = outboundHistoryHasVideo,
            // The panel also publishes whether the web preference reaches the wire; the composer
            // recomputes that itself where it matters (the outbound decision below), so the
            // published copy is ignored here.
            onSelectionChange = { web, intent, _ ->
                selectedControlWeb = web
                selectedControlReasoning = intent
                onSelectReasoningMode(ReasoningMode.fromIntent(intent))
            },
            onPersist = ::persistCapabilityPreferences,
            onPromoteToModelDefault = ::promoteCapabilityPreferencesToModelDefault,
            onAdvancedSettingsClosed = { modelBehaviorRevision += 1 },
            onOpenModelSwitcher = onOpenModelSwitcher,
            generationParameterProviderId = generationParameterProviderId,
            onNavigateToProviderDetail = onNavigateToProviderDetail,
            onNavigateToConnectionWebSearch = onNavigateToConnectionWebSearch,
            onNavigateToRelayModelAdvanced = onNavigateToRelayModelAdvanced,
            modelControlsWebSearch = modelControlsWebSearch,
            isExistingConversation = isExistingConversation,
            modelControlsOpensSearchMethod = modelControlsOpensSearchMethod,
            onNavigateToWebSearchFromChat = onNavigateToWebSearchFromChat,
            onNavigateToProviderSetup = onNavigateToProviderSetup,
            onSelectModel = onSelectModel,
            onDismiss = {
                showModelControls = false
                modelControlsOpensSearchMethod = false

                modelBehaviorRevision += 1
            },
        )
    }
    // The button icon / count follow the items shown in the menu (disabled items count too); whether an item is tappable is read from each item's enabled.
    val showsImageEntry = attachmentEntry.image.shown
    val showsVideoEntry = attachmentEntry.video.shown
    val showsFileEntry = attachmentEntry.file.shown
    val supportsAttachmentEntry = attachmentEntry.showsEntry
    val showsModeControls = true
    val imageAttachmentCount = remember(pendingAttachments) {
        pendingAttachments.count { it.kind == AttachmentKind.Image }
    }
    val videoAttachmentCount = remember(pendingAttachments) {
        pendingAttachments.count { it.kind == AttachmentKind.Video }
    }
    val fileAttachmentCount = remember(pendingAttachments) {
        pendingAttachments.count { it.kind == AttachmentKind.File }
    }
    val pendingAttachmentCount = pendingAttachments.size
    val attachmentButtonCount = when {
        showsImageEntry && !showsFileEntry -> imageAttachmentCount
        showsVideoEntry && !showsImageEntry && !showsFileEntry -> videoAttachmentCount
        showsFileEntry && !showsImageEntry -> fileAttachmentCount
        else -> pendingAttachmentCount
    }
    val supportedAttachmentKinds = listOf(
        showsImageEntry,
        showsVideoEntry,
        showsFileEntry,
    ).count { it }
    val attachmentButtonIcon = when {
        supportedAttachmentKinds != 1 -> Icons.Filled.Add
        showsImageEntry -> Icons.Outlined.Image
        showsVideoEntry -> Icons.Outlined.Videocam
        showsFileEntry -> Icons.Outlined.Description
        else -> Icons.Filled.Add
    }
    val hasComposerContent = hasComposerText || pendingAttachments.isNotEmpty()
    val dormantCapabilityOwners = modelControlRuntimeIdentity?.let { identity ->
        setOf("web", "reasoning").filterTo(linkedSetOf()) { owner ->
            ModelControlRejectionCache.isRejectedByAnySource(
                identity,
                owner,
                selectedTier = selectedControlReasoning.takeIf { owner == "reasoning" },
            )
        }
    }.orEmpty()
    // Same combined entry point as sending and the panel
    val webSearchChipState = webSearchChipSnapshot?.let { snap ->
        val provider = generationParameterProvider ?: return@let null
        val model = currentModel ?: return@let null
        val relayFact = ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput.relayWeb(provider, model, webPreference = selectedControlWeb)
        ai.oriveo.community.core.search.resolveWebSearchState(
            snap.stateInput(
                facts = ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput.webSearchFacts(
                    provider, model, webPresentation, "web" in dormantCapabilityOwners, relayFact, snap.toolCall,
                ),
                panelWritable = modelControlRuntimeIdentity != null,
                webOn = ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput.webSearchOn(selectedControlWeb, relayFact),
                modelKey = ai.oriveo.community.feature.chat.modelcontrols.webSearchModelKey(provider, model),
            ),
        )
    }
    val outboundCapabilityDecision = ChatCapabilityOutboundDecision.resolve(
        requested = CapabilityPreferenceValues(selectedControlWeb, selectedControlReasoning),
        controls = runtimeModelControls,
        dormantOwners = dormantCapabilityOwners,
        customOwners = developerCustomOwners,

        webReachesTheWire = CapabilityWebPreferenceLiveness.reachesTheWire(
            webPresentation,
            "web" in developerCustomOwners,
        ),
    )
    val hasReasoningHighlight = outboundCapabilityDecision.hasReasoningSelection
    // The chip highlight only reads chipLit; when null (previous shape) fall back to the previous liveness
    val hasWebHighlight = webSearchChipState?.chipLit ?: outboundCapabilityDecision.hasWebSelection
    val activeCapabilityIcons = buildList {
        if (hasWebHighlight) add(Icons.Outlined.Language)
        if (hasReasoningHighlight) add(Icons.Outlined.Psychology)
    }
    val modelControlAccessibilityState = buildList {
        if (hasWebHighlight) add(stringResource(R.string.capability_web))
        if (hasReasoningHighlight) add(stringResource(R.string.capability_reasoning))
        if (hasModelBehaviorOverride) add(stringResource(R.string.generation_parameters_section))
    }.joinToString(" · ").takeIf { it.isNotEmpty() }
    val hasModeHighlights = hasReasoningHighlight || hasWebHighlight
    val hasDraftHighlight = hasComposerContent && !isGenerating
    val attachmentAccent = composerAttachmentAccent()

    val attachmentUploadBlocked = false
    val modeHighlightAccent = when {
        hasReasoningHighlight -> composerAccent(ModelCapability.Reasoning)
        hasWebHighlight -> composerAccent(ModelCapability.Web)
        else -> attachmentAccent
    }
    var showAttachmentPicker by remember { mutableStateOf(false) }
    var showAttachmentPickerUnavailableDialog by remember { mutableStateOf(false) }
    var composerFocused by remember { mutableStateOf(false) }

    val imagePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(maxItems = 10),
    ) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        uris.forEach(onProcessImageUri)
    }

    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        uris.forEach(onProcessFileUri)
    }

    val composerContext = LocalContext.current
    var pendingCameraUri by remember { mutableStateOf<android.net.Uri?>(null) }
    val cameraLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.TakePicture(),
    ) { success ->
        val uri = pendingCameraUri
        pendingCameraUri = null
        if (success && uri != null) {
            onProcessImageUri(uri)
        }
    }
    val deviceHasCamera = remember(composerContext) {
        composerContext.packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_CAMERA_ANY)
    }
    val launchExternalActivity = { launch: () -> Unit ->
        if (launchExternalActivitySafely(launch) == ExternalActivityLaunchOutcome.UNAVAILABLE) {
            pendingCameraUri = null
            showAttachmentPicker = false
            showAttachmentPickerUnavailableDialog = true
        }
    }
    val launchCamera = {
        val file = java.io.File(composerContext.cacheDir, "chat_capture_${System.currentTimeMillis()}.jpg")
        val uri = androidx.core.content.FileProvider.getUriForFile(
            composerContext,
            "${composerContext.packageName}.fileprovider",
            file,
        )
        pendingCameraUri = uri
        launchExternalActivity { cameraLauncher.launch(uri) }
    }

    ComposerAttachmentDialogs(
        showPickerUnavailable = showAttachmentPickerUnavailableDialog,
        onDismissPickerUnavailable = { showAttachmentPickerUnavailableDialog = false },
        showAttachmentSizeLimitDialog = showAttachmentSizeLimitDialog,
        onDismissAttachmentSizeLimitDialog = onDismissAttachmentSizeLimitDialog,
    )

    // The input bar surface paints no background: the earlier transparent-to-solid scrim sat over the list and
    // bled under the navigation bar, which looked like a floating rectangle. The message list now fades itself
    // out with a mask (ChatListEdgeFade), so the page background runs continuously to the bottom of the screen.
    val composerSurfaceModifier = Modifier.fillMaxWidth()
    Box(modifier = composerSurfaceModifier) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = OriveoTheme.spacing.lg)
                .padding(top = 12.dp, bottom = OriveoTheme.spacing.sm + 2.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            NoteContextSection(
                attachedNotes = attachedNotes,
                relatedNotes = relatedNotes,
                onAttach = onAttachNote,
                onDismissRelated = onDismissRelatedNote,
                onDetach = onDetachNote,
                onPreview = onPreviewNote,
            )

            AnimatedVisibility(
                visible = showsModeControls,
                enter = slideInVertically(initialOffsetY = { it / 2 }) + fadeIn(),
                exit = slideOutVertically(targetOffsetY = { it / 2 }) + fadeOut(),
            ) {
                ComposerModeControlsRow(
                    modelControlsEmphasized = outboundCapabilityDecision.hasActiveCapabilitySelection || hasModelBehaviorOverride,
                    activeCapabilityIcons = activeCapabilityIcons,
                    modelControlAccessibilityState = modelControlAccessibilityState,
                    onOpenModelControls = {
                        val restored = restoredCapabilityPreferences()
                        selectedControlWeb = restored.web
                        selectedControlReasoning = restored.reasoningIntent
                        showModelControls = true
                    },
                    controlsEnabled = controlsEnabled,
                    isReadOnly = isReadOnly,
                    mcpEntryVisible = mcpEntryVisible,
                    mcpToolsAvailable = mcpToolsAvailable,
                    mcpEnabledServerCount = mcpEnabledServerCount,
                    onOpenMcpTools = onOpenMcpTools,
                    contextUsage = contextUsage,
                    onOpenContextUsage = onOpenContextUsage,
                )
            }

            AnimatedVisibility(
                visible = pendingAttachments.isNotEmpty(),
                enter = slideInVertically(initialOffsetY = { it / 2 }) + fadeIn(),
                exit = slideOutVertically(targetOffsetY = { it / 2 }) + fadeOut(),
            ) {
                ComposerAttachmentTray(
                    pendingAttachments = pendingAttachments,
                    restoredImageStates = restoredImageStates,
                    attachmentAccent = attachmentAccent,
                    onAttachmentRemove = onAttachmentRemove,
                    onNavigateToSkillEdit = onNavigateToSkillEdit,
                )
            }

            ComposerInputRow(
                inputTextProvider = inputTextProvider,
                onInputChange = onInputChange,
                hasComposerContent = hasComposerContent,
                hasDraftHighlight = hasDraftHighlight,
                composerFocused = composerFocused,
                onComposerFocusedChange = { composerFocused = it },
                onComposerFocused = onComposerFocused,
                composerFocusRequester = composerFocusRequester,
                keyboardController = keyboardController,
                composerContext = composerContext,
                pendingQuoteContext = pendingQuoteContext,
                onRemoveQuote = onRemoveQuote,
                controlsEnabled = controlsEnabled,
                isGenerating = isGenerating,
                isReadOnly = isReadOnly,
                isSendBlocked = isSendBlocked,
                supportsAttachmentEntry = supportsAttachmentEntry,
                attachmentEntry = attachmentEntry,
                attachmentEntryBlocked = attachmentUploadBlocked,
                deviceHasCamera = deviceHasCamera,
                attachmentButtonIcon = attachmentButtonIcon,
                attachmentAccent = attachmentAccent,
                attachmentButtonCount = attachmentButtonCount,
                showAttachmentPicker = showAttachmentPicker,
                onShowAttachmentPickerChange = { showAttachmentPicker = it },
                launchExternalActivity = launchExternalActivity,
                imagePicker = imagePicker,
                filePicker = filePicker,
                launchCamera = launchCamera,
                dictation = dictation,
                selectionProbe = selectionProbe,
                canSendDictation = canSendDictation,
                voiceConversationAvailable = voiceConversationAvailable,
                onStartVoiceConversation = onStartVoiceConversation,
                voiceBackToStage = voiceBackToStage,
                onBackToVoiceStage = onBackToVoiceStage,
                isAwaitingVoiceCatalog = isAwaitingVoiceCatalog,
                onStopGeneration = onStopGeneration,
                onSendClick = onSendClick,
            )

        }
    }
}

// The bodies below were moved out of EnhancedComposer verbatim: ART's verifier rejected EnhancedComposerKt
// (VerifyError "copy-reference v11<-v253 type=Boolean") once the single method neared the 256-register limit.
// State stays in EnhancedComposer; these only receive values and callbacks. Guarded by EnhancedComposerSizeGuardTest.

@Composable
private fun ComposerAttachmentDialogs(
    showPickerUnavailable: Boolean,
    onDismissPickerUnavailable: () -> Unit,
    showAttachmentSizeLimitDialog: Boolean,
    onDismissAttachmentSizeLimitDialog: () -> Unit,
) {
    if (showPickerUnavailable) {
        AlertDialog(
            onDismissRequest = onDismissPickerUnavailable,
            title = { Text(stringResource(R.string.attachment_picker_unavailable_title)) },
            text = { Text(stringResource(R.string.attachment_picker_unavailable_message)) },
            confirmButton = {
                TextButton(onClick = onDismissPickerUnavailable) {
                    Text(stringResource(R.string.ok))
                }
            },
        )
    }

    if (showAttachmentSizeLimitDialog) {
        AlertDialog(
            onDismissRequest = onDismissAttachmentSizeLimitDialog,
            title = { Text(stringResource(R.string.attachment_too_large_title)) },
            text = {
                Text(
                    stringResource(
                        R.string.attachment_too_large_message,
                        AttachmentImportPolicy.sizeLimitMegabytes(AttachmentImportPolicy.MAX_ATTACHMENT_BYTES),
                    ),
                )
            },
            confirmButton = {
                TextButton(onClick = onDismissAttachmentSizeLimitDialog) {
                    Text(stringResource(R.string.ok))
                }
            },
        )
    }

}

/** Model controls sheet; the panel's own navigation exits are wired here, state writes come in as callbacks. */
@Composable
private fun ComposerModelControlsSheetHost(
    generationParameterProvider: Provider?,
    currentModel: AIModel?,
    generationParameterConversationId: String,
    modelControlsFinalTransport: String?,
    metadataRevision: String?,
    capabilityObservationRevision: Long,
    controlsEnabled: Boolean,
    @StringRes modelControlReadOnlyReasonRes: Int?,
    selectedControlWeb: CapabilityWebPreference,
    selectedControlReasoning: String?,
    developerCustomOwners: Set<String>,
    modelBehaviorOverrideCount: Int,
    attachmentEntry: ComposerAttachmentEntryModel,
    outboundHistoryHasVideo: Boolean,
    onSelectionChange: (CapabilityWebPreference, String?, Boolean) -> Unit,
    onPersist: (CapabilityPreferenceValues) -> Unit,
    onPromoteToModelDefault: (CapabilityPreferenceValues) -> Unit,
    onAdvancedSettingsClosed: () -> Unit,
    onOpenModelSwitcher: () -> Unit,
    generationParameterProviderId: String?,
    onNavigateToProviderDetail: (providerId: String) -> Unit,
    onNavigateToConnectionWebSearch: (providerId: String) -> Unit,
    onNavigateToRelayModelAdvanced: (providerId: String, modelId: String) -> Unit,
    modelControlsWebSearch: ai.oriveo.community.feature.chat.modelcontrols.ModelControlsWebSearch?,
    isExistingConversation: Boolean,
    modelControlsOpensSearchMethod: Boolean,
    onNavigateToWebSearchFromChat: (conversationId: String?, oneTap: ai.oriveo.community.core.search.OneTapReuseTarget?) -> Unit,
    onNavigateToProviderSetup: () -> Unit,
    onSelectModel: (providerId: String, modelId: String) -> Unit,
    onDismiss: () -> Unit,
) {
    ModelControlsEntrySheet(
        provider = generationParameterProvider,
        model = currentModel,
        conversationId = generationParameterConversationId,
        finalTransport = modelControlsFinalTransport,
        metadataRevision = metadataRevision,
        capabilityObservationRevision = capabilityObservationRevision,
        runtimeIsReadOnly = !controlsEnabled,
        runtimeReadOnlyReasonRes = modelControlReadOnlyReasonRes,
        web = selectedControlWeb,
        reasoningIntent = selectedControlReasoning,
        customOwners = developerCustomOwners,
        generationOverrideCount = modelBehaviorOverrideCount,
        attachmentEntry = attachmentEntry,
        outboundHistoryHasVideo = outboundHistoryHasVideo,
        onSelectionChange = onSelectionChange,
        onPersist = onPersist,
        onPromoteToModelDefault = onPromoteToModelDefault,
        onAdvancedSettingsClosed = onAdvancedSettingsClosed,
        onChooseAnotherModel = onOpenModelSwitcher,
        // This exit must land on this connection's own detail page (the relay protocol is edited there).
        // The missing-model panel's "choose connection" still goes to ProviderSetup: there is no "this connection" then.
        onOpenConnectionSettings = {
            generationParameterProviderId?.let(onNavigateToProviderDetail)
        },
        onOpenConnectionWebSearch = {
            generationParameterProviderId?.let(onNavigateToConnectionWebSearch)
        },
        onOpenRelayModelAdvanced = { modelId ->
            generationParameterProviderId?.let { onNavigateToRelayModelAdvanced(it, modelId) }
        },
        webSearch = modelControlsWebSearch,
        webSearchDraft = !isExistingConversation,
        opensSearchMethod = modelControlsOpensSearchMethod,
        // Second argument = whether passing writes this conversation's web search (not when the panel cannot persist); no write, no conversation id.
        onOpenWebSearchFromChat = { oneTap, arms, serviceIdsBefore ->
            ai.oriveo.community.core.search.WebSearchChatReturn.leave(
                ai.oriveo.community.core.search.WebSearchChatReturn.Pending(
                    generationParameterConversationId, oneTap != null, arms, serviceIdsBefore,
                ),
            )
            onNavigateToWebSearchFromChat(generationParameterConversationId.takeIf { arms }, oneTap)
        },
        onNavigateToProviderSetup = onNavigateToProviderSetup,
        onSelectModel = onSelectModel,
        onDismiss = onDismiss,
    )
}

/** Mode chips row (model controls / MCP) with the context usage ring pinned at the end. */
@Composable
private fun ComposerModeControlsRow(
    modelControlsEmphasized: Boolean,
    activeCapabilityIcons: List<ImageVector>,
    modelControlAccessibilityState: String?,
    onOpenModelControls: () -> Unit,
    controlsEnabled: Boolean,
    isReadOnly: Boolean,
    mcpEntryVisible: Boolean,
    mcpToolsAvailable: Boolean,
    mcpEnabledServerCount: Int,
    onOpenMcpTools: () -> Unit,
    contextUsage: ai.oriveo.community.feature.chat.ContextUsageSummary?,
    onOpenContextUsage: () -> Unit,
) {
    val hapticFeedback = LocalHapticFeedback.current
    BoxWithConstraints(
        modifier = Modifier
            .fillMaxWidth()
            .offset(y = 4.dp),
    ) {
        // Chips scroll; the usage ring stays pinned at the trailing end .
        Row(
            modifier = Modifier.widthIn(max = maxWidth).fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
        Row(
            modifier = Modifier
                .weight(1f)
                .wrapContentWidth(Alignment.Start)
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 2.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ComposerControlChip(
                title = stringResource(R.string.model_controls),
                icon = Icons.Outlined.Tune,
                accent = composerModelBehaviorAccent(),
                emphasized = modelControlsEmphasized,
                disabled = false,
                badgeText = null,
                accessory = ComposerControlChipAccessory.Chevron,
                capabilityIcons = activeCapabilityIcons,
                accessibilityState = modelControlAccessibilityState,
                onClick = onOpenModelControls,
            )

            // Remote MCP entry. The caller hides it when no server is added; discovery lives in Settings > MCP.
            // It opens while answering too: the toggles affect only the next send, never the running turn.
            if (mcpEntryVisible) {
                val mcpOn = mcpToolsAvailable && mcpEnabledServerCount > 0
                ComposerControlChip(
                    title = stringResource(R.string.mcp_tools_chip),
                    icon = Icons.Outlined.Build,
                    accent = composerModelBehaviorAccent(),
                    emphasized = mcpOn,
                    disabled = isReadOnly,
                    badgeText = mcpEnabledServerCount.takeIf { mcpOn }?.toString(),
                    accessory = ComposerControlChipAccessory.None,
                    accessibilityState = when {
                        !mcpToolsAvailable -> stringResource(R.string.mcp_tools_chip_state_unavailable)
                        mcpOn -> stringResource(R.string.mcp_tools_chip_state_on, mcpEnabledServerCount)
                        else -> stringResource(R.string.mcp_tools_chip_state_off)
                    },
                    dimmed = !mcpToolsAvailable,
                    onClick = {
                        hapticFeedback.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        onOpenMcpTools()
                    },
                )
            }
        }
        ai.oriveo.community.feature.chat.ContextUsageRing(
            summary = contextUsage,
            onClick = onOpenContextUsage,
            modifier = Modifier.padding(start = 4.dp, end = 2.dp),
        )
        }
    }
}

/** Pending attachment thumbnails tray. */
@Composable
private fun ComposerAttachmentTray(
    pendingAttachments: List<Attachment>,
    restoredImageStates: Map<String, RestoredImageState>,
    attachmentAccent: ComposerCapabilityAccent,
    onAttachmentRemove: (String) -> Unit,
    onNavigateToSkillEdit: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val isDarkTheme = OriveoTheme.isDark
    val trayShape = RoundedCornerShape(20.dp)

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(78.dp)
            .shadow(
                elevation = 7.dp,
                shape = trayShape,
                ambientColor = colors.shadow.opacity(if (isDarkTheme) 0.12f else 0.035f),
                spotColor = colors.shadow.opacity(if (isDarkTheme) 0.12f else 0.035f),
            )
            .clip(trayShape)
            .background(
                color = composerDynamicColor(
                    light = 0xF8FAFC,
                    dark = 0x111A2C,
                    lightAlpha = 0.66f,
                    darkAlpha = 0.58f,
                ),
                shape = trayShape,
            )
            .drawWithCache {
                val tint = attachmentAccent.softFill.copy(alpha = if (isDarkTheme) 0.05f else 0.08f)
                onDrawWithContent {
                    drawContent()
                    val cr = CornerRadius(20.dp.toPx(), 20.dp.toPx())
                    drawRoundRect(color = tint, cornerRadius = cr)
                }
            },
    ) {
        LazyRow(
            modifier = Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        ) {
            items(pendingAttachments, key = { it.id }) { attachment ->
                ComposerAttachmentThumbnail(
                    attachment = attachment,
                    restoredState = restoredImageStates[attachment.id],
                    onRemove = { onAttachmentRemove(attachment.id) },
                )
            }
        }
    }
}

/** Input shell (quote chip, attachment entry, text field, dictation) plus the send / voice action cluster. */
@Composable
private fun ComposerInputRow(
    inputTextProvider: () -> String,
    onInputChange: (String) -> Unit,
    hasComposerContent: Boolean,
    hasDraftHighlight: Boolean,
    composerFocused: Boolean,
    onComposerFocusedChange: (Boolean) -> Unit,
    onComposerFocused: () -> Unit,
    composerFocusRequester: FocusRequester,
    keyboardController: SoftwareKeyboardController?,
    composerContext: android.content.Context,
    pendingQuoteContext: QuoteContext?,
    onRemoveQuote: () -> Unit,
    controlsEnabled: Boolean,
    isGenerating: Boolean,
    isReadOnly: Boolean,
    isSendBlocked: Boolean,
    supportsAttachmentEntry: Boolean,
    attachmentEntry: ComposerAttachmentEntryModel,
    attachmentEntryBlocked: Boolean,
    deviceHasCamera: Boolean,
    attachmentButtonIcon: ImageVector,
    attachmentAccent: ComposerCapabilityAccent,
    attachmentButtonCount: Int,
    showAttachmentPicker: Boolean,
    onShowAttachmentPickerChange: (Boolean) -> Unit,
    launchExternalActivity: (() -> Unit) -> Unit,
    imagePicker: androidx.activity.result.ActivityResultLauncher<androidx.activity.result.PickVisualMediaRequest>,
    filePicker: androidx.activity.result.ActivityResultLauncher<Array<String>>,
    launchCamera: () -> Unit,
    dictation: DictationHostCoordinator?,
    selectionProbe: ComposerSelectionProbe?,
    canSendDictation: (() -> Boolean)?,
    voiceConversationAvailable: Boolean,
    onStartVoiceConversation: () -> Unit,
    voiceBackToStage: Boolean,
    onBackToVoiceStage: () -> Unit,
    isAwaitingVoiceCatalog: Boolean,
    onStopGeneration: () -> Unit,
    onSendClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        val composerShape = RoundedCornerShape(24.dp)
        val composerShellFill = composerShellFillColor(
            isDark = OriveoTheme.isDark,
            focused = composerFocused,
            draftHighlight = hasDraftHighlight,
            colors = colors,
        )
        val composerShellBorder = when {
            // Focused: the solid stroke gives way to the gradient border (ComposerAnimatedAiBorder)
            composerFocused -> Color.Transparent
            hasDraftHighlight -> colors.primary.copy(alpha = 0.25f)
            // Unfocused: a soft lavender stroke instead of neutral grey, in the aurora / brand family
            else -> colors.primary.copy(alpha = 0.16f)
        }
        val composerShellSurfaceModifier = Modifier.background(composerShellFill, composerShape)

        Column(
            modifier = Modifier
                .weight(1f),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            pendingQuoteContext?.takeIf { it.isValid }?.let { quote ->
                QuoteContextChip(
                    quote = quote,
                    presentation = QuoteContextChipPresentation.Composer,
                    onRemove = onRemoveQuote,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            DictationInputSwitcher(
                handle = dictation,
                // Same gate as the send button, treating the transcript as composer content.
                canSend = canSendDictation ?: { !isReadOnly && !isSendBlocked && !isGenerating },
                modifier = Modifier.fillMaxWidth(),
                // Like iOS DictationInputRow: the border wraps only the input row; the recording bar /
                // busy row is its own row 8 dp below, outside the border (the main key steps aside).
                spacing = 8.dp,
                input = { dictationRow ->
            Box(
                modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 50.dp, max = 156.dp)
                // No Modifier.shadow(elevation): the shell fill is translucent glass (the aurora shows through) and the
                // native elevation shadow, drawn behind the element, would show as a dark ring inside the rounded edge
                // (ambient/spotColor only work on API 28+, pure black on minSdk 26). Depth comes from border + focus border.
                .clip(composerShape)
                .then(composerShellSurfaceModifier)
                .border(OriveoBorderWidth.standard, composerShellBorder, composerShape),
            ) {
            val dictationIdle = dictationRow == DictationInputRow.Normal
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        start = if (supportsAttachmentEntry && dictationIdle) 6.dp else 14.dp,
                        top = 5.dp,
                        end = 14.dp,
                        bottom = 5.dp,
                    ),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (supportsAttachmentEntry && dictationIdle) {
                    val attachmentEntryDisabled = !controlsEnabled || attachmentEntryBlocked
                    // Vision models: the image entry splits into camera + library, matching iOS / ChatGPT / Claude.
                    // Camera shows only when the device has one (some ChromeOS / foldable / tablet devices do not).
                    val cameraItem = attachmentEntry.camera(deviceHasCamera)
                    val totalAttachmentOptions = (listOf(cameraItem) + attachmentEntry.items).count { it.shown }
                    ComposerAttachmentEntryButton(
                        icon = attachmentButtonIcon,
                        accent = attachmentAccent,
                        count = attachmentButtonCount,
                        emphasized = attachmentButtonCount > 0,
                        disabled = attachmentEntryDisabled,
                        showMenu = showAttachmentPicker,
                        onDismissMenu = { onShowAttachmentPickerChange(false) },
                        onClick = {
                            if (attachmentEntryDisabled) return@ComposerAttachmentEntryButton
                            when {
                                totalAttachmentOptions > 1 -> onShowAttachmentPickerChange(true)
                                attachmentEntry.image.enabled -> {
                                    launchExternalActivity {
                                        imagePicker.launch(
                                            androidx.activity.result.PickVisualMediaRequest(
                                                ActivityResultContracts.PickVisualMedia.ImageOnly,
                                            ),
                                        )
                                    }
                                }
                                attachmentEntry.video.enabled -> launchExternalActivity {
                                    filePicker.launch(AttachmentImportPolicy.videoPickerMimeTypes)
                                }
                                attachmentEntry.file.enabled -> launchExternalActivity {
                                    filePicker.launch(AttachmentImportPolicy.pickerMimeTypes)
                                }
                            }
                        },
                        onPickCamera = {
                            onShowAttachmentPickerChange(false)
                            launchCamera()
                        },
                        onPickImage = {
                            onShowAttachmentPickerChange(false)
                            launchExternalActivity {
                                imagePicker.launch(
                                    androidx.activity.result.PickVisualMediaRequest(
                                        ActivityResultContracts.PickVisualMedia.ImageOnly,
                                    ),
                                )
                            }
                        },
                        onPickVideo = {
                            onShowAttachmentPickerChange(false)
                            launchExternalActivity {
                                filePicker.launch(AttachmentImportPolicy.videoPickerMimeTypes)
                            }
                        },
                        onPickFile = {
                            onShowAttachmentPickerChange(false)
                            launchExternalActivity {
                                filePicker.launch(AttachmentImportPolicy.pickerMimeTypes)
                            }
                        },
                        cameraItem = cameraItem,
                        imageItem = attachmentEntry.image,
                        videoItem = attachmentEntry.video,
                        fileItem = attachmentEntry.file,
                    )
                }

                ComposerTextField(
                    textProvider = inputTextProvider,
                    onValueChange = onInputChange,
                    enabled = controlsEnabled,
                    placeholderRes = when {
                        isGenerating -> R.string.ai_is_answering
                        isReadOnly -> R.string.chat_read_only_placeholder
                        else -> R.string.type_a_message
                    },
                    focusRequester = composerFocusRequester,
                    onFocusChanged = { focused ->
                        onComposerFocusedChange(focused)
                        if (focused) onComposerFocused()
                    },
                    selectionProbe = selectionProbe,
                    listening = dictationRow is DictationInputRow.Recording,
                    modifier = Modifier.weight(1f),
                )

                if (dictationIdle) {
                    if (dictation != null) {
                        DictationMicButton(
                            onClick = dictation::onMicTap,
                            enabled = controlsEnabled,
                        )
                    }
                }
            }

            // Dictation recording: slow rotating glow; otherwise the gradient AI border shows only while focused (unmounted on blur)
            ComposerDictationGlowSlot(
                handle = dictation,
                cornerRadius = 24.dp,
                modifier = Modifier.matchParentSize(),
            ) {
                if (composerFocused) {
                    ComposerAnimatedAiBorder(
                        cornerRadius = 24.dp,
                        modifier = Modifier.matchParentSize(),
                    )
                }
            }
            }
            },
            ) {}
        }

        val voiceEntryAvailable = voiceConversationAvailable && !isReadOnly && !isSendBlocked
        // Recording / transcribing replaces the input row with the dictation bar; the main key steps aside.
        DictationMainKeySlot(handle = dictation) {
        ComposerActionCluster(
            isGenerating = isGenerating,
            isPrimed = hasComposerContent && !isGenerating && !isSendBlocked,
            enabled = isGenerating ||
                (!isReadOnly && !isSendBlocked && (hasComposerContent || voiceEntryAvailable)),
            // Lifted 7 dp so the 40 dp circle centers on the field vertically (matches iOS .padding(.bottom, 7))
            modifier = Modifier.padding(bottom = 7.dp),
            voiceAvailable = voiceEntryAvailable,
            onStartVoice = {
                keyboardController?.hide()
                onComposerFocusedChange(false)
                onStartVoiceConversation()
            },
            backToStage = voiceBackToStage,
            awaitingCatalog = isAwaitingVoiceCatalog,
            onBackToStage = {
                keyboardController?.hide()
                onComposerFocusedChange(false)
                onBackToVoiceStage()
            },
        ) {
            @Suppress("DEPRECATION")
            val vibrator = composerContext.getSystemService(android.content.Context.VIBRATOR_SERVICE) as? android.os.Vibrator

            if (isGenerating) {
                vibrator?.vibrate(android.os.VibrationEffect.createOneShot(40, android.os.VibrationEffect.DEFAULT_AMPLITUDE))
                onStopGeneration()
            } else if (!isReadOnly && !isSendBlocked && hasComposerContent) {
                keyboardController?.hide()
                onComposerFocusedChange(false)
                vibrator?.vibrate(android.os.VibrationEffect.createOneShot(20, android.os.VibrationEffect.DEFAULT_AMPLITUDE))
                onSendClick()
            }
        }
        }
    }
}

/** The single entry point for reading the provider id in [EnhancedComposer]; a separate function avoids a D8 null-check miscompile in the very large method. */
private fun composerProviderId(provider: Provider?): String? = provider?.id

/**
 * The text field itself. **The only composable that recomposes per keystroke.**
 *
 * [textProvider] is a lazy read: the text lives in the local snapshot state of `ChatComposerHost`
 * further up the call chain, and calling the provider here is what creates the subscription. So a
 * keystroke invalidates this function and nothing else -- not `EnhancedComposer` (a thousand plus
 * lines of capability resolution and `stringResource` lookups), not `ChatComposerHost`, not
 * `ChatScreenContent`, and not `ChatMessagesList`. Taking `value: String` as a parameter here would
 * void that protection entirely (a changed parameter makes the caller non skippable).
 */
/** Hands focus and keyboard to the input when a valid quote appears or changes (the quote card's "Ask about this"). */
@Composable
private fun ComposerQuoteFocusEffect(
    quote: QuoteContext?,
    enabled: Boolean,
    focusRequester: FocusRequester,
    keyboardController: SoftwareKeyboardController?,
) {
    LaunchedEffect(quote?.sourceMessageId, quote?.selectedText) {
        if (quote?.isValid == true && enabled) {
            focusRequester.requestFocus()
            keyboardController?.show()
        }
    }
}

@Composable
private fun ComposerTextField(
    textProvider: () -> String,
    onValueChange: (String) -> Unit,
    enabled: Boolean,
    @StringRes placeholderRes: Int,
    focusRequester: FocusRequester,
    onFocusChanged: (Boolean) -> Unit,
    selectionProbe: ComposerSelectionProbe? = null,
    /** Dictation is recording into this field: an empty field shows the listening placeholder. */
    listening: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val text = textProvider()
    // The length limit has to read and write the selection (after a paste in the middle is cut the
    // caret lands at the end of the kept part), hence the TextFieldValue overload. The selection
    // state stays in this composable; the owner still receives a plain String.
    val field = rememberComposerLengthLimitedField(text = text, onTextChange = onValueChange, selectionProbe = selectionProbe)
    BasicTextField(
        value = field.value,
        onValueChange = field.onValueChange,
        visualTransformation = field.visualTransformation,
        modifier = modifier
            // UI tests locate the field by resource-id rather than by coordinates, which break as
            // soon as the screen resolution changes.
            .testTag("chat_composer_input")
            .focusRequester(focusRequester)
            .onFocusChanged { onFocusChanged(it.isFocused) },
        enabled = enabled,
        minLines = 1,
        maxLines = 5,
        textStyle = OriveoTheme.typography.body.copy(
            color = if (enabled) colors.textPrimary else colors.textTertiary,
        ).merge(userContentTextStyle),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
        cursorBrush = SolidColor(colors.primary),
        decorationBox = { innerTextField ->
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .padding(vertical = 8.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                if (text.isBlank()) {
                    Text(
                        text = stringResource(if (listening) R.string.voice_dictation_listening_placeholder else placeholderRes),
                        style = OriveoTheme.typography.body,
                        color = if (enabled) colors.textSecondary else colors.textTertiary,
                    )
                }
                // Full-width host so the field lays out by content direction ("/we" sits left under RTL).
                Box(modifier = Modifier.fillMaxWidth()) {
                    innerTextField()
                }
            }
        },
    )
}

/**
 * Identity loading must restart when the resolved Relay route can change, without retaining an
 * API key or request headers in Compose state keys. `updatedAt` covers local credential/connection
 * epoch updates; the route fields cover same-id endpoint and transport edits.
 */
