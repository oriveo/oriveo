package ai.oriveo.community.feature.skills

import ai.oriveo.community.R
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.CreateKnowledgeFileRequest
import ai.oriveo.community.core.data.repository.CreateSkillRequest
import ai.oriveo.community.core.data.repository.KnowledgeCleanupInput
import ai.oriveo.community.core.data.repository.UpdateSkillRequest
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillCategory
import ai.oriveo.community.core.model.SkillKnowledgeBase
import ai.oriveo.community.core.model.SkillKnowledgeFile
import ai.oriveo.community.core.model.resolveActiveModel

import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class SkillViewModel(
    private val skillRepository: SkillRepository,
    private val providerRepository: ProviderRepository,
    private val conversationRepository: ConversationRepository,
    private val appPreferencesRepository: AppPreferencesRepository,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val capabilityPreferenceStore: CapabilityPreferenceStore? = null,
) : ViewModel() {
    private fun hasProviderKey(provider: Provider): Boolean =
        provider.apiKey.trim().isNotEmpty() || provider.apiKeyPreview.trim().isNotEmpty()

    val catalogSkills: StateFlow<List<Skill>> = skillRepository.observeCatalogSkills()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val userSkills: StateFlow<List<Skill>> = skillRepository.observeUserSkills()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val allSkills: StateFlow<List<Skill>> = skillRepository.observeAllSkills()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val usage: StateFlow<Nothing?> = kotlinx.coroutines.flow.MutableStateFlow(null)

    val categories: StateFlow<List<SkillCategory>> = skillRepository.categories
    private val providers: StateFlow<List<Provider>> = providerRepository.observeAll()
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    private val lastUsedModelRef = appPreferencesRepository.lastUsedModelRef
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    

    var isRefreshing by mutableStateOf(false)
        private set

    var skillToDelete: Skill? by mutableStateOf(null)

    
    var expandedCategories by mutableStateOf(emptySet<String>())
        private set

    
    var editingSkill: Skill? by mutableStateOf(null)
        private set
    var isSaving by mutableStateOf(false)
        private set
    var saveError: String? by mutableStateOf(null)
        private set

    var showSkillProviderPrompt by mutableStateOf(false)
        private set

    fun dismissSkillProviderPrompt() {
        showSkillProviderPrompt = false
    }


    init {
        viewModelScope.launch { refreshAllSafely() }
    }

    fun refresh() {
        viewModelScope.launch {
            isRefreshing = true
            try {
                refreshAllSafely()
            } finally {
                isRefreshing = false
            }
        }
    }

    private suspend fun refreshAllSafely() {
        try {
            skillRepository.refreshAll()
        } catch (error: Exception) {
            showGuardError(error)
            // Keep screen interactive even when refresh fails.
        }
    }

    fun toggleCategoryExpansion(categoryId: String) {
        expandedCategories = if (expandedCategories.contains(categoryId)) {
            expandedCategories - categoryId
        } else {
            expandedCategories + categoryId
        }
    }

    fun isCategoryExpanded(categoryId: String): Boolean =
        expandedCategories.contains(categoryId)


    /**
     * The server's legacy Skill capability fields are descriptive input only.  They remain
     * inherited until the owner explicitly confirms this exact provider/model transport target.
     */
    data class SkillCapabilityConfirmationTarget(
        val providerID: String,
        val providerName: String,
        val modelID: String,
        val modelName: String,
        val transportIdentity: String,
    )

    fun skillCapabilityConfirmationTarget(skill: Skill): SkillCapabilityConfirmationTarget? {
        if (capabilityPreferenceStore == null) return null
        val suggestedProviderID = skill.suggestedProviderId?.trim().orEmpty()
        val suggestedModelID = skill.suggestedModelId?.trim().orEmpty()
        if (suggestedProviderID.isEmpty() || suggestedModelID.isEmpty()) return null
        val provider = providers.value.firstOrNull { it.id.equals(suggestedProviderID, ignoreCase = true) } ?: return null
        val model = ModelSelectionUtils.matchingModel(provider.models, suggestedModelID) ?: return null
        val identity = ModelControlRuntimeIdentityResolver.resolve(provider, model) ?: return null
        return SkillCapabilityConfirmationTarget(
            providerID = provider.id,
            providerName = provider.displayName,
            modelID = identity.canonicalModelId,
            modelName = model.name,
            transportIdentity = identity.storageIdentity,
        )
    }

    fun isSkillCapabilityConfirmed(skill: Skill): Boolean {
        val target = skillCapabilityConfirmationTarget(skill) ?: return false
        return capabilityPreferenceStore?.hasSkillAgentConfirmation(
            providerID = target.providerID,
            modelID = target.modelID,
            skillID = skill.id,
            transportIdentity = target.transportIdentity,
        ) == true
    }

    /** Explicit user action; no stored Skill field can call this implicitly. */
    fun confirmSkillCapability(skill: Skill) {
        val target = skillCapabilityConfirmationTarget(skill) ?: return
        capabilityPreferenceStore?.invalidateSkillAgent(skill.id)
        capabilityPreferenceStore?.confirmSkillAgent(
            values = capabilityValuesFromExplicitConfirmation(skill),
            providerID = target.providerID,
            modelID = target.modelID,
            skillID = skill.id,
            transportIdentity = target.transportIdentity,
        )
    }

    /** Explicit withdrawal; the tombstone is synced by the existing capability preference store. */
    fun cancelSkillCapabilityConfirmation(skillID: String) {
        capabilityPreferenceStore?.invalidateSkillAgent(skillID)
    }

    // ── CRUD ──

    fun createSkill(
        name: String,
        description: String,
        icon: String,
        color: String,
        systemPrompt: String,
        suggestedProviderId: String?,
        suggestedModelId: String?,
        modelCapabilityHint: String,
        temperature: Double?,
        reasoningLevel: String?,
        webSearchEnabled: Boolean?,
        starterMessages: List<String>,
        knowledgeFiles: List<SkillKnowledgeFile>,
        knowledgeBase: SkillKnowledgeBase?,
        useMemory: Boolean,
        onSuccess: (Skill) -> Unit,
        onError: (String) -> Unit,
    ) {
        viewModelScope.launch {
            isSaving = true
            saveError = null
            try {
                val skill = skillRepository.create(
                    CreateSkillRequest(
                        name = name,
                        description = description,
                        icon = icon,
                        color = color,
                        systemPrompt = systemPrompt,
                        suggestedProviderId = suggestedProviderId,
                        suggestedModelId = suggestedModelId,
                        modelCapabilityHint = modelCapabilityHint,
                        temperature = temperature,
                        reasoningLevel = reasoningLevel,
                        webSearchEnabled = webSearchEnabled,
                        starterMessages = starterMessages,
                        knowledgeFiles = knowledgeFiles.map {
                            CreateKnowledgeFileRequest(name = it.name, content = it.content)
                        },
                        knowledgeBase = knowledgeBase,
                        useMemory = useMemory,
                    )
                )
                onSuccess(skill)
            } catch (e: Exception) {
                if (!showGuardError(e)) {
                    saveError = e.message
                    onError(e.message ?: "Unknown error")
                }
            } finally {
                isSaving = false
            }
        }
    }

    fun updateSkill(
        id: String,
        name: String?,
        description: String?,
        icon: String?,
        color: String?,
        systemPrompt: String?,
        suggestedProviderId: String?,
        suggestedModelId: String?,
        modelCapabilityHint: String?,
        temperature: Double?,
        reasoningLevel: String?,
        webSearchEnabled: Boolean?,
        starterMessages: List<String>?,
        knowledgeFiles: List<SkillKnowledgeFile>?,
        knowledgeBase: SkillKnowledgeBase?,
        knowledgeCleanup: KnowledgeCleanupInput? = null,
        useMemory: Boolean?,
        onSuccess: (Skill) -> Unit,
        onError: (String) -> Unit,
    ) {
        viewModelScope.launch {
            isSaving = true
            saveError = null
            try {
                val skill = skillRepository.update(
                    id,
                    UpdateSkillRequest(
                        name = name,
                        description = description,
                        icon = icon,
                        color = color,
                        systemPrompt = systemPrompt,
                        suggestedProviderId = suggestedProviderId,
                        suggestedModelId = suggestedModelId,
                        modelCapabilityHint = modelCapabilityHint,
                        temperature = temperature,
                        reasoningLevel = reasoningLevel,
                        webSearchEnabled = webSearchEnabled,
                        starterMessages = starterMessages,
                        knowledgeFiles = knowledgeFiles?.map {
                            CreateKnowledgeFileRequest(name = it.name, content = it.content)
                        },
                        knowledgeBase = knowledgeBase,
                        knowledgeCleanup = knowledgeCleanup,
                        useMemory = useMemory,
                    )
                )
                val previous = editingSkill?.takeIf { it.id.equals(id, ignoreCase = true) }
                if (previous != null && capabilityTargetChanged(previous, skill)) {
                    // A changed suggested target must never inherit the old explicit consent.
                    // Clear the whole Skill namespace, because the old transport fingerprint may
                    // no longer be reconstructable after a provider/catalog mutation.
                    capabilityPreferenceStore?.invalidateSkillAgent(skill.id)
                }
                editingSkill = skill
                onSuccess(skill)
            } catch (e: Exception) {
                if (!showGuardError(e)) {
                    saveError = e.message
                    onError(e.message ?: "Unknown error")
                }
            } finally {
                isSaving = false
            }
        }
    }

    fun deleteSkill(
        id: String,
        knowledgeCleanup: KnowledgeCleanupInput? = null,
        onDone: () -> Unit = {},
        onError: (String) -> Unit = {},
    ) {
        viewModelScope.launch {
            try {
                skillRepository.delete(id, knowledgeCleanup)
            } catch (e: Exception) {
                if (!showGuardError(e)) onError(e.message ?: "Unknown error")
            }
            skillToDelete = null
            onDone()
        }
    }

    fun forkSkill(id: String, onSuccess: (Skill) -> Unit, onError: (String) -> Unit) {
        viewModelScope.launch {
            try {
                val skill = skillRepository.fork(id)
                onSuccess(skill)
            } catch (e: Exception) {
                if (!showGuardError(e)) onError(e.message ?: "Unknown error")
            }
        }
    }

    fun togglePin(skill: Skill) {
        viewModelScope.launch {
            val newPinned = !skill.isPinned
            val pinOrder = if (newPinned) {
                (allSkills.value.filter { it.isPinned }.maxOfOrNull { it.pinOrder } ?: 0) + 1
            } else {
                skill.pinOrder
            }
            skillRepository.togglePin(skill.id, newPinned, pinOrder)
        }
    }

    fun loadSkillForEdit(id: String) {
        viewModelScope.launch {
            editingSkill = skillRepository.getById(id)
        }
    }

    fun clearEditState() {
        editingSkill = null
        saveError = null
    }

    private fun showGuardError(error: Throwable): Boolean {
        @Suppress("UNUSED_PARAMETER")
        val ignored = error
        return false
    }

    private fun capabilityValuesFromExplicitConfirmation(skill: Skill): CapabilityPreferenceValues =
        CapabilityPreferenceValues(
            web = if (skill.webSearchEnabled == true) CapabilityWebPreference.Automatic else CapabilityWebPreference.Off,
            reasoningIntent = skill.reasoningLevel?.trim()?.lowercase()?.takeIf {
                it in setOf("off", "low", "balanced", "deep", "max")
            },
        )

    private fun capabilityTargetChanged(before: Skill, after: Skill): Boolean =
        !before.suggestedProviderId.orEmpty().equals(after.suggestedProviderId.orEmpty(), ignoreCase = true) ||
            before.suggestedModelId.orEmpty() != after.suggestedModelId.orEmpty()

    val openAIKnowledgeProvider: StateFlow<Provider?> = providers.map { list ->
        list.firstOrNull { it.kind == ProviderKind.OpenAI && it.apiKey.trim().isNotEmpty() }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val hasAnyOpenAIProvider: StateFlow<Boolean> = openAIKnowledgeProvider
        .map { it != null }
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    val hasOpenRouterProvider: StateFlow<Boolean> = providers.map { list ->
        list.any { it.kind == ProviderKind.OpenRouter && hasProviderKey(it) }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, false)

    /** Exposed only so the edit surface re-evaluates an exact confirmation target after catalog refresh. */
    val capabilityConfirmationProviders: StateFlow<List<Provider>> = providers

    private data class ActiveModel(
        val provider: Provider,
        val model: AIModel,
    )

    private fun matchesCapabilityHint(provider: Provider, model: AIModel, hint: String): Boolean = when (hint) {
        "reasoning" -> CapabilityEvidenceProductionAdapter.supportedReasoningModes(provider, model).isNotEmpty()
        "vision" -> ModelCapability.Image in
            CapabilityEvidenceProductionAdapter.governedMetadataCapabilities(provider, model)
        "fast" -> model.priceTier == "$" ||
            model.name.contains("mini", ignoreCase = true) ||
            model.name.contains("haiku", ignoreCase = true) ||
            model.name.contains("flash", ignoreCase = true)
        "large-context" -> (model.contextLength ?: 0) >= 128_000
        else -> false
    }

    private fun resolveModelForSkill(skill: Skill): ActiveModel? {
        val providerList = providers.value
            .filter { it.status !is ProviderConnectionState.Issue && it.models.isNotEmpty() }

        if (providerList.isEmpty()) return null

        if (skill.suggestedModelId != null && skill.suggestedProviderId != null) {
            val suggestedProvider = providerList.firstOrNull {
                it.id == skill.suggestedProviderId || it.kind.rawValue == skill.suggestedProviderId
            }
            val suggestedModel = suggestedProvider?.models?.let { models ->
                ModelSelectionUtils.matchingModel(models, skill.suggestedModelId)
            }
            if (suggestedProvider != null && suggestedModel != null) {
                return ActiveModel(suggestedProvider, suggestedModel)
            }
        }

        if (skill.modelCapabilityHint != "any") {
            val activeProviderId = resolveActiveModel(providers.value, lastUsedModelRef.value)?.provider?.id
            val sortedProviders = providerList.sortedByDescending { it.id == activeProviderId }
            for (provider in sortedProviders) {
                val model = provider.models.firstOrNull {
                    matchesCapabilityHint(provider, it, skill.modelCapabilityHint)
                }
                if (model != null) {
                    return ActiveModel(provider, model)
                }
            }
        }

        val active = resolveActiveModel(providerList, lastUsedModelRef.value)
        if (active != null && providerList.any { it.id == active.provider.id }) {
            return ActiveModel(active.provider, active.model)
        }

        val fallbackProvider = providerList.firstOrNull() ?: return null
        val fallbackModel = fallbackProvider.defaultModel ?: fallbackProvider.models.firstOrNull() ?: return null
        return ActiveModel(fallbackProvider, fallbackModel)
    }

    fun startConversationWithSkill(
        skill: Skill,
        onCreated: (String) -> Unit,
        onMissingProvider: (() -> Unit)? = null,
    ) {
        val active = resolveModelForSkill(skill)
        if (active == null) {
            globalSnackbarManager.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.skills_needProviderMessage),
                ),
            )
            showSkillProviderPrompt = true
            return
        }

        viewModelScope.launch {
            appPreferencesRepository.setLastUsedModel(active.provider.id, active.model)
            val conversation = conversationRepository.createDraft(
                providerID = active.provider.id,
                providerKind = active.provider.kind,
                modelID = ModelSelectionUtils.preferredStoredModelIdentifier(active.model),
                title = skill.name,
                skillId = skill.id,
                useMemory = skill.useMemory,
            )
            
            
            onCreated(conversation.id)
            skillRepository.recordUse(skill.id)
        }
    }
}
