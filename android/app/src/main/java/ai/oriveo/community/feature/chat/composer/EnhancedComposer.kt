package ai.oriveo.community.feature.chat.composer

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
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
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
import androidx.compose.material.icons.outlined.MenuBook
import androidx.compose.material.icons.outlined.Psychology
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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
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
    inputText: String,
    onInputChange: (String) -> Unit,
    pendingAttachments: List<Attachment>,
    pendingQuoteContext: QuoteContext?,
    onRemoveQuote: () -> Unit,
    onAttachmentRemove: (String) -> Unit,
    currentModel: AIModel?,
    generationParameterProvider: Provider?,
    generationParameterConversationId: String,
    isExistingConversation: Boolean,

    conversationSkillId: String?,
    /** Exact transport that the selected official model will use; null intentionally fails closed. */
    modelControlsFinalTransport: String?,
    supportsImageAttachment: Boolean,
    supportsVideoAttachment: Boolean,
    supportsFileAttachment: Boolean,
    onSelectReasoningMode: (ReasoningMode) -> Unit,

    onSelectModel: (providerId: String, modelId: String) -> Unit,
    onOpenModelSwitcher: () -> Unit,
    showAttachmentSizeLimitDialog: Boolean,
    onDismissAttachmentSizeLimitDialog: () -> Unit,
    onProcessImageUri: (android.net.Uri) -> Unit,
    onProcessFileUri: (android.net.Uri) -> Unit,
    onSendClick: () -> Unit,
    onStopGeneration: () -> Unit,
    providerKind: ProviderKind?,
    onNavigateToProviderSetup: () -> Unit,

    onNavigateToProviderDetail: (providerId: String) -> Unit = {},
    onNavigateToSkillEdit: () -> Unit = {},
    isGenerating: Boolean,
    isReadOnly: Boolean,

    transparentChrome: Boolean,
    hazeState: HazeState,
    trueTransparentBlurEnabled: Boolean,

    attachedNotes: List<ai.oriveo.community.core.model.Note> = emptyList(),
    relatedNotes: List<ai.oriveo.community.core.model.Note> = emptyList(),
    onAttachNote: (ai.oriveo.community.core.model.Note) -> Unit = {},
    onDismissRelatedNote: (ai.oriveo.community.core.model.Note) -> Unit = {},
    onDetachNote: (ai.oriveo.community.core.model.Note) -> Unit = {},
    onPreviewNote: (ai.oriveo.community.core.model.Note) -> Unit = {},
) {
    val colors = OriveoTheme.colors
    val isDarkTheme = OriveoTheme.isDark
    val hapticFeedback = LocalHapticFeedback.current
    val keyboardController = LocalSoftwareKeyboardController.current
    val composerFocusRequester = remember { FocusRequester() }
    LaunchedEffect(pendingQuoteContext?.sourceMessageId, pendingQuoteContext?.selectedText) {
        if (pendingQuoteContext?.isValid == true && !isReadOnly && !isGenerating) {
            composerFocusRequester.requestFocus()
            keyboardController?.show()
        }
    }
    val controlsEnabled = !isGenerating && !isReadOnly
    val context = LocalContext.current
    val generationSettingsStore = remember(context) { GenerationParameterSettingsStore.from(context) }
    val capabilityPreferenceStore = remember(context) { CapabilityPreferenceStore.from(context) }
    val localCustomFragmentStore = remember(context) { LocalCapabilityCustomFragmentStore.from(context) }
    val metadataRevision = MetadataClient.instance.currentMetadataRevision()
    val modelControlRuntimeIdentity = generationParameterProvider?.let { provider ->
        currentModel?.let { model -> ModelControlRuntimeIdentityResolver.resolve(provider, model) }
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

    var modelBehaviorRevision by remember { mutableIntStateOf(0) }
    var selectedControlWeb by remember(generationParameterProvider?.id, currentModel?.id, generationParameterConversationId) {
        mutableStateOf(CapabilityWebPreference.Off)
    }
    var selectedControlReasoning by remember(generationParameterProvider?.id, currentModel?.id, generationParameterConversationId) {
        mutableStateOf<String?>(null)
    }

    var developerCustomOwners by remember(generationParameterProvider?.id, currentModel?.id, generationParameterConversationId) {
        mutableStateOf<Set<String>>(emptySet())
    }

    fun restoredCapabilityPreferences(): CapabilityPreferenceValues {
        val provider = generationParameterProvider ?: return CapabilityPreferenceValues()
        currentModel ?: return CapabilityPreferenceValues()
        val identity = modelControlRuntimeIdentity ?: return CapabilityPreferenceValues()

        return capabilityPreferenceStore.displayedForUi(
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = identity.canonicalModelId,
            conversationID = generationParameterConversationId,
            skillID = conversationSkillId,
            transportIdentity = identity.storageIdentity,
            isExistingConversation = isExistingConversation,
        )
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
        ).keys
    }

    fun persistCapabilityPreferences(values: CapabilityPreferenceValues) {
        val provider = generationParameterProvider ?: return
        currentModel ?: return
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
        generationParameterProvider?.id,
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
        generationParameterProvider?.id,
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
        generationParameterProvider?.id,
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
    if (showModelControls) {
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
            onChooseAnotherModel = onOpenModelSwitcher,

            onOpenConnectionSettings = {
                generationParameterProvider?.id?.let(onNavigateToProviderDetail)
            },
            onNavigateToProviderSetup = onNavigateToProviderSetup,
            onSelectModel = onSelectModel,
            onDismiss = {
                showModelControls = false

                modelBehaviorRevision += 1
            },
        )
    }
    val supportsAttachmentEntry = supportsImageAttachment || supportsVideoAttachment || supportsFileAttachment
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
        supportsImageAttachment && !supportsFileAttachment -> imageAttachmentCount
        supportsVideoAttachment && !supportsImageAttachment && !supportsFileAttachment -> videoAttachmentCount
        supportsFileAttachment && !supportsImageAttachment -> fileAttachmentCount
        else -> pendingAttachmentCount
    }
    val supportedAttachmentKinds = listOf(
        supportsImageAttachment,
        supportsVideoAttachment,
        supportsFileAttachment,
    ).count { it }
    val attachmentButtonIcon = when {
        supportedAttachmentKinds != 1 -> Icons.Filled.Add
        supportsImageAttachment -> Icons.Outlined.Image
        supportsVideoAttachment -> Icons.Outlined.Videocam
        supportsFileAttachment -> Icons.Outlined.Description
        else -> Icons.Filled.Add
    }
    val hasComposerContent = inputText.trim().isNotEmpty() || pendingAttachments.isNotEmpty()
    val dormantCapabilityOwners = modelControlRuntimeIdentity?.let { identity ->
        setOf("web", "reasoning").filterTo(linkedSetOf()) { owner ->
            ModelControlRejectionCache.isRejectedByAnySource(identity, owner)
        }
    }.orEmpty()
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
    val hasWebHighlight = outboundCapabilityDecision.hasWebSelection
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
    val attachmentSyncBannerText: String? = null
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

    if (showAttachmentPickerUnavailableDialog) {
        AlertDialog(
            onDismissRequest = { showAttachmentPickerUnavailableDialog = false },
            title = { Text(stringResource(R.string.attachment_picker_unavailable_title)) },
            text = { Text(stringResource(R.string.attachment_picker_unavailable_message)) },
            confirmButton = {
                TextButton(onClick = { showAttachmentPickerUnavailableDialog = false }) {
                    Text(stringResource(R.string.ok))
                }
            },
        )
    }

    if (showAttachmentSizeLimitDialog) {
        AlertDialog(
            onDismissRequest = onDismissAttachmentSizeLimitDialog,
            title = { Text(stringResource(R.string.attachment_too_large_title)) },
            text = { Text(stringResource(R.string.attachment_too_large_message)) },
            confirmButton = {
                TextButton(onClick = onDismissAttachmentSizeLimitDialog) {
                    Text(stringResource(R.string.ok))
                }
            },
        )
    }

    val scrimBleedPx = with(LocalDensity.current) {
        WindowInsets.navigationBars.getBottom(this).toFloat()
    }
    val composerSurfaceModifier = if (transparentChrome) {
        Modifier.fillMaxWidth()
    } else {
        Modifier
            .fillMaxWidth()
            .drawBehind {

                val scrimHeight = size.height + scrimBleedPx
                drawRect(
                    brush = Brush.verticalGradient(
                        colorStops = arrayOf(
                            0f to colors.background.copy(alpha = 0f),
                            0.42f to colors.background,
                            1f to colors.background,
                        ),
                        startY = 0f,
                        endY = scrimHeight,
                    ),
                    size = Size(size.width, scrimHeight),
                )
            }
    }
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
                visible = attachmentSyncBannerText != null,
                enter = slideInVertically(initialOffsetY = { -it / 2 }) + fadeIn(),
                exit = slideOutVertically(targetOffsetY = { -it / 2 }) + fadeOut(),
            ) {
                attachmentSyncBannerText?.let { text ->
                    Unit
                }
            }

            AnimatedVisibility(
                visible = showsModeControls,
                enter = slideInVertically(initialOffsetY = { it / 2 }) + fadeIn(),
                exit = slideOutVertically(targetOffsetY = { it / 2 }) + fadeOut(),
            ) {
                BoxWithConstraints(
                    modifier = Modifier
                        .fillMaxWidth()
                        .offset(y = 4.dp),
                ) {
                    Row(
                        modifier = Modifier
                            .widthIn(max = maxWidth)
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
                            emphasized = outboundCapabilityDecision.hasActiveCapabilitySelection || hasModelBehaviorOverride,
                            disabled = false,
                            badgeText = null,
                            accessory = ComposerControlChipAccessory.Chevron,
                            capabilityIcons = activeCapabilityIcons,
                            accessibilityState = modelControlAccessibilityState,
                            onClick = {
                                val restored = restoredCapabilityPreferences()
                                selectedControlWeb = restored.web
                                selectedControlReasoning = restored.reasoningIntent
                                showModelControls = true
                            },
                        )

                    }
                }
            }

            AnimatedVisibility(
                visible = pendingAttachments.isNotEmpty(),
                enter = slideInVertically(initialOffsetY = { it / 2 }) + fadeIn(),
                exit = slideOutVertically(targetOffsetY = { it / 2 }) + fadeOut(),
            ) {
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
                                onRemove = { onAttachmentRemove(attachment.id) },
                            )
                        }
                    }
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                val composerShape = RoundedCornerShape(22.dp)
                val composerShellFill = when {
                    composerFocused -> composerDynamicColor(light = 0xFFFFFF, dark = 0x101113, lightAlpha = 0.26f, darkAlpha = 0.46f)
                    hasDraftHighlight -> composerDynamicColor(light = 0xFBF9FF, dark = 0x0B0C0E, lightAlpha = 0.19f, darkAlpha = 0.42f)
                    else -> composerDynamicColor(light = 0xFFFFFF, dark = 0x07080A, lightAlpha = 0.11f, darkAlpha = 0.38f)
                }
                val composerShellBorder = when {

                    composerFocused -> Color.Transparent
                    hasDraftHighlight -> colors.primary.copy(alpha = 0.25f)

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
                    Box(
                        modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 50.dp, max = 156.dp)

                        .clip(composerShape)
                        .then(composerShellSurfaceModifier)
                        .border(OriveoBorderWidth.standard, composerShellBorder, composerShape),
                    ) {

                    if (hasDraftHighlight) {

                        val draftGlowBrush = remember(colors.primaryGlow) {
                            Brush.radialGradient(
                                colors = listOf(
                                    colors.primaryGlow.copy(alpha = 0.22f),
                                    Color.Transparent,
                                ),
                            )
                        }
                        Box(
                            modifier = Modifier.matchParentSize(),
                            contentAlignment = Alignment.CenterEnd,
                        ) {
                            Box(
                                modifier = Modifier
                                    .offset(x = 12.dp)
                                    .size(74.dp)
                                    .graphicsLayer {

                                        alpha = DRAFT_GLOW_ALPHA_RATIO
                                    }
                                    .background(brush = draftGlowBrush, shape = androidx.compose.foundation.shape.CircleShape),
                            )
                        }
                    }

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(
                                start = if (supportsAttachmentEntry) 6.dp else 14.dp,
                                top = 5.dp,
                                end = 14.dp,
                                bottom = 5.dp,
                            ),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        if (supportsAttachmentEntry) {

                            val attachmentEntryDisabled = !controlsEnabled || attachmentUploadBlocked

                            val showCameraOption = supportsImageAttachment && deviceHasCamera
                            val totalAttachmentOptions = (if (showCameraOption) 1 else 0) +
                                (if (supportsImageAttachment) 1 else 0) +
                                (if (supportsVideoAttachment) 1 else 0) +
                                (if (supportsFileAttachment) 1 else 0)
                            ComposerAttachmentEntryButton(
                                icon = attachmentButtonIcon,
                                accent = attachmentAccent,
                                count = attachmentButtonCount,
                                emphasized = attachmentButtonCount > 0,
                                disabled = attachmentEntryDisabled,
                                showMenu = showAttachmentPicker,
                                onDismissMenu = { showAttachmentPicker = false },
                                onClick = {
                                    if (attachmentEntryDisabled) return@ComposerAttachmentEntryButton
                                    when {
                                        totalAttachmentOptions > 1 -> showAttachmentPicker = true
                                        supportsImageAttachment -> {
                                            launchExternalActivity {
                                                imagePicker.launch(
                                                    androidx.activity.result.PickVisualMediaRequest(
                                                        ActivityResultContracts.PickVisualMedia.ImageOnly,
                                                    ),
                                                )
                                            }
                                        }
                                        supportsVideoAttachment -> launchExternalActivity {
                                            filePicker.launch(AttachmentImportPolicy.videoPickerMimeTypes)
                                        }
                                        supportsFileAttachment -> launchExternalActivity {
                                            filePicker.launch(AttachmentImportPolicy.pickerMimeTypes)
                                        }
                                    }
                                },
                                onPickCamera = {
                                    showAttachmentPicker = false
                                    launchCamera()
                                },
                                onPickImage = {
                                    showAttachmentPicker = false
                                    launchExternalActivity {
                                        imagePicker.launch(
                                            androidx.activity.result.PickVisualMediaRequest(
                                                ActivityResultContracts.PickVisualMedia.ImageOnly,
                                            ),
                                        )
                                    }
                                },
                                onPickVideo = {
                                    showAttachmentPicker = false
                                    launchExternalActivity {
                                        filePicker.launch(AttachmentImportPolicy.videoPickerMimeTypes)
                                    }
                                },
                                onPickFile = {
                                    showAttachmentPicker = false
                                    launchExternalActivity {
                                        filePicker.launch(AttachmentImportPolicy.pickerMimeTypes)
                                    }
                                },
                                showCameraOption = showCameraOption,
                                showImageOption = supportsImageAttachment,
                                showVideoOption = supportsVideoAttachment,
                                showFileOption = supportsFileAttachment,
                            )
                        }

                        BasicTextField(
                            value = inputText,
                            onValueChange = onInputChange,
                            modifier = Modifier
                                .weight(1f)
                                .focusRequester(composerFocusRequester)
                                .onFocusChanged { composerFocused = it.isFocused },
                            enabled = controlsEnabled,
                            minLines = 1,
                            maxLines = 5,
                            textStyle = OriveoTheme.typography.body.copy(
                                color = if (controlsEnabled) colors.textPrimary else colors.textTertiary,
                            ),
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
                                    if (inputText.isBlank()) {
                                        val placeholderText = when {
                                            isGenerating -> stringResource(R.string.ai_is_answering)
                                            isReadOnly -> stringResource(R.string.chat_read_only_placeholder)
                                            else -> stringResource(R.string.type_a_message)
                                        }
                                        Text(
                                            text = placeholderText,
                                            style = OriveoTheme.typography.body,
                                            color = if (controlsEnabled) colors.textSecondary else colors.textTertiary,
                                        )
                                    }
                                    innerTextField()
                                }
                            },
                        )
                    }

                    if (composerFocused) {
                        ComposerAnimatedAiBorder(
                            cornerRadius = 22.dp,
                            modifier = Modifier.matchParentSize(),
                        )
                    }
                    }
                }

                ComposerActionCluster(
                    isGenerating = isGenerating,
                    isPrimed = hasComposerContent && !isGenerating,
                    enabled = isGenerating || (!isReadOnly && hasComposerContent),

                    modifier = Modifier.padding(bottom = 7.dp),
                ) {
                    @Suppress("DEPRECATION")
                    val vibrator = composerContext.getSystemService(android.content.Context.VIBRATOR_SERVICE) as? android.os.Vibrator

                    if (isGenerating) {
                        vibrator?.vibrate(android.os.VibrationEffect.createOneShot(40, android.os.VibrationEffect.DEFAULT_AMPLITUDE))
                        onStopGeneration()
                    } else if (!isReadOnly && hasComposerContent) {
                        keyboardController?.hide()
                        composerFocused = false
                        vibrator?.vibrate(android.os.VibrationEffect.createOneShot(20, android.os.VibrationEffect.DEFAULT_AMPLITUDE))
                        onSendClick()
                    }
                }
            }
        }
    }
}

private const val DRAFT_GLOW_ALPHA_RATIO = 0.705f

/**
 * Identity loading must restart when the resolved Relay route can change, without retaining an
 * API key or request headers in Compose state keys. `updatedAt` covers local credential/connection
 * epoch updates; the route fields cover same-id endpoint and transport edits.
 */
