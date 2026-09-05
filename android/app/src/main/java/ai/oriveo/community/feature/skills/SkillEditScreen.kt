package ai.oriveo.community.feature.skills

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.util.launchExternalActivityOrNotify
import ai.oriveo.community.core.data.repository.KnowledgeCleanupInput
import ai.oriveo.community.core.model.SkillKnowledgeBase
import ai.oriveo.community.core.model.SkillKnowledgeBaseFile
import ai.oriveo.community.core.model.SkillKnowledgeEligibility
import ai.oriveo.community.core.model.SkillKnowledgeErrorCode
import ai.oriveo.community.core.model.SkillKnowledgeFileStatus
import ai.oriveo.community.core.model.SkillKnowledgeFile
import ai.oriveo.community.core.model.SkillKnowledgeRuntimeConfig
import ai.oriveo.community.core.util.InputSizeLimitExceededException
import ai.oriveo.community.core.util.readBytesLimited
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoSectionHeader
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.ui.theme.OriveoSpacing
import ai.oriveo.community.ui.theme.OriveoTheme
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.koin.androidx.compose.koinViewModel
import java.io.ByteArrayInputStream
import java.util.UUID

private val colorPalette = listOf(
    "#6d38ff", "#4A90D9", "#50C878", "#FF6B6B",
    "#FF9F43", "#A855F7", "#EC4899", "#06B6D4",
    "#84CC16", "#F59E0B", "#6366F1", "#14B8A6",
)

private val capabilityOptions = listOf(
    "any", "reasoning", "vision", "fast", "large-context",
)


private fun parseHexColor(hex: String): Color {
    val clean = hex.removePrefix("#")
    return try {
        Color(android.graphics.Color.parseColor("#$clean"))
    } catch (_: Exception) {
        Color(0xFF8C5FF8) // = LightOriveoColors.primary
    }
}

private enum class SkillKnowledgeCtaReason {
    NoOpenAIKey,
    OnlyOpenRouter,
    OpenAIEndpointNotOfficial,
    RetrievalModelNotEnabled,
    ServiceUnavailable,
}

private data class SkillKnowledgeCtaContent(
    val reason: SkillKnowledgeCtaReason,
    val message: String,
    val requiredModel: String? = null,
    val primaryLabel: String,
    val secondaryLabel: String,
)

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SkillEditScreen(
    skillId: String?,
    onBack: () -> Unit,
    onOpenOpenAISetup: () -> Unit,
    onOpenOpenAIProviderDetail: (String) -> Unit,
    viewModel: SkillViewModel = koinViewModel(),
) {
    val context = LocalResources.current
    val androidContext = LocalContext.current
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val layout = OriveoTheme.layout
    val typography = OriveoTheme.typography

    val fileImportScope = rememberCoroutineScope()
    val isEditing = skillId != null
    val knowledgeApi = Unit

    LaunchedEffect(skillId) {
        if (skillId != null) {
            viewModel.loadSkillForEdit(skillId)
        } else {
            viewModel.clearEditState()
        }
    }

    val existingSkill = viewModel.editingSkill

    
    var name by rememberSaveable { mutableStateOf("") }
    var description by rememberSaveable { mutableStateOf("") }
    var icon by rememberSaveable { mutableStateOf("\uD83E\uDD16") }
    var color by rememberSaveable { mutableStateOf("#6d38ff") }
    var systemPrompt by rememberSaveable { mutableStateOf("") }
    var useMemory by rememberSaveable { mutableStateOf(true) }
    var modelCapabilityHint by rememberSaveable { mutableStateOf("any") }
    val knowledgeFiles = remember { mutableStateListOf<SkillKnowledgeFile>() }
    var knowledgeBase by remember { mutableStateOf<SkillKnowledgeBase?>(null) }
    var originalKnowledgeBase by remember { mutableStateOf<SkillKnowledgeBase?>(null) }

    
    var showDiscardDialog by remember { mutableStateOf(false) }
    var showIconDialog by remember { mutableStateOf(false) }
    var iconInput by remember { mutableStateOf("") }
    var showAdvanced by rememberSaveable { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var initialized by remember { mutableStateOf(false) }
    var knowledgeRuntime by remember { mutableStateOf<SkillKnowledgeRuntimeConfig?>(null) }
    var knowledgeEligibility by remember { mutableStateOf<SkillKnowledgeEligibility?>(null) }
    var knowledgePendingId by remember { mutableStateOf<String?>(null) }
    var knowledgeReplaceTargetId by remember { mutableStateOf<String?>(null) }
    var knowledgeRefreshTick by remember { mutableStateOf(0) }
    var dismissedKnowledgeCtaReason by remember { mutableStateOf<SkillKnowledgeCtaReason?>(null) }
    val knowledgeRetryCache = remember { mutableStateMapOf<String, ai.oriveo.community.core.model.SkillKnowledgeUploadPayload>() }

    DisposableEffect(Unit) {
        onDispose {
            knowledgeRetryCache.clear()
        }
    }
    val knowledgeUsedBytes = sumKnowledgeBaseBytes(knowledgeBase)
    val knowledgeMutating = knowledgePendingId != null
    val knowledgeEligible = knowledgeEligibility?.eligible == true
    val openAIProvider by viewModel.openAIKnowledgeProvider.collectAsStateWithLifecycle()
    val hasOpenRouterProvider by viewModel.hasOpenRouterProvider.collectAsStateWithLifecycle()
    // The confirmation target is intentionally derived from the live provider instance and its
    // current model catalog; legacy Skill web/reasoning fields alone never enable anything.
    val confirmationProviders by viewModel.capabilityConfirmationProviders.collectAsStateWithLifecycle()
    val skillCapabilityTarget = existingSkill?.let(viewModel::skillCapabilityConfirmationTarget)
    var skillCapabilityConfirmed by remember(
        existingSkill?.id,
        skillCapabilityTarget?.providerID,
        skillCapabilityTarget?.modelID,
        skillCapabilityTarget?.transportIdentity,
        confirmationProviders,
    ) {
        mutableStateOf(existingSkill?.let(viewModel::isSkillCapabilityConfirmed) == true)
    }

    
    LaunchedEffect(existingSkill) {
        if (existingSkill != null && !initialized) {
            name = existingSkill.name
            description = existingSkill.description
            icon = existingSkill.icon
            color = existingSkill.color
            systemPrompt = existingSkill.systemPrompt
            useMemory = existingSkill.useMemory
            modelCapabilityHint = existingSkill.modelCapabilityHint
            knowledgeFiles.clear()
            knowledgeFiles.addAll(existingSkill.knowledgeFiles)
            knowledgeBase = existingSkill.knowledgeBase
            originalKnowledgeBase = existingSkill.knowledgeBase
            initialized = true
        } else if (existingSkill == null && skillId == null) {
            originalKnowledgeBase = null
        }
    }

    LaunchedEffect(openAIProvider?.id, openAIProvider?.apiKey, openAIProvider?.baseUrlText, openAIProvider?.models, knowledgeRefreshTick) {
        try {
            val runtime = null
            knowledgeRuntime = runtime
            val eligibility = null
            knowledgeEligibility = eligibility
            if (false) {
                dismissedKnowledgeCtaReason = null
            }
        } catch (e: Exception) {
            android.util.Log.w("SkillEdit", "Knowledge capability check failed", e)
            knowledgeRuntime = null
            knowledgeEligibility = SkillKnowledgeEligibility(
                eligible = false,
                errorCode = SkillKnowledgeErrorCode.KNOWLEDGE_SERVICE_UNAVAILABLE,
                requiredModel = null,
            )
        }
    }

    val activeIndexingFile = knowledgeBase?.files?.firstOrNull {
        it.status == SkillKnowledgeFileStatus.INDEXING && !it.openAIFileId.isNullOrBlank()
    }
    val knowledgeIndexingRefreshKey = if (
        openAIProvider == null ||
        knowledgeBase == null ||
        knowledgeBase?.vectorStoreId.isNullOrBlank() ||
        activeIndexingFile == null
    ) {
        "no-indexing"
    } else {
        listOf(
            openAIProvider?.id.orEmpty(),
            openAIProvider?.apiKey.orEmpty(),
            openAIProvider?.baseUrlText.orEmpty(),
            knowledgeBase?.vectorStoreId.orEmpty(),
            activeIndexingFile.id,
            activeIndexingFile.openAIFileId.orEmpty(),
        ).joinToString("|")
    }

    fun applyKnowledgeIndexingStatus(fileId: String, status: SkillKnowledgeFileStatus) {
        val currentKnowledgeBase = knowledgeBase ?: return
        val updatedAt = java.time.Instant.now().toString()
        knowledgeBase = currentKnowledgeBase.copy(
            files = currentKnowledgeBase.files.map { file ->
                if (file.id == fileId) {
                    file.copy(
                        status = status,
                        errorCode = if (status == SkillKnowledgeFileStatus.FAILED) {
                            SkillKnowledgeErrorCode.KNOWLEDGE_INDEX_FAILED
                        } else {
                            null
                        },
                        updatedAt = updatedAt,
                    )
                } else {
                    file
                }
            },
            updatedAt = updatedAt,
        )
    }

    LaunchedEffect(knowledgeIndexingRefreshKey) {
        val provider = openAIProvider ?: return@LaunchedEffect
        val currentKnowledgeBase = knowledgeBase ?: return@LaunchedEffect
        val indexingFile = activeIndexingFile ?: return@LaunchedEffect
        val openAIFileId = indexingFile.openAIFileId ?: return@LaunchedEffect
        if (currentKnowledgeBase.vectorStoreId.isBlank()) return@LaunchedEffect

        repeat(30) {
            delay(3_000)
            if (!isActive) return@LaunchedEffect

            val status = try {
                null
            } catch (error: Exception) {
                errorMessage = error.message
                return@LaunchedEffect
            } ?: return@repeat

            if (status == SkillKnowledgeFileStatus.READY || status == SkillKnowledgeFileStatus.FAILED) {
                applyKnowledgeIndexingStatus(indexingFile.id, status)
                return@LaunchedEffect
            }
        }

        if (isActive) {
            applyKnowledgeIndexingStatus(indexingFile.id, SkillKnowledgeFileStatus.FAILED)
        }
    }

    
    
    val hasChanges by remember {
        derivedStateOf {
            if (existingSkill != null) {
                name != existingSkill.name
                    || description != existingSkill.description
                    || icon != existingSkill.icon
                    || color != existingSkill.color
                    || systemPrompt != existingSkill.systemPrompt
                    || knowledgeFiles.toList() != existingSkill.knowledgeFiles
                    || knowledgeBase.normalizeForComparison() != originalKnowledgeBase.normalizeForComparison()
                    || useMemory != existingSkill.useMemory
                    || modelCapabilityHint != existingSkill.modelCapabilityHint
            } else {
                name.isNotBlank() || systemPrompt.isNotBlank() || knowledgeBase != null
            }
        }
    }

    val canSave = name.isNotBlank()
            && systemPrompt.isNotBlank()
            && systemPrompt.length <= 4000
            && !viewModel.isSaving
            && !knowledgeMutating

    fun buildKnowledgeCleanupInput(providerApiKey: String, providerBaseUrl: String?): KnowledgeCleanupInput =
        KnowledgeCleanupInput(
            apiKey = providerApiKey,
            baseURL = providerBaseUrl?.takeIf { it.isNotBlank() },
        )

    fun decodeKnowledgeErrorCode(value: String?): SkillKnowledgeErrorCode? = when (value?.trim()) {
        "openai_not_configured" -> SkillKnowledgeErrorCode.OPENAI_NOT_CONFIGURED
        "openai_endpoint_not_official" -> SkillKnowledgeErrorCode.OPENAI_ENDPOINT_NOT_OFFICIAL
        "retrieval_model_not_enabled" -> SkillKnowledgeErrorCode.RETRIEVAL_MODEL_NOT_ENABLED
        "knowledge_service_unavailable" -> SkillKnowledgeErrorCode.KNOWLEDGE_SERVICE_UNAVAILABLE
        "unsupported_file_type" -> SkillKnowledgeErrorCode.UNSUPPORTED_FILE_TYPE
        "reference_file_too_large" -> SkillKnowledgeErrorCode.REFERENCE_FILE_TOO_LARGE
        "reference_file_char_limit_exceeded" -> SkillKnowledgeErrorCode.REFERENCE_FILE_CHAR_LIMIT_EXCEEDED
        "knowledge_file_too_large" -> SkillKnowledgeErrorCode.KNOWLEDGE_FILE_TOO_LARGE
        "knowledge_total_size_exceeded" -> SkillKnowledgeErrorCode.KNOWLEDGE_TOTAL_SIZE_EXCEEDED
        "knowledge_extract_failed" -> SkillKnowledgeErrorCode.KNOWLEDGE_EXTRACT_FAILED
        "knowledge_upload_failed" -> SkillKnowledgeErrorCode.KNOWLEDGE_UPLOAD_FAILED
        "knowledge_index_failed" -> SkillKnowledgeErrorCode.KNOWLEDGE_INDEX_FAILED
        "knowledge_retrieve_failed" -> SkillKnowledgeErrorCode.KNOWLEDGE_RETRIEVE_FAILED
        "knowledge_cleanup_failed" -> SkillKnowledgeErrorCode.KNOWLEDGE_CLEANUP_FAILED
        else -> null
    }

    fun resolveKnowledgeErrorCode(error: Throwable, fallback: SkillKnowledgeErrorCode): SkillKnowledgeErrorCode {
        val direct = decodeKnowledgeErrorCode(error.message)
        if (direct != null) return direct
        val body = error.message
        return body
            ?.split('"', '{', '}', ',', ' ', '\n', '\r', '\t', ':')
            ?.mapNotNull(::decodeKnowledgeErrorCode)
            ?.firstOrNull()
            ?: fallback
    }

    fun localizedGuardError(error: Throwable): String? = null

    fun localizedKnowledgeError(
        code: SkillKnowledgeErrorCode,
        requiredModel: String? = null,
    ): String = when (code) {
        SkillKnowledgeErrorCode.OPENAI_NOT_CONFIGURED -> context.getString(R.string.skills_knowledgeErrorOpenAI)
        SkillKnowledgeErrorCode.OPENAI_ENDPOINT_NOT_OFFICIAL -> context.getString(R.string.skills_knowledgeErrorEndpoint)
        SkillKnowledgeErrorCode.RETRIEVAL_MODEL_NOT_ENABLED -> context.getString(
            R.string.skills_knowledgeErrorModelDisabled,
            requiredModel ?: knowledgeRuntime?.retrievalModel.orEmpty(),
        )
        SkillKnowledgeErrorCode.KNOWLEDGE_SERVICE_UNAVAILABLE -> context.getString(R.string.skills_knowledgeErrorServiceUnavailable)
        SkillKnowledgeErrorCode.UNSUPPORTED_FILE_TYPE -> context.getString(R.string.skills_knowledgeErrorUnsupportedType)
        SkillKnowledgeErrorCode.REFERENCE_FILE_TOO_LARGE -> context.getString(R.string.skills_fileTooLarge)
        SkillKnowledgeErrorCode.REFERENCE_FILE_CHAR_LIMIT_EXCEEDED -> context.getString(R.string.skills_fileTooLarge)
        SkillKnowledgeErrorCode.KNOWLEDGE_FILE_TOO_LARGE -> context.getString(R.string.skills_knowledgeErrorFileTooLarge)
        SkillKnowledgeErrorCode.KNOWLEDGE_TOTAL_SIZE_EXCEEDED -> context.getString(R.string.skills_knowledgeErrorQuotaExceeded)
        SkillKnowledgeErrorCode.KNOWLEDGE_EXTRACT_FAILED -> context.getString(R.string.skills_knowledgeErrorExtractFailed)
        SkillKnowledgeErrorCode.KNOWLEDGE_UPLOAD_FAILED -> context.getString(R.string.skills_knowledgeErrorUploadFailed)
        SkillKnowledgeErrorCode.KNOWLEDGE_INDEX_FAILED -> context.getString(R.string.skills_knowledgeErrorIndexFailed)
        SkillKnowledgeErrorCode.KNOWLEDGE_RETRIEVE_FAILED -> context.getString(R.string.skills_knowledgeErrorRetrieveFailed)
        SkillKnowledgeErrorCode.KNOWLEDGE_CLEANUP_FAILED -> context.getString(R.string.skills_knowledgeErrorCleanupFailed)
    }

    fun localizedKnowledgeStatus(status: SkillKnowledgeFileStatus): String = when (status) {
        SkillKnowledgeFileStatus.EXTRACTING,
        SkillKnowledgeFileStatus.UPLOADING -> context.getString(R.string.skills_knowledgeStatusUploading)
        SkillKnowledgeFileStatus.INDEXING -> context.getString(R.string.skills_knowledgeStatusIndexing)
        SkillKnowledgeFileStatus.READY -> context.getString(R.string.skills_knowledgeStatusReady)
        SkillKnowledgeFileStatus.FAILED -> context.getString(R.string.skills_knowledgeStatusFailed)
        SkillKnowledgeFileStatus.REPLACING -> context.getString(R.string.skills_knowledgeStatusReplacing)
        SkillKnowledgeFileStatus.DELETING -> context.getString(R.string.skills_knowledgeStatusDeleting)
        SkillKnowledgeFileStatus.DISABLED -> context.getString(R.string.skills_knowledgeStatusUnavailable)
    }

    fun displayKnowledgeStatus(file: SkillKnowledgeBaseFile): SkillKnowledgeFileStatus =
        if (file.status == SkillKnowledgeFileStatus.READY && !knowledgeEligible) {
            SkillKnowledgeFileStatus.DISABLED
        } else {
            file.status
        }

    suspend fun cleanupDraftKnowledgeResources(): Boolean {
        val plan = buildDraftKnowledgeCleanupPlan(
            originalKnowledgeBase = originalKnowledgeBase,
            currentKnowledgeBase = knowledgeBase,
        ) ?: return true
        val provider = openAIProvider
        if (provider == null) {
            errorMessage = localizedKnowledgeError(SkillKnowledgeErrorCode.OPENAI_NOT_CONFIGURED)
            return false
        }

        return try {
            null
            true
        } catch (error: Exception) {
            errorMessage = localizedGuardError(error) ?: localizedKnowledgeError(
                resolveKnowledgeErrorCode(error, SkillKnowledgeErrorCode.KNOWLEDGE_CLEANUP_FAILED),
            )
            false
        }
    }

    
    suspend fun inspectImportedFile(uri: Uri): ImportedFileMetadata = withContext(Dispatchers.IO) {
        val contentResolver = androidContext.contentResolver
        val (displayName, declaredSize) = contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val nameIndex = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            val sizeIndex = cursor.getColumnIndex(android.provider.OpenableColumns.SIZE)
            if (!cursor.moveToFirst()) {
                "file" to null
            } else {
                val name = if (nameIndex >= 0) cursor.getString(nameIndex) else "file"
                val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else null
                name to size
            }
        } ?: ("file" to null)
        ImportedFileMetadata(
            fileName = displayName,
            mimeType = contentResolver.getType(uri) ?: "application/octet-stream",
            declaredSizeBytes = declaredSize,
        )
    }

    suspend fun loadImportedFileSource(uri: Uri, maxBytes: Long): ImportedFileSource = withContext(Dispatchers.IO) {
        val metadata = inspectImportedFile(uri)
        val bytes = androidContext.contentResolver.openInputStream(uri)?.use {
            it.readBytesLimited(maxBytes)
        } ?: byteArrayOf()
        ImportedFileSource(
            bytes = bytes,
            fileName = metadata.fileName,
            mimeType = metadata.mimeType,
            sizeBytes = resolveImportedFileSize(
                metadataSizeBytes = metadata.declaredSizeBytes,
                fallbackSizeBytes = bytes.size.toLong(),
            ),
        )
    }

    val knowledgeEligibilityHint = when {
        knowledgeEligibility == null ->
            context.getString(R.string.skills_knowledgeEligibilityReady)
        knowledgeEligible ->
            context.getString(R.string.skills_knowledgeEligibilityReady)
        else ->
            localizedKnowledgeError(
                knowledgeEligibility?.errorCode ?: SkillKnowledgeErrorCode.KNOWLEDGE_SERVICE_UNAVAILABLE,
                knowledgeEligibility?.requiredModel,
            )
    }
    val requiredKnowledgeModel = knowledgeEligibility?.requiredModel ?: knowledgeRuntime?.retrievalModel
    val currentKnowledgeCtaReason = when {
        knowledgeEligibility == null || knowledgeEligibility?.eligible == true -> null
        knowledgeEligibility?.errorCode == SkillKnowledgeErrorCode.OPENAI_NOT_CONFIGURED && hasOpenRouterProvider && openAIProvider == null ->
            SkillKnowledgeCtaReason.OnlyOpenRouter
        knowledgeEligibility?.errorCode == SkillKnowledgeErrorCode.OPENAI_NOT_CONFIGURED ->
            SkillKnowledgeCtaReason.NoOpenAIKey
        knowledgeEligibility?.errorCode == SkillKnowledgeErrorCode.OPENAI_ENDPOINT_NOT_OFFICIAL ->
            SkillKnowledgeCtaReason.OpenAIEndpointNotOfficial
        knowledgeEligibility?.errorCode == SkillKnowledgeErrorCode.RETRIEVAL_MODEL_NOT_ENABLED ->
            SkillKnowledgeCtaReason.RetrievalModelNotEnabled
        else ->
            SkillKnowledgeCtaReason.ServiceUnavailable
    }
    val knowledgeCta = when (currentKnowledgeCtaReason) {
        SkillKnowledgeCtaReason.NoOpenAIKey -> SkillKnowledgeCtaContent(
            reason = SkillKnowledgeCtaReason.NoOpenAIKey,
            message = context.getString(R.string.skills_knowledgeCtaOpenAIRequired),
            primaryLabel = context.getString(R.string.skills_knowledgeCtaConfigureOpenAI),
            secondaryLabel = context.getString(R.string.skills_knowledgeCtaNotNow),
        )
        SkillKnowledgeCtaReason.OnlyOpenRouter -> SkillKnowledgeCtaContent(
            reason = SkillKnowledgeCtaReason.OnlyOpenRouter,
            message = context.getString(R.string.skills_knowledgeCtaOpenRouterOnly),
            primaryLabel = context.getString(R.string.skills_knowledgeCtaAddOpenAIKey),
            secondaryLabel = context.getString(R.string.skills_knowledgeCtaNotNow),
        )
        SkillKnowledgeCtaReason.OpenAIEndpointNotOfficial -> SkillKnowledgeCtaContent(
            reason = SkillKnowledgeCtaReason.OpenAIEndpointNotOfficial,
            message = context.getString(R.string.skills_knowledgeCtaEndpointNotOfficial),
            primaryLabel = context.getString(R.string.skills_knowledgeCtaCheckOpenAIConfiguration),
            secondaryLabel = context.getString(R.string.skills_knowledgeCtaNotNow),
        )
        SkillKnowledgeCtaReason.RetrievalModelNotEnabled -> SkillKnowledgeCtaContent(
            reason = SkillKnowledgeCtaReason.RetrievalModelNotEnabled,
            message = context.getString(R.string.skills_knowledgeCtaRetrievalModel),
            requiredModel = requiredKnowledgeModel,
            primaryLabel = context.getString(R.string.skills_knowledgeCtaAddModel),
            secondaryLabel = context.getString(R.string.skills_knowledgeCtaNotNow),
        )
        SkillKnowledgeCtaReason.ServiceUnavailable -> SkillKnowledgeCtaContent(
            reason = SkillKnowledgeCtaReason.ServiceUnavailable,
            message = context.getString(R.string.skills_knowledgeCtaServiceUnavailable),
            primaryLabel = context.getString(R.string.skills_knowledgeCtaTryAgain),
            secondaryLabel = context.getString(R.string.skills_knowledgeCtaContinueEditingSkill),
        )
        null -> null
    }
    val shouldShowKnowledgeCta = knowledgeCta != null && dismissedKnowledgeCtaReason != knowledgeCta.reason

    fun knowledgeFileSubtitle(file: SkillKnowledgeBaseFile): String {
        val parts = mutableListOf(
            formatKnowledgeBytes(file.sizeBytes),
            localizedKnowledgeStatus(displayKnowledgeStatus(file)),
        )
        file.errorCode?.let { parts += localizedKnowledgeError(it) }
        return parts.joinToString(" · ")
    }

    suspend fun startKnowledgeUpload(source: ImportedFileSource, replacing: String?) {
        errorMessage = null
        val runtime = knowledgeRuntime
        if (runtime == null) {
            errorMessage = localizedKnowledgeError(SkillKnowledgeErrorCode.KNOWLEDGE_SERVICE_UNAVAILABLE)
            return
        }
        val provider = openAIProvider
        if (provider == null) {
            errorMessage = localizedKnowledgeError(SkillKnowledgeErrorCode.OPENAI_NOT_CONFIGURED)
            return
        }
        if (!isKnowledgeFileTypeSupported(source.fileName, source.mimeType, runtime.supportedFileTypes)) {
            errorMessage = localizedKnowledgeError(SkillKnowledgeErrorCode.UNSUPPORTED_FILE_TYPE)
            return
        }

        val targetFile = replacing?.let { targetId ->
            knowledgeBase?.files?.firstOrNull { it.id == targetId }
        }
        val previousKnowledgeBase = knowledgeBase
        val originalOpenAIFileIds = originalKnowledgeBase
            ?.files
            ?.mapNotNull { it.openAIFileId?.trim()?.takeIf(String::isNotEmpty) }
            ?.toSet()
            ?: emptySet()
        val targetIsPersistedRemoteFile = targetFile?.openAIFileId?.let { it in originalOpenAIFileIds } == true
        val existingBytes = maxOf(0L, knowledgeUsedBytes - (targetFile?.sizeBytes ?: 0L))
        val existingCount = maxOf(0, (knowledgeBase?.files?.size ?: 0) - if (targetFile == null) 0 else 1)
        validateKnowledgeBaseQuota(
            existingCount = existingCount,
            existingBytes = existingBytes,
            nextFileBytes = source.sizeBytes,
        )?.let { quotaError ->
            errorMessage = localizedKnowledgeError(quotaError)
            return
        }

        val payload = buildKnowledgeUploadPayload(
            data = source.bytes,
            fileName = source.fileName,
            mimeType = source.mimeType,
            sizeBytes = source.sizeBytes,
        )
        val localFileId = targetFile?.id ?: UUID.randomUUID().toString()
        knowledgeRetryCache[localFileId] = payload
        knowledgePendingId = localFileId
        knowledgeBase = upsertKnowledgeBase(
            knowledgeBase = knowledgeBase,
            provider = runtime.provider,
            retrievalModel = runtime.retrievalModel,
            expiresAfterDays = runtime.expiresAfterDays,
            vectorStoreId = knowledgeBase?.vectorStoreId,
            file = buildLocalKnowledgeBaseFile(
                id = localFileId,
                name = payload.displayName,
                mimeType = payload.displayMimeType,
                sizeBytes = payload.displaySizeBytes,
                ingestionMode = payload.ingestionMode,
                extractedFrom = payload.extractedFrom,
                status = if (targetFile == null) SkillKnowledgeFileStatus.UPLOADING else SkillKnowledgeFileStatus.REPLACING,
                createdAt = targetFile?.createdAt,
            ),
        )

        try {
            val nextKnowledgeBase = if (targetFile != null) {
                if (targetIsPersistedRemoteFile) {
                    null
                } else {
                    null
                }
            } else {
                null
            }
            knowledgeBase = nextKnowledgeBase
            knowledgeRetryCache.remove(localFileId)
        } catch (error: Exception) {
            val errorCode = resolveKnowledgeErrorCode(
                error = error,
                fallback = SkillKnowledgeErrorCode.KNOWLEDGE_UPLOAD_FAILED,
            )
            knowledgeBase = if (targetFile != null && targetIsPersistedRemoteFile) {
                previousKnowledgeBase
            } else if (targetFile != null) {
                upsertKnowledgeBase(
                    knowledgeBase = knowledgeBase,
                    provider = runtime.provider,
                    retrievalModel = runtime.retrievalModel,
                    expiresAfterDays = runtime.expiresAfterDays,
                    vectorStoreId = knowledgeBase?.vectorStoreId,
                    file = buildLocalKnowledgeBaseFile(
                        id = targetFile.id,
                        name = payload.displayName,
                        mimeType = payload.displayMimeType,
                        sizeBytes = payload.displaySizeBytes,
                        ingestionMode = payload.ingestionMode,
                        extractedFrom = payload.extractedFrom,
                        openAIFileId = targetFile.openAIFileId,
                        status = SkillKnowledgeFileStatus.FAILED,
                        errorCode = errorCode,
                        createdAt = targetFile.createdAt,
                    ),
                )
            } else {
                upsertKnowledgeBase(
                    knowledgeBase = knowledgeBase,
                    provider = runtime.provider,
                    retrievalModel = runtime.retrievalModel,
                    expiresAfterDays = runtime.expiresAfterDays,
                    vectorStoreId = knowledgeBase?.vectorStoreId,
                    file = buildLocalKnowledgeBaseFile(
                        id = localFileId,
                        name = payload.displayName,
                        mimeType = payload.displayMimeType,
                        sizeBytes = payload.displaySizeBytes,
                        ingestionMode = payload.ingestionMode,
                        extractedFrom = payload.extractedFrom,
                        status = SkillKnowledgeFileStatus.FAILED,
                        errorCode = errorCode,
                    ),
                )
            }
            errorMessage = localizedGuardError(error) ?: localizedKnowledgeError(errorCode)
        } finally {
            knowledgePendingId = null
            knowledgeReplaceTargetId = null
        }
    }

    suspend fun retryKnowledgeFile(file: SkillKnowledgeBaseFile) {
        val payload = knowledgeRetryCache[file.id]
        if (payload == null) {
            errorMessage = context.getString(R.string.skills_knowledgeRetryUnavailable)
            return
        }
        val runtime = knowledgeRuntime
        if (runtime == null) {
            errorMessage = localizedKnowledgeError(SkillKnowledgeErrorCode.KNOWLEDGE_SERVICE_UNAVAILABLE)
            return
        }
        val provider = openAIProvider
        if (provider == null) {
            errorMessage = localizedKnowledgeError(SkillKnowledgeErrorCode.OPENAI_NOT_CONFIGURED)
            return
        }

        knowledgePendingId = file.id
        knowledgeBase = upsertKnowledgeBase(
            knowledgeBase = knowledgeBase,
            provider = runtime.provider,
            retrievalModel = runtime.retrievalModel,
            expiresAfterDays = runtime.expiresAfterDays,
            vectorStoreId = knowledgeBase?.vectorStoreId,
            file = buildLocalKnowledgeBaseFile(
                id = file.id,
                name = payload.displayName,
                mimeType = payload.displayMimeType,
                sizeBytes = payload.displaySizeBytes,
                ingestionMode = payload.ingestionMode,
                extractedFrom = payload.extractedFrom,
                openAIFileId = file.openAIFileId,
                status = SkillKnowledgeFileStatus.UPLOADING,
                createdAt = file.createdAt,
            ),
        )

        try {
            val nextKnowledgeBase = null
            knowledgeBase = nextKnowledgeBase
            knowledgeRetryCache.remove(file.id)
        } catch (error: Exception) {
            val errorCode = resolveKnowledgeErrorCode(
                error = error,
                fallback = SkillKnowledgeErrorCode.KNOWLEDGE_UPLOAD_FAILED,
            )
            knowledgeBase = upsertKnowledgeBase(
                knowledgeBase = knowledgeBase,
                provider = runtime.provider,
                retrievalModel = runtime.retrievalModel,
                expiresAfterDays = runtime.expiresAfterDays,
                vectorStoreId = knowledgeBase?.vectorStoreId,
                file = buildLocalKnowledgeBaseFile(
                    id = file.id,
                    name = payload.displayName,
                    mimeType = payload.displayMimeType,
                    sizeBytes = payload.displaySizeBytes,
                    ingestionMode = payload.ingestionMode,
                    extractedFrom = payload.extractedFrom,
                    status = SkillKnowledgeFileStatus.FAILED,
                    errorCode = errorCode,
                    createdAt = file.createdAt,
                ),
            )
            errorMessage = localizedGuardError(error) ?: localizedKnowledgeError(errorCode)
        } finally {
            knowledgePendingId = null
        }
    }

    suspend fun deleteKnowledgeFile(file: SkillKnowledgeBaseFile) {
        val previousKnowledgeBase = knowledgeBase
        val originalOpenAIFileIds = originalKnowledgeBase
            ?.files
            ?.mapNotNull { it.openAIFileId?.trim()?.takeIf(String::isNotEmpty) }
            ?.toSet()
            ?: emptySet()
        val isPersistedRemoteFile = file.openAIFileId?.let { it in originalOpenAIFileIds } == true
        val hasRemoteDraftResource = !file.openAIFileId.isNullOrBlank() && !isPersistedRemoteFile
        knowledgePendingId = file.id

        if (hasRemoteDraftResource && previousKnowledgeBase != null) {
            knowledgeBase = upsertKnowledgeBase(
                knowledgeBase = previousKnowledgeBase,
                provider = previousKnowledgeBase.provider,
                retrievalModel = previousKnowledgeBase.retrievalModel,
                expiresAfterDays = previousKnowledgeBase.expiresAfterDays,
                vectorStoreId = previousKnowledgeBase.vectorStoreId,
                file = file.copy(
                    status = SkillKnowledgeFileStatus.DELETING,
                ),
            )
        }

        try {
            val provider = openAIProvider
            knowledgeBase = if (previousKnowledgeBase != null && hasRemoteDraftResource) {
                if (provider == null) {
                    throw IllegalStateException("openai_not_configured")
                }
                null
                removeKnowledgeBaseFile(previousKnowledgeBase, file.id)
            } else {
                removeKnowledgeBaseFile(previousKnowledgeBase, file.id)
            }
            knowledgeRetryCache.remove(file.id)
        } catch (error: Exception) {
            knowledgeBase = previousKnowledgeBase
            errorMessage = localizedGuardError(error) ?: localizedKnowledgeError(
                resolveKnowledgeErrorCode(
                    error = error,
                    fallback = SkillKnowledgeErrorCode.KNOWLEDGE_CLEANUP_FAILED,
                ),
            )
        } finally {
            knowledgePendingId = null
        }
    }

    val referenceFilePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        fileImportScope.launch {
            try {
                
                
                val metadata = inspectImportedFile(uri)
                metadata.declaredSizeBytes?.let { declaredSize ->
                    validateReferenceFileSize(declaredSize)?.let { sizeError ->
                        errorMessage = localizedKnowledgeError(sizeError)
                        return@launch
                    }
                }
                val source = try {
                    loadImportedFileSource(uri, MAX_REFERENCE_FILE_SIZE_BYTES)
                } catch (_: InputSizeLimitExceededException) {
                    errorMessage = localizedKnowledgeError(SkillKnowledgeErrorCode.REFERENCE_FILE_TOO_LARGE)
                    return@launch
                }
                validateReferenceFileSize(source.sizeBytes)?.let { sizeError ->
                    errorMessage = localizedKnowledgeError(sizeError)
                    return@launch
                }

                val ext = source.fileName.substringAfterLast('.', "").lowercase()
                val isPdf = source.mimeType == "application/pdf" || ext == "pdf"
                val isOffice = ai.oriveo.community.core.attachments.extractors.OfficeTextExtractor.isOfficeFile(ext)
                val content = withContext(Dispatchers.IO) {
                    when {
                        isPdf -> {
                            PDFBoxResourceLoader.init(androidContext)
                            PDDocument.load(ByteArrayInputStream(source.bytes)).use { document ->
                                PDFTextStripper().getText(document)
                            }
                        }
                        isOffice -> {
                            ai.oriveo.community.core.attachments.extractors.OfficeTextExtractor.extractText(source.bytes, ext)
                                ?: throw IllegalStateException(context.getString(R.string.skills_knowledgeImportFailed))
                        }
                        else -> source.bytes.toString(Charsets.UTF_8)
                    }
                }
                if (content.trim().isEmpty()) {
                    errorMessage = context.getString(R.string.skills_knowledgeImportEmpty)
                    return@launch
                }

                knowledgeFiles += buildReferenceKnowledgeFile(
                    name = source.fileName,
                    mimeType = source.mimeType,
                    sourceType = if (isPdf) {
                        ai.oriveo.community.core.model.SkillKnowledgeSourceType.PDF_TEXT
                    } else {
                        ai.oriveo.community.core.model.SkillKnowledgeSourceType.TEXT
                    },
                    content = content,
                )
                errorMessage = null
            } catch (error: Exception) {
                android.util.Log.w("SkillEdit", "Reference file import failed", error)
                errorMessage = error.message ?: context.getString(R.string.skills_knowledgeImportFailed)
            }
        }
    }

    val knowledgeFilePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri: Uri? ->
        if (uri == null) {
            knowledgeReplaceTargetId = null
            return@rememberLauncherForActivityResult
        }
        fileImportScope.launch {
            try {
                
                
                
                val metadata = inspectImportedFile(uri)
                metadata.declaredSizeBytes?.let { declaredSize ->
                    val existing = knowledgeBase?.files
                    val quotaError = validateKnowledgeBaseQuota(
                        existingCount = existing?.size ?: 0,
                        existingBytes = existing?.sumOf { it.sizeBytes } ?: 0L,
                        nextFileBytes = declaredSize,
                    )
                    if (quotaError != null) {
                        knowledgeReplaceTargetId = null
                        errorMessage = localizedKnowledgeError(quotaError)
                        return@launch
                    }
                }
                val source = try {
                    loadImportedFileSource(uri, MAX_KNOWLEDGE_FILE_SIZE_BYTES)
                } catch (_: InputSizeLimitExceededException) {
                    knowledgeReplaceTargetId = null
                    errorMessage = localizedKnowledgeError(SkillKnowledgeErrorCode.KNOWLEDGE_FILE_TOO_LARGE)
                    return@launch
                }
                startKnowledgeUpload(
                    source = source,
                    replacing = knowledgeReplaceTargetId,
                )
            } catch (error: Exception) {
                knowledgeReplaceTargetId = null
                errorMessage = error.message ?: context.getString(R.string.skills_knowledgeImportFailed)
            }
        }
    }

    
    fun save() {
        errorMessage = null
        if (skillId != null) {
            val knowledgeCleanup = if (requiresRemoteKnowledgeCleanup(
                    originalKnowledgeBase = originalKnowledgeBase,
                    currentKnowledgeBase = knowledgeBase,
                )) {
                val provider = openAIProvider
                if (provider == null) {
                    errorMessage = localizedKnowledgeError(SkillKnowledgeErrorCode.OPENAI_NOT_CONFIGURED)
                    return
                }
                buildKnowledgeCleanupInput(
                    providerApiKey = provider.apiKey,
                    providerBaseUrl = provider.baseUrlText,
                )
            } else {
                null
            }
            viewModel.updateSkill(
                id = skillId,
                name = name.trim(),
                description = description.trim(),
                icon = icon,
                color = color,
                systemPrompt = systemPrompt,
                
                
                suggestedProviderId = existingSkill?.suggestedProviderId,
                suggestedModelId = existingSkill?.suggestedModelId,
                modelCapabilityHint = modelCapabilityHint,
                temperature = existingSkill?.temperature,
                reasoningLevel = existingSkill?.reasoningLevel,
                webSearchEnabled = existingSkill?.webSearchEnabled,
                starterMessages = emptyList(),
                knowledgeFiles = knowledgeFiles.toList(),
                knowledgeBase = knowledgeBase,
                knowledgeCleanup = knowledgeCleanup,
                useMemory = useMemory,
                onSuccess = { onBack() },
                onError = {
                    errorMessage = decodeKnowledgeErrorCode(it)?.let(::localizedKnowledgeError) ?: it
                },
            )
        } else {
            viewModel.createSkill(
                name = name.trim(),
                description = description.trim(),
                icon = icon,
                color = color,
                systemPrompt = systemPrompt,
                suggestedProviderId = null,
                suggestedModelId = null,
                modelCapabilityHint = modelCapabilityHint,
                temperature = null,
                reasoningLevel = null,
                webSearchEnabled = null,
                starterMessages = emptyList(),
                knowledgeFiles = knowledgeFiles.toList(),
                knowledgeBase = knowledgeBase,
                useMemory = useMemory,
                onSuccess = { onBack() },
                onError = { errorMessage = it },
            )
        }
    }

    BackHandler(enabled = hasChanges) {
        showDiscardDialog = true
    }

    val skillColor = parseHexColor(color)

    Box(modifier = Modifier.fillMaxSize()) {
        OriveoScreenBackground()

        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            text = stringResource(
                                if (isEditing) R.string.skills_editSkill
                                else R.string.skills_newSkill
                            ),
                            style = typography.title2,
                            color = colors.textPrimary,
                        )
                    },
                    navigationIcon = {
                        IconButton(onClick = {
                            if (hasChanges) showDiscardDialog = true else onBack()
                        }) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = stringResource(R.string.back),
                                tint = colors.textPrimary,
                            )
                        }
                    },
                    actions = {
                        
                        if (viewModel.isSaving) {
                            CircularProgressIndicator(
                                modifier = Modifier
                                    .size(20.dp)
                                    .padding(end = spacing.sm),
                                strokeWidth = 2.dp,
                                color = colors.primary,
                            )
                        } else {
                            TextButton(
                                onClick = { save() },
                                enabled = canSave,
                            ) {
                                Text(
                                    text = stringResource(R.string.save),
                                    style = typography.title3,
                                    color = if (canSave) colors.primary else colors.textTertiary,
                                )
                            }
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
                )
            },
        ) { padding ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = layout.screenH),
                verticalArrangement = Arrangement.spacedBy(layout.sectionGap),
            ) {
                // ── Error Banner ──
                val err = errorMessage ?: viewModel.saveError
                if (err != null) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(
                                color = colors.danger.copy(alpha = 0.08f),
                                shape = RoundedCornerShape(12.dp),
                            )
                            .border(
                                width = 1.dp,
                                color = colors.danger.copy(alpha = 0.15f),
                                shape = RoundedCornerShape(12.dp),
                            )
                            .padding(horizontal = spacing.lg, vertical = spacing.md),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(spacing.sm),
                    ) {
                        Icon(
                            Icons.Filled.Warning,
                            contentDescription = null,
                            modifier = Modifier.size(14.dp),
                            tint = colors.danger,
                        )
                        Text(
                            text = err,
                            style = typography.caption,
                            color = colors.danger,
                        )
                    }
                }

                // ── Hero Section ──
                OriveoCard(contentPadding = PaddingValues(spacing.s20)) {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(spacing.s20),
                    ) {
                        
                        Box(
                            modifier = Modifier.size(104.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            
                            Box(
                                modifier = Modifier
                                    .size(104.dp)
                                    .background(
                                        color = skillColor.copy(alpha = 0.06f),
                                        shape = RoundedCornerShape(28.dp),
                                    ),
                            )
                            
                            Box(
                                modifier = Modifier
                                    .size(80.dp)
                                    .shadow(
                                        elevation = 10.dp,
                                        shape = RoundedCornerShape(22.dp),
                                        spotColor = skillColor.copy(alpha = 0.25f),
                                    )
                                    .background(
                                        color = skillColor.copy(alpha = 0.14f),
                                        shape = RoundedCornerShape(22.dp),
                                    )
                                    .border(
                                        width = 1.5.dp,
                                        color = skillColor.copy(alpha = 0.22f),
                                        shape = RoundedCornerShape(22.dp),
                                    )
                                    .clip(RoundedCornerShape(22.dp))
                                    .clickable {
                                        iconInput = icon
                                        showIconDialog = true
                                    },
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(text = icon, fontSize = 44.sp)
                            }
                        }

                        
                        Column(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(spacing.sm),
                        ) {
                            
                            BasicTextField(
                                value = name,
                                onValueChange = { if (it.length <= 50) name = it },
                                textStyle = typography.title2.copy(
                                    color = colors.textPrimary,
                                    textAlign = TextAlign.Center,
                                ),
                                singleLine = true,
                                cursorBrush = SolidColor(colors.primary),
                                decorationBox = { inner ->
                                    Box(
                                        modifier = Modifier.fillMaxWidth(),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        if (name.isEmpty()) {
                                            Text(
                                                text = stringResource(R.string.skills_skillName),
                                                style = typography.title2,
                                                color = colors.textTertiary,
                                                textAlign = TextAlign.Center,
                                            )
                                        }
                                        inner()
                                    }
                                },
                            )
                            
                            BasicTextField(
                                value = description,
                                onValueChange = { if (it.length <= 100) description = it },
                                textStyle = typography.body.copy(
                                    color = colors.textSecondary,
                                    textAlign = TextAlign.Center,
                                ),
                                singleLine = true,
                                cursorBrush = SolidColor(colors.primary),
                                decorationBox = { inner ->
                                    Box(
                                        modifier = Modifier.fillMaxWidth(),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        if (description.isEmpty()) {
                                            Text(
                                                text = stringResource(R.string.skills_briefDescription),
                                                style = typography.body,
                                                color = colors.textTertiary,
                                                textAlign = TextAlign.Center,
                                            )
                                        }
                                        inner()
                                    }
                                },
                            )
                        }

                        
                        HorizontalDivider(
                            color = colors.border.opacity(0.5f),
                            modifier = Modifier.padding(horizontal = spacing.lg),
                        )

                        
                        FlowRow(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(spacing.md, Alignment.CenterHorizontally),
                            verticalArrangement = Arrangement.spacedBy(spacing.md),
                            maxItemsInEachRow = 6,
                        ) {
                            colorPalette.forEach { hex ->
                                val c = parseHexColor(hex)
                                val isSelected = hex == color
                                Box(
                                    modifier = Modifier
                                        .size(32.dp)
                                        .background(color = c, shape = CircleShape)
                                        .then(
                                            if (isSelected) Modifier.border(
                                                width = 2.5.dp,
                                                color = colors.textPrimary,
                                                shape = CircleShape,
                                            ) else Modifier
                                        )
                                        .clip(CircleShape)
                                        .clickable { color = hex },
                                )
                            }
                        }
                    }
                }

                // ── Instructions Section ──
                Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                    SectionLabel(
                        text = stringResource(R.string.skills_instructions),
                        tooltip = stringResource(R.string.skills_tipInstructions),
                    )

                    OriveoCard {
                        Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                            TextField(
                                value = systemPrompt,
                                onValueChange = { if (it.length <= 4000) systemPrompt = it },
                                placeholder = {
                                    Text(
                                        stringResource(R.string.skills_systemPromptPlaceholder),
                                        style = typography.body,
                                        color = colors.textTertiary,
                                    )
                                },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .heightIn(min = 140.dp, max = 280.dp),
                                textStyle = typography.body.copy(color = colors.textPrimary),
                                colors = TextFieldDefaults.colors(
                                    focusedContainerColor = Color.Transparent,
                                    unfocusedContainerColor = Color.Transparent,
                                    focusedIndicatorColor = Color.Transparent,
                                    unfocusedIndicatorColor = Color.Transparent,
                                    cursorColor = colors.primary,
                                ),
                            )
                            Text(
                                text = "${systemPrompt.length} / 4000",
                                style = typography.footnote,
                                color = if (systemPrompt.length > 4000) colors.danger else colors.textTertiary,
                                modifier = Modifier.align(Alignment.End),
                            )
                        }
                    }
                }

                // ── Knowledge Files Section ──
                Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                    SectionLabel(
                        text = stringResource(R.string.skills_knowledgeFiles),
                        tooltip = stringResource(R.string.skills_tipKnowledgeFiles),
                        trailing = stringResource(
                            R.string.skills_filesQuota,
                            knowledgeFiles.size,
                            MAX_KNOWLEDGE_FILES,
                        ),
                    )

                    OriveoCard(contentPadding = PaddingValues(vertical = spacing.xs)) {
                        Column {
                            if (knowledgeFiles.isEmpty()) {
                                Text(
                                    text = stringResource(R.string.skills_noKnowledgeFiles),
                                    style = typography.caption,
                                    color = colors.textTertiary,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = spacing.lg, vertical = 14.dp),
                                    textAlign = TextAlign.Center,
                                )
                                CardDivider()
                            }

                            knowledgeFiles.forEachIndexed { index, file ->
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = spacing.md, vertical = 4.dp),
                                ) {
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .background(
                                                color = colors.surfaceInset.copy(alpha = 0.6f),
                                                shape = RoundedCornerShape(10.dp),
                                            )
                                            .padding(horizontal = spacing.md, vertical = spacing.sm),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(spacing.md),
                                    ) {
                                        
                                        Box(
                                            modifier = Modifier
                                                .size(34.dp)
                                                .background(
                                                    color = colors.primary.copy(alpha = 0.1f),
                                                    shape = RoundedCornerShape(8.dp),
                                                ),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Icon(
                                                Icons.Filled.Description,
                                                contentDescription = null,
                                                modifier = Modifier.size(16.dp),
                                                tint = colors.primary,
                                            )
                                        }
                                        
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(
                                                text = file.name,
                                                style = typography.body,
                                                color = colors.textPrimary,
                                                maxLines = 1,
                                            )
                                            Text(
                                                text = stringResource(R.string.skills_nChars, file.charCount),
                                                style = typography.footnote,
                                                color = colors.textTertiary,
                                            )
                                        }
                                        
                                        IconButton(
                                            onClick = { knowledgeFiles.removeAt(index) },
                                            modifier = Modifier.size(24.dp),
                                        ) {
                                            Icon(
                                                Icons.Filled.Cancel,
                                                contentDescription = null,
                                                modifier = Modifier.size(18.dp),
                                                tint = colors.textTertiary,
                                            )
                                        }
                                    }
                                }
                            }

                            if (knowledgeFiles.size < MAX_KNOWLEDGE_FILES) {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable {
                                            launchExternalActivityOrNotify(androidContext) {
                                                referenceFilePickerLauncher.launch(
                                                    arrayOf(
                                                        "text/*",
                                                        "application/json",
                                                        "application/xml",
                                                        "application/pdf",
                                                        "text/csv",
                                                        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                                                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                                                        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                                                    )
                                                )
                                            }
                                        }
                                        .padding(vertical = 14.dp),
                                    horizontalArrangement = Arrangement.Center,
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Icon(
                                        Icons.Filled.Add,
                                        contentDescription = null,
                                        modifier = Modifier.size(13.dp),
                                        tint = colors.primary,
                                    )
                                    Spacer(Modifier.width(spacing.xs))
                                    Text(
                                        text = stringResource(R.string.skills_addFile),
                                        style = typography.caption,
                                        color = colors.primary,
                                    )
                                }
                            }
                        }
                    }
                }

                // ── Knowledge Base Files Section ──
                Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                    SectionLabel(
                        text = stringResource(R.string.skills_knowledgeBaseFiles),
                        tooltip = stringResource(R.string.skills_tipKnowledgeBaseFiles),
                        trailing = stringResource(
                            R.string.skills_filesQuota,
                            knowledgeBase?.files?.size ?: 0,
                            MAX_KNOWLEDGE_FILES,
                        ),
                    )

                    OriveoCard(contentPadding = PaddingValues(vertical = spacing.xs)) {
                        Column {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = spacing.lg, vertical = 14.dp),
                                horizontalArrangement = Arrangement.spacedBy(spacing.md),
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = knowledgeRuntime?.let {
                                            context.getString(
                                                R.string.skills_knowledgeProviderSummary,
                                                it.provider,
                                                it.retrievalModel,
                                            )
                                        } ?: stringResource(R.string.skills_knowledgeErrorServiceUnavailable),
                                        style = typography.footnote,
                                        color = colors.textSecondary,
                                    )
                                    Spacer(Modifier.height(4.dp))
                                    Text(
                                        text = context.getString(
                                            R.string.skills_knowledgeBytesSummary,
                                            formatKnowledgeBytes(knowledgeUsedBytes),
                                            formatKnowledgeBytes(MAX_KNOWLEDGE_TOTAL_BYTES),
                                        ),
                                        style = typography.footnote,
                                        color = colors.textTertiary,
                                    )
                                    Spacer(Modifier.height(4.dp))
                                    Text(
                                        text = knowledgeEligibilityHint,
                                        style = typography.caption,
                                        color = colors.textTertiary,
                                    )
                                    if (shouldShowKnowledgeCta) {
                                        Spacer(Modifier.height(spacing.sm))
                                        KnowledgeCtaCard(
                                            content = knowledgeCta,
                                            onPrimaryClick = {
                                                when (knowledgeCta.reason) {
                                                    SkillKnowledgeCtaReason.NoOpenAIKey,
                                                    SkillKnowledgeCtaReason.OnlyOpenRouter -> onOpenOpenAISetup()
                                                    SkillKnowledgeCtaReason.OpenAIEndpointNotOfficial,
                                                    SkillKnowledgeCtaReason.RetrievalModelNotEnabled -> {
                                                        openAIProvider?.id?.let(onOpenOpenAIProviderDetail) ?: onOpenOpenAISetup()
                                                    }
                                                    SkillKnowledgeCtaReason.ServiceUnavailable -> {
                                                        knowledgeRefreshTick += 1
                                                    }
                                                }
                                            },
                                            onSecondaryClick = {
                                                dismissedKnowledgeCtaReason = knowledgeCta.reason
                                            },
                                        )
                                    }
                                }
                            }

                            CardDivider()

                            if ((knowledgeBase?.files?.isEmpty() ?: true)) {
                                Text(
                                    text = stringResource(R.string.skills_noKnowledgeBaseFiles),
                                    style = typography.caption,
                                    color = colors.textTertiary,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = spacing.lg, vertical = 14.dp),
                                    textAlign = TextAlign.Center,
                                )
                                CardDivider()
                            }

                            knowledgeBase?.files?.forEach { file ->
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = spacing.md, vertical = 4.dp),
                                ) {
                                    Column(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .background(
                                                color = colors.surfaceInset.copy(alpha = 0.6f),
                                                shape = RoundedCornerShape(10.dp),
                                            )
                                            .padding(horizontal = spacing.md, vertical = spacing.sm),
                                        verticalArrangement = Arrangement.spacedBy(spacing.sm),
                                    ) {
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(spacing.md),
                                        ) {
                                            Box(
                                                modifier = Modifier
                                                    .size(34.dp)
                                                    .background(
                                                        color = colors.primary.copy(alpha = 0.1f),
                                                        shape = RoundedCornerShape(8.dp),
                                                    ),
                                                contentAlignment = Alignment.Center,
                                            ) {
                                                Icon(
                                                    Icons.Filled.Description,
                                                    contentDescription = null,
                                                    modifier = Modifier.size(16.dp),
                                                    tint = colors.primary,
                                                )
                                            }
                                            Column(modifier = Modifier.weight(1f)) {
                                                Text(
                                                    text = file.name,
                                                    style = typography.body,
                                                    color = colors.textPrimary,
                                                    maxLines = 1,
                                                )
                                                Text(
                                                    text = knowledgeFileSubtitle(file),
                                                    style = typography.footnote,
                                                    color = colors.textTertiary,
                                                )
                                            }
                                        }

                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.End,
                                        ) {
                                            if (displayKnowledgeStatus(file) == SkillKnowledgeFileStatus.READY) {
                                                TextButton(
                                                    onClick = {
                                                        knowledgeReplaceTargetId = file.id
                                                        launchExternalActivityOrNotify(androidContext) {
                                                            knowledgeFilePickerLauncher.launch(arrayOf("*/*"))
                                                        }
                                                    },
                                                    enabled = !knowledgeMutating,
                                                ) {
                                                    Text(stringResource(R.string.skills_replaceFile))
                                                }
                                            }
                                            if (file.status == SkillKnowledgeFileStatus.FAILED && knowledgeEligible) {
                                                TextButton(
                                                    onClick = { fileImportScope.launch { retryKnowledgeFile(file) } },
                                                    enabled = !knowledgeMutating,
                                                ) {
                                                    Text(stringResource(R.string.skills_retryFile))
                                                }
                                            }
                                            TextButton(
                                                onClick = { fileImportScope.launch { deleteKnowledgeFile(file) } },
                                                enabled = !knowledgeMutating,
                                            ) {
                                                Text(stringResource(R.string.skills_deleteFile))
                                            }
                                        }
                                    }
                                }
                            }

                            if ((knowledgeBase?.files?.size ?: 0) < MAX_KNOWLEDGE_FILES) {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable(enabled = !knowledgeMutating && knowledgeEligible) {
                                            knowledgeReplaceTargetId = null
                                            launchExternalActivityOrNotify(androidContext) {
                                                knowledgeFilePickerLauncher.launch(arrayOf("*/*"))
                                            }
                                        }
                                        .padding(vertical = 14.dp),
                                    horizontalArrangement = Arrangement.Center,
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Icon(
                                        Icons.Filled.Add,
                                        contentDescription = null,
                                        modifier = Modifier.size(13.dp),
                                        tint = if (knowledgeEligible && !knowledgeMutating) {
                                            colors.primary
                                        } else {
                                            colors.textTertiary
                                        },
                                    )
                                    Spacer(Modifier.width(spacing.xs))
                                    Text(
                                        text = stringResource(R.string.skills_addKnowledgeFile),
                                        style = typography.caption,
                                        color = if (knowledgeEligible && !knowledgeMutating) {
                                            colors.primary
                                        } else {
                                            colors.textTertiary
                                        },
                                    )
                                }
                            }
                        }
                    }
                }

                // ── Advanced Section ──
                Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                    SectionLabel(
                        text = stringResource(R.string.skills_advanced),
                        tooltip = stringResource(R.string.skills_tipAdvanced),
                    )

                    OriveoCard(contentPadding = PaddingValues(0.dp)) {
                        Column {
                            
                            val chevronRotation by animateFloatAsState(
                                targetValue = if (showAdvanced) 90f else 0f,
                                label = "chevron",
                            )
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { showAdvanced = !showAdvanced }
                                    .padding(horizontal = spacing.lg, vertical = 14.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = stringResource(R.string.skills_advancedSettings),
                                    style = typography.body,
                                    color = colors.textPrimary,
                                    modifier = Modifier.weight(1f),
                                )
                                Icon(
                                    Icons.Filled.ChevronRight,
                                    contentDescription = null,
                                    modifier = Modifier
                                        .size(16.dp)
                                        .rotate(chevronRotation),
                                    tint = colors.textTertiary,
                                )
                            }

                            AnimatedVisibility(
                                visible = showAdvanced,
                                enter = expandVertically() + fadeIn(),
                                exit = shrinkVertically() + fadeOut(),
                            ) {
                                Column {
                                    CardDivider()

                                    Column(
                                        modifier = Modifier.padding(spacing.lg),
                                        verticalArrangement = Arrangement.spacedBy(layout.sectionGap),
                                    ) {
                                        // P4b: old Skill capability fields stay inherited until this
                                        // single, explicit confirmation is made for the exact target.
                                        skillCapabilityTarget?.let { target ->
                                            Column(verticalArrangement = Arrangement.spacedBy(spacing.xs)) {
                                                Text(
                                                    text = stringResource(R.string.model_controls),
                                                    style = typography.caption,
                                                    color = colors.textSecondary,
                                                )
                                                Text(
                                                    text = "${target.providerName} · ${target.modelName}",
                                                    style = typography.body,
                                                    color = colors.textPrimary,
                                                )
                                                
                                                
                                                
                                                
                                                
                                                Text(
                                                    text = stringResource(R.string.skill_capability_confirm_note),
                                                    style = typography.footnote,
                                                    color = colors.textTertiary,
                                                )
                                                Row(horizontalArrangement = Arrangement.spacedBy(spacing.sm)) {
                                                    if (skillCapabilityConfirmed) {
                                                        TextButton(
                                                            onClick = {
                                                                viewModel.cancelSkillCapabilityConfirmation(existingSkill.id)
                                                                skillCapabilityConfirmed = false
                                                            },
                                                        ) {
                                                            Text(stringResource(R.string.cancel))
                                                        }
                                                    } else {
                                                        TextButton(
                                                            onClick = {
                                                                viewModel.confirmSkillCapability(existingSkill)
                                                                skillCapabilityConfirmed = viewModel.isSkillCapabilityConfirmed(existingSkill)
                                                            },
                                                        ) {
                                                            Text(stringResource(R.string.confirm))
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // Model Capability
                                        Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                                            Text(
                                                text = stringResource(R.string.skills_modelCapability),
                                                style = typography.caption,
                                                color = colors.textSecondary,
                                            )
                                            SingleChoiceSegmentedButtonRow(
                                                modifier = Modifier.fillMaxWidth(),
                                            ) {
                                                capabilityOptions.forEachIndexed { index, option ->
                                                    SegmentedButton(
                                                        selected = modelCapabilityHint == option,
                                                        onClick = { modelCapabilityHint = option },
                                                        shape = SegmentedButtonDefaults.itemShape(
                                                            index = index,
                                                            count = capabilityOptions.size,
                                                        ),
                                                        label = {
                                                            Text(
                                                                text = capabilityLabel(option),
                                                                style = typography.footnote,
                                                                maxLines = 1,
                                                            )
                                                        },
                                                    )
                                                }
                                            }
                                        }

                                        // Use Memory
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            verticalAlignment = Alignment.CenterVertically,
                                        ) {
                                            Column(modifier = Modifier.weight(1f)) {
                                                Text(
                                                    text = stringResource(R.string.skills_useMemory),
                                                    style = typography.body,
                                                    color = colors.textPrimary,
                                                )
                                                Text(
                                                    text = stringResource(R.string.skills_useMemoryDescription),
                                                    style = typography.footnote,
                                                    color = colors.textTertiary,
                                                )
                                            }
                                            Switch(
                                                checked = useMemory,
                                                onCheckedChange = { useMemory = it },
                                                colors = SwitchDefaults.colors(
                                                    checkedTrackColor = colors.primary,
                                                ),
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Spacer(Modifier.height(spacing.xxl))
            }
        }

        // ── Discard Dialog ──
        if (showDiscardDialog) {
            AlertDialog(
                onDismissRequest = { showDiscardDialog = false },
                title = { Text(stringResource(R.string.skills_discardChanges)) },
                text = { Text(stringResource(R.string.skills_discardMessage)) },
                confirmButton = {
                    TextButton(onClick = {
                        fileImportScope.launch {
                            if (cleanupDraftKnowledgeResources()) {
                                showDiscardDialog = false
                                onBack()
                            }
                        }
                    }) {
                        Text(stringResource(R.string.discard))
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showDiscardDialog = false }) {
                        Text(stringResource(R.string.cancel))
                    }
                },
            )
        }

        // ── Icon Dialog ──
        if (showIconDialog) {
            AlertDialog(
                onDismissRequest = { showIconDialog = false },
                title = { Text(stringResource(R.string.skills_emojiIcon)) },
                text = {
                    TextField(
                        value = iconInput,
                        onValueChange = { iconInput = it },
                        singleLine = true,
                        placeholder = { Text("\uD83E\uDD16") },
                    )
                },
                confirmButton = {
                    TextButton(onClick = {
                        val trimmed = iconInput.trim()
                        if (trimmed.isNotEmpty()) {
                            
                            val codePoint = trimmed.codePointAt(0)
                            icon = String(Character.toChars(codePoint))
                        }
                        showIconDialog = false
                    }) {
                        Text(stringResource(R.string.ok))
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showIconDialog = false }) {
                        Text(stringResource(R.string.cancel))
                    }
                },
            )
        }

        
        
        
        
        

    }
}

private data class ImportedFileSource(
    val bytes: ByteArray,
    val fileName: String,
    val mimeType: String,
    val sizeBytes: Long,
)


private data class ImportedFileMetadata(
    val fileName: String,
    val mimeType: String,
    val declaredSizeBytes: Long?,
)


@Composable
private fun KnowledgeCtaCard(
    content: SkillKnowledgeCtaContent,
    onPrimaryClick: () -> Unit,
    onSecondaryClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val typography = OriveoTheme.typography

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                color = colors.surfaceInset,
                shape = RoundedCornerShape(12.dp),
            )
            .border(
                width = OriveoBorderWidth.standard,
                color = colors.border.opacity(0.6f),
                shape = RoundedCornerShape(12.dp),
            )
            .padding(spacing.md),
        verticalArrangement = Arrangement.spacedBy(spacing.sm),
    ) {
        Text(
            text = content.message,
            style = typography.caption,
            color = colors.textSecondary,
        )

        val requiredModel = content.requiredModel?.trim().orEmpty()
        if (requiredModel.isNotEmpty()) {
            Text(
                text = stringResource(R.string.skills_requiredModel, requiredModel),
                style = typography.footnote,
                color = colors.textSecondary,
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(spacing.sm),
        ) {
            TextButton(
                onClick = onPrimaryClick,
                modifier = Modifier
                    .weight(1f)
                    .background(colors.primary, RoundedCornerShape(999.dp)),
            ) {
                Text(
                    text = content.primaryLabel,
                    style = typography.caption,
                    
                    color = Color.White,
                )
            }

            TextButton(
                onClick = onSecondaryClick,
                modifier = Modifier
                    .weight(1f)
                    .background(colors.surfaceElevated, RoundedCornerShape(999.dp)),
            ) {
                Text(
                    text = content.secondaryLabel,
                    style = typography.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun SectionLabel(
    text: String,
    tooltip: String? = null,
    trailing: String? = null,
) {
    val colors = OriveoTheme.colors
    var showTip by remember { mutableStateOf(false) }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = text.uppercase(),
            style = OriveoTheme.typography.footnote.copy(
                fontSize = 11.sp,
                letterSpacing = 0.8.sp,
            ),
            color = colors.textTertiary,
        )
        if (tooltip != null) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(16.dp)
                    .border(OriveoBorderWidth.standard, colors.textTertiary.copy(alpha = 0.4f), CircleShape)
                    .clip(CircleShape)
                    .clickable { showTip = true },
            ) {
                Text(
                    text = "?",
                    fontSize = 9.sp,
                    fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
                    color = colors.textTertiary,
                    textAlign = TextAlign.Center,
                    style = LocalTextStyle.current.copy(
                        platformStyle = PlatformTextStyle(includeFontPadding = false),
                        lineHeightStyle = LineHeightStyle(
                            alignment = LineHeightStyle.Alignment.Center,
                            trim = LineHeightStyle.Trim.Both,
                        ),
                    ),
                )
            }
        }
        if (trailing != null) {
            Text(
                text = trailing,
                style = OriveoTheme.typography.footnote,
                color = colors.textTertiary,
            )
        }
    }

    if (showTip && tooltip != null) {
        AlertDialog(
            onDismissRequest = { showTip = false },
            text = {
                Text(
                    text = tooltip,
                    style = OriveoTheme.typography.body,
                    color = colors.textPrimary,
                )
            },
            confirmButton = {
                TextButton(onClick = { showTip = false }) {
                    Text(stringResource(R.string.ok))
                }
            },
        )
    }
}

@Composable
private fun CardDivider() {
    HorizontalDivider(
        color = OriveoTheme.colors.border.opacity(0.5f),
        modifier = Modifier.padding(horizontal = OriveoSpacing.lg),
    )
}

@Composable
private fun capabilityLabel(option: String): String = when (option) {
    "any" -> stringResource(R.string.skills_capabilityAny)
    "reasoning" -> stringResource(R.string.skills_capabilityReasoning)
    "vision" -> stringResource(R.string.skills_capabilityVision)
    "fast" -> stringResource(R.string.skills_capabilityFast)
    "large-context" -> stringResource(R.string.skills_capabilityLargeContext)
    else -> option
}
