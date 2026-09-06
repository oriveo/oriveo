package ai.oriveo.community.feature.settings

import androidx.annotation.StringRes
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.core.util.takeGraphemes
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import org.koin.core.component.KoinComponent
import org.koin.core.component.get
import java.time.Instant

class MemoryViewModel(
    private val appPreferencesRepository: AppPreferencesRepository,
    private val conversationRepository: ConversationRepository,
    private val providerRepository: ProviderRepository,
) : ViewModel(), KoinComponent {

    var editText by mutableStateOf("")
        private set
    var antiForgetEnabled by mutableStateOf(false)
        private set
    var antiForgetText by mutableStateOf("")
        private set
    var editRevision by mutableIntStateOf(0)
        private set
    var isGeneratingDraft by mutableStateOf(false)
        private set
    var activeDraftRequestId by mutableStateOf<String?>(null)
        private set
    var pendingGeneratedDraft by mutableStateOf<String?>(null)
        private set
    var showDraftConflictDialog by mutableStateOf(false)
        private set
    var showSaveSuccessDialog by mutableStateOf(false)
        private set

    var draftError by mutableStateOf<DraftError?>(null)
        private set

    private var originalText = ""
    private var originalAntiForgetEnabled = false
    private var draftGenerationJob: Job? = null

    val usageCount: StateFlow<Int> = appPreferencesRepository.memoryUsageCount
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val hasRecentConversations: StateFlow<Boolean> = conversationRepository.observeHasAnyWithMessages()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val hasChanges: Boolean
        get() = editText != originalText ||
            antiForgetEnabled != originalAntiForgetEnabled

    val isEmpty: Boolean
        get() = editText.trim().isBlank()

    init {
        viewModelScope.launch {
            originalText = appPreferencesRepository.getMemoryText()
            originalAntiForgetEnabled = appPreferencesRepository.getMemoryAntiForgetEnabled()
            editText = originalText
            antiForgetEnabled = originalAntiForgetEnabled

            antiForgetText = appPreferencesRepository.getMemoryAntiForgetText()
        }
    }

    fun updateEditText(text: String) {
        val next = text.takeGraphemes(AppPreferencesRepository.MEMORY_CHARACTER_LIMIT)
        if (next != editText) {
            editText = next
            editRevision += 1
        }
    }

    fun updateAntiForgetEnabled(enabled: Boolean) {
        if (antiForgetEnabled == enabled) return
        antiForgetEnabled = enabled
        editRevision += 1

        if (enabled) {
            antiForgetText = editText.takeGraphemes(
                AppPreferencesRepository.MEMORY_ANTI_FORGET_CHARACTER_LIMIT,
            )
        }
    }

    fun save() {
        viewModelScope.launch {
            val normalizedText = editText.trim()
                .takeGraphemes(AppPreferencesRepository.MEMORY_CHARACTER_LIMIT)
            val normalizedAntiForgetEnabled = normalizedText.isNotBlank() && antiForgetEnabled

            val normalizedAntiForgetText = if (normalizedText.isBlank()) {
                ""
            } else {
                editText.takeGraphemes(AppPreferencesRepository.MEMORY_ANTI_FORGET_CHARACTER_LIMIT)
            }
            val updatedAt = Instant.now().toString()

            val previousWasEmpty = originalText.isBlank()
            val newIsEmpty = normalizedText.isBlank()
            val operation = when {
                previousWasEmpty && newIsEmpty -> "clear"
                previousWasEmpty -> "create"
                newIsEmpty -> "clear"
                else -> "update"
            }

            appPreferencesRepository.saveMemory(
                text = normalizedText,
                antiForgetEnabled = normalizedAntiForgetEnabled,
                antiForgetText = normalizedAntiForgetText,
                updatedAt = updatedAt,
            )
            originalText = normalizedText
            originalAntiForgetEnabled = normalizedAntiForgetEnabled
            editText = normalizedText
            antiForgetEnabled = normalizedAntiForgetEnabled
            antiForgetText = normalizedAntiForgetText
            editRevision = 0

            showSaveSuccessDialog = true
        }
    }

    fun dismissSaveSuccess() {
        showSaveSuccessDialog = false
    }

    fun dismissDraftError() {
        draftError = null
    }

    fun generateDraft() {
        draftGenerationJob?.cancel()
        val requestId = generateUuidString()
        activeDraftRequestId = requestId
        val baselineRevision = editRevision
        val baselineText = editText
        pendingGeneratedDraft = null
        draftError = null

        draftGenerationJob = viewModelScope.launch {
            try {

                val allProviders = providerRepository.observeAll().first()
                val candidates = allProviders
                    .filter { it.apiKey.isNotBlank() }
                    .mapNotNull { provider -> provider.toDraftCandidate() }

                if (candidates.isEmpty()) {
                    val hasAnyKey = allProviders.any { it.apiKey.isNotBlank() }
                    presentDraftError(
                        if (hasAnyKey) {
                            DraftError(
                                titleRes = R.string.memory_error_no_model_title,
                                messageRes = R.string.memory_error_no_model_message,
                            )
                        } else {
                            DraftError(
                                titleRes = R.string.memory_error_no_provider_title,
                                messageRes = R.string.memory_error_no_provider_message,
                            )
                        },
                    )
                    return@launch
                }

                val recent = conversationRepository.getRecentConversationsWithMessages(limit = 5)
                if (recent.isEmpty()) {
                    presentDraftError(
                        DraftError(
                            titleRes = R.string.memory_error_not_enough_title,
                            messageRes = R.string.memory_error_not_enough_message,
                        ),
                    )
                    return@launch
                }

                val excerpts = recent.joinToString("\n---\n") { conversation ->
                    conversation.messages
                        .filter { it.role == ChatRole.User || it.role == ChatRole.Assistant }
                        .joinToString("\n") { message ->
                            "${message.role.name.lowercase()}: ${message.text}"
                        }
                        .takeGraphemes(EXCERPT_CHARACTER_LIMIT)
                }
                if (excerpts.isBlank()) {
                    presentDraftError(
                        DraftError(
                            titleRes = R.string.memory_error_not_enough_title,
                            messageRes = R.string.memory_error_not_enough_message,
                        ),
                    )
                    return@launch
                }

                val prompt = buildDraftPrompt(excerpts)

                isGeneratingDraft = true

                var lastError: Throwable? = null
                var attempts = 0
                for (candidate in candidates) {
                    if (activeDraftRequestId != requestId) return@launch
                    attempts += 1
                    try {
                        val service = providerRepository.serviceFor(candidate.provider.kind)
                        val response = service.sendMessage(
                            apiKey = candidate.provider.apiKey,
                            modelID = candidate.model.id,
                            messages = listOf(
                                ChatMessage(
                                    id = generateUuidString(),
                                    role = ChatRole.User,
                                    text = prompt,
                                    providerID = candidate.provider.id,
                                    providerKind = candidate.provider.kind,
                                    providerName = candidate.provider.displayName,
                                    modelID = candidate.model.id,
                                    modelName = candidate.model.name,
                                    state = ChatMessageState.Delivered,
                                ),
                            ),
                            baseUrl = candidate.provider.baseUrlText,
                            supportsImageGen = false,
                            reasoningMode = ReasoningMode.Automatic,
                            webSearchEnabled = false,
                            requestOptions = ChatRequestOptions(),
                        )

                        if (activeDraftRequestId != requestId) return@launch

                        val draft = response.result.text
                            .trim()
                            .takeGraphemes(AppPreferencesRepository.MEMORY_CHARACTER_LIMIT)
                        if (draft.isBlank()) {

                            lastError = ProviderServiceError.EmptyResponse
                            continue
                        }

                        val userEditedSinceStart =
                            editRevision != baselineRevision || editText != baselineText
                        if (userEditedSinceStart) {
                            pendingGeneratedDraft = draft
                            showDraftConflictDialog = true
                        } else {
                            editText = draft
                            editRevision += 1
                        }
                        return@launch
                    } catch (cancel: CancellationException) {
                        throw cancel
                    } catch (error: Throwable) {
                        lastError = error

                    }
                }

                if (activeDraftRequestId != requestId) return@launch
                presentDraftError(aggregateDraftError(attempts, lastError))
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (error: Throwable) {
                if (activeDraftRequestId == requestId) {
                    presentDraftError(
                        DraftError(
                            titleRes = R.string.memory_error_hydrate_title,
                            messageRes = R.string.memory_error_hydrate_message,
                        ),
                    )
                }
            } finally {
                if (activeDraftRequestId == requestId) {
                    activeDraftRequestId = null
                    isGeneratingDraft = false
                }
            }
        }
    }

    fun applyPendingGeneratedDraft() {
        pendingGeneratedDraft?.let { draft ->
            editText = draft
            editRevision += 1
        }
        pendingGeneratedDraft = null
        showDraftConflictDialog = false
    }

    fun dismissPendingGeneratedDraft() {
        pendingGeneratedDraft = null
        showDraftConflictDialog = false
    }

    override fun onCleared() {
        draftGenerationJob?.cancel()
        activeDraftRequestId = null
    }

    private fun aggregateDraftError(attempts: Int, lastError: Throwable?): DraftError {

        if (attempts <= 1) {
            val detail = providerErrorDetail(lastError)
            return if (detail.isNullOrBlank()) {
                DraftError(
                    titleRes = R.string.memory_error_generic_title,
                    messageRes = R.string.memory_error_generic_message,
                )
            } else {
                DraftError(
                    titleRes = R.string.memory_error_generic_title,
                    messageLiteral = detail,
                )
            }
        }

        val detail = providerErrorDetail(lastError)
        return if (detail.isNullOrBlank()) {
            DraftError(
                titleRes = R.string.memory_error_generic_title,
                messageRes = R.string.memory_error_aggregated,
                args = listOf(attempts),
            )
        } else {
            DraftError(
                titleRes = R.string.memory_error_generic_title,
                messageRes = R.string.memory_error_aggregated_with_detail,
                args = listOf(attempts, detail),
            )
        }
    }

    private fun providerErrorDetail(error: Throwable?): String? = when (error) {
        null -> null
        is ProviderServiceError -> localizeProviderMessage(error)
        else -> error.message
    }

    private fun localizeProviderMessage(error: ProviderServiceError): String =
        runCatching { ErrorMapper.localizeProviderErrorMessage(error, get<android.content.Context>()) }
            .getOrDefault(error.userMessage)

    private fun presentDraftError(error: DraftError) {
        draftError = error
    }

    private fun Provider.toDraftCandidate(): DraftCandidate? {
        val resolvedModel: AIModel = defaultModel
            ?: models.firstOrNull()
            ?: allModels.firstOrNull()
            ?: return null
        return DraftCandidate(provider = this, model = resolvedModel)
    }

    private fun buildDraftPrompt(excerpts: String): String = """
        Based on the following conversation excerpts, write a concise personal profile in the same language the user is using (under 400 words).
        Include: their role/expertise, current projects or tech stack, preferred response style and language.
        Only include information clearly evident from the conversations. Do not invent or assume.
        Write in first person, as if the user is describing themselves.

        Conversation excerpts:
        $excerpts
    """.trimIndent()

    private data class DraftCandidate(
        val provider: Provider,
        val model: AIModel,
    )

    data class DraftError(
        @param:StringRes val titleRes: Int,
        @param:StringRes val messageRes: Int? = null,
        val messageLiteral: String? = null,
        val args: List<Any> = emptyList(),
    )

    companion object {
        private const val EXCERPT_CHARACTER_LIMIT = 500
    }
}
