package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.attachments.AttachmentInjector
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.resolvedForRequest
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.core.provider.ModelControlRejectionCache
import ai.oriveo.community.core.util.normalizeUuid
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.streaming.StreamRequest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

internal class ChatSendCoordinator(
    private val appPreferencesRepository: AppPreferencesRepository,
    private val chatStreamingManager: ChatStreamingManager,
    private val applicationScope: CoroutineScope,
    private val promptInjectionBuilder: ChatPromptInjectionBuilder,
    private val currentAntiForgetEnabled: () -> Boolean,
    private val currentAntiForgetText: () -> String,
    /** Resolves the pinned note ids on the conversation, plus any staged before it was stored. */
    private val pinnedNotesResolver: suspend (List<String>) -> List<Note>,
    private val pendingPinnedNoteIds: () -> List<String>,
    private val generationParameterSettingsStore: GenerationParameterSettingsStore,
    private val capabilityPreferenceStore: CapabilityPreferenceStore? = null,
    private val localCustomFragmentStore: LocalCapabilityCustomFragmentStore? = null,
    private val capabilityEvidencePartition: () -> String = { "" },
    private val capabilityEvidenceIdentity: suspend (Provider, String, String) -> ai.oriveo.community.core.model.CapabilityEvidenceIdentity? = { _, _, _ -> null },
) {
    fun launchSend(
        conversation: Conversation,
        provider: Provider,
        modelId: String,
        text: String,
        memoryText: String,
        existingMessages: List<ChatMessage>,
        attachments: List<Attachment>? = null,
        quoteContext: QuoteContext? = null,
        persistUserMessage: Boolean = true,
        appendToAssistant: ChatMessage? = null,
        userMessageAlreadyInHistory: Boolean = false,
    ) {
        // Capture the capability partition exactly once, up front. The identity producer may read
        // the epoch later on another thread, and re-reading it there would let a request built for
        // one partition be dispatched against another.
        val evidencePartitionId = capabilityEvidencePartition()
        val selectedModel = ProviderSelectionSnapshot.selectedModel(provider, modelId)
        val modelControlIdentity = selectedModel?.let {
            ModelControlRuntimeIdentityResolver.resolve(provider, it)
        }
        val omitSettingMarker = appendToAssistant?.customRetryWithoutFieldsCode
            ?.split(':')
            ?.takeIf { parts -> parts.size == 5 && parts[0] == "omit_capability_setting_once" }
        val omitSettingSource = omitSettingMarker?.get(1)?.takeIf { it in setOf("custom", "provider_recipe") }
        val omitSettingOwner = omitSettingMarker?.get(2)?.takeIf { it in setOf("web", "reasoning", "generation") }
        fun decodeMarkerPart(encoded: String): String? = runCatching {
            String(java.util.Base64.getUrlDecoder().decode(encoded), Charsets.UTF_8)
        }.getOrNull()
        val omitRecipeRef = omitSettingMarker?.get(3)?.takeUnless { it == "-" }?.let(::decodeMarkerPart)
        val omitSettingPointers = omitSettingMarker?.get(4)?.let { encoded ->
            runCatching {
                String(java.util.Base64.getUrlDecoder().decode(encoded), Charsets.UTF_8)
                    .split('\u001f')
                    .filter { it.startsWith('/') && it.length <= 160 }
                    .toSet()
                    .takeIf { it.isNotEmpty() }
            }.getOrNull()
        }.orEmpty()
        fun cachedRejectedSettings(owner: String, source: String, recipeRef: String? = null): Set<String> =
            modelControlIdentity
                ?.let { ModelControlRejectionCache.rejectedSettings(it, owner, source, recipeRef = recipeRef) }
                .orEmpty()
        val omitSettingCacheMatches = omitSettingSource != null && omitSettingOwner != null &&
            omitSettingPointers.isNotEmpty() &&
            (omitSettingSource != "provider_recipe" || !omitRecipeRef.isNullOrBlank()) &&
            cachedRejectedSettings(omitSettingOwner, omitSettingSource, omitRecipeRef).containsAll(omitSettingPointers)
        val resendSettingSource = omitSettingSource.takeIf { omitSettingCacheMatches }
        val resendSettingOwner = omitSettingOwner.takeIf { omitSettingCacheMatches }
        val resendRecipeRef = omitRecipeRef.takeIf { omitSettingCacheMatches }
        val resendSettingPointers = omitSettingPointers.takeIf { omitSettingCacheMatches }.orEmpty()
        // Same resolution the composer chip and the model-control panel use. What goes out on the
        // wire and what the UI shows must always come from one conclusion, never two.
        val storedTypedPreferences = capabilityPreferenceStore?.resolvedForRequest(
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = modelControlIdentity?.canonicalModelId ?: modelId,
            conversationID = conversation.id,
            skillID = conversation.skillId,
            transportIdentity = modelControlIdentity?.storageIdentity,
        ) ?: CapabilityPreferenceValues()
        // A custom fragment goes out on exactly one condition: this owner's custom entry is
        // enabled right now. Schema availability filtering already happens inside
        // `fragmentsByOwner`, so there is deliberately no second `capabilityCustomFragmentAvailable`
        // check here. Writing that rule in two places is exactly the shape of the bug where the UI
        // claims a custom fragment is in charge while the request quietly dropped it.
        val storedCustomFragments = if (modelControlIdentity != null) {
            localCustomFragmentStore?.fragmentsByOwner(
                provider.id,
                modelControlIdentity.canonicalModelId,
                conversation.id,
                modelControlIdentity.storageIdentity,
                // Sending is the one discrete event that must not miss a recipe version change: if
                // the user's custom fields do not follow the new version, this message silently
                // goes out without a JSON block they believe is still in effect.
                forwardPort = LocalCapabilityCustomFragmentStore.ForwardPortContext(
                    providerKind = provider.kind,
                    schemaModelID = modelId,
                    activeProfile = selectedModel?.generationProfile,
                ),
            ).orEmpty()
        } else emptyMap()
        val storedReasoningMode = ReasoningMode.fromIntent(storedTypedPreferences.reasoningIntent)
        val storedWebRequested = storedTypedPreferences.web != CapabilityWebPreference.Off
        val currentRecipeRefs = MetadataClient.capabilityRuntimeRequest(
            providerKind = provider.kind,
            modelID = modelId,
            finalTransport = modelControlIdentity?.finalTransport.orEmpty(),
            webRequested = storedWebRequested,
            reasoningMode = storedReasoningMode,
            typedWebIntent = "force".takeIf { storedTypedPreferences.web == CapabilityWebPreference.Force },
            typedReasoningIntent = storedTypedPreferences.reasoningIntent,
        )?.selections.orEmpty().associate { it.capability to it.id }
        val normalRejectedRecipeOwners = currentRecipeRefs.mapNotNull { (owner, recipeRef) ->
            owner.takeIf {
                owner !in storedCustomFragments && cachedRejectedSettings(owner, "provider_recipe", recipeRef).isNotEmpty()
            }
        }.toSet()
        val normalRejectedCustomOwners = storedCustomFragments.keys.filterTo(linkedSetOf()) { owner ->
            cachedRejectedSettings(owner, "custom").isNotEmpty()
        }
        val explicitRecipeOwner = resendSettingOwner?.takeIf {
            resendSettingSource == "provider_recipe" && resendRecipeRef != null && resendSettingPointers.isNotEmpty()
        }
        val dormantOwners = (normalRejectedRecipeOwners + normalRejectedCustomOwners) - setOfNotNull(explicitRecipeOwner)
        val typedPreferences = storedTypedPreferences.copy(
            web = if ("web" in dormantOwners) CapabilityWebPreference.Off else storedTypedPreferences.web,
        )
        val effectiveReasoningMode = ReasoningMode.fromIntent(typedPreferences.reasoningIntent)
        val requestedWebSearchEnabled = when (typedPreferences.web) {
            CapabilityWebPreference.Off -> false
            CapabilityWebPreference.Automatic, CapabilityWebPreference.Force, CapabilityWebPreference.Custom -> true
        }
        val effectiveWebSearchEnabled = requestedWebSearchEnabled
        val dispatchedTypedPreferences = if (effectiveWebSearchEnabled) typedPreferences else typedPreferences.copy(
            web = CapabilityWebPreference.Off,
        )
        // The raw fragment is read only into this process-local request carrier; it is never
        // persisted or logged. An explicit recovery retry carries a one-shot marker on the
        // replacement assistant message, which suppresses every custom owner for that one request
        // without touching what the user has stored.
        val localCustomFragments = storedCustomFragments
            .mapNotNull { (owner, raw) ->
                (owner to raw).takeIf {
                    owner !in dormantOwners && resendSettingOwner != owner
                }
            }
            .toMap()
        val customOwners = localCustomFragments.keys
        val customTypedPreferences = dispatchedTypedPreferences.copy(
            web = if ("web" in customOwners) CapabilityWebPreference.Off else dispatchedTypedPreferences.web,
            reasoningIntent = if ("reasoning" in customOwners) null else dispatchedTypedPreferences.reasoningIntent,
        )
        val customReasoningMode = if ("reasoning" in customOwners) ReasoningMode.Automatic else effectiveReasoningMode

        // The whole send, including the 1-50ms window spent assembling the prompt, runs on the
        // application scope rather than the ViewModel's. Navigating away or closing the chat screen
        // mid-send would otherwise cancel it somewhere between prompt assembly and startStream, and
        // the message would be lost.
        applicationScope.launch {
            // Pinned notes: what the conversation already stores, plus anything staged while
            // composing a first message that has not been written yet. Deduplicate and keep the
            // most recent few.
            val pinnedNoteIds = (conversation.pinnedNoteIds + pendingPinnedNoteIds())
                .map(::normalizeUuid)
                .distinct()
                .takeLast(ChatPromptInjectionBuilder.MAX_PINNED_NOTES)
            // The lookup has no ORDER BY, so reorder to match pinnedNoteIds. That keeps injection
            // order deterministic and makes it predictable which notes get dropped under a tight
            // prompt budget.
            val resolvedPinned = if (pinnedNoteIds.isEmpty()) emptyList() else pinnedNotesResolver(pinnedNoteIds)
            val pinnedById = resolvedPinned.associateBy { normalizeUuid(it.id) }
            val pinnedNotes = pinnedNoteIds.mapNotNull { pinnedById[it] }
            val promptInjection = promptInjectionBuilder.build(
                conversation = conversation,
                memoryText = memoryText,
                latestUserText = text,
                pinnedNotes = pinnedNotes,
            )
            val antiForgetText = if (appendToAssistant != null) {
                null
            } else {
                ChatPromptInjectionBuilder.resolvedAntiForgetText(
                    conversation = conversation,
                    existingMessages = existingMessages,
                    memoryText = memoryText,
                    antiForgetEnabled = currentAntiForgetEnabled(),
                    antiForgetText = currentAntiForgetText(),
                    remainingChars = promptInjection?.remainingChars ?: 12_000,
                )
            }
            val finalSystemPrompt = finalSystemPrompt(
                basePrompt = promptInjection?.systemPrompt.orEmpty(),
                attachments = attachments,
            )
            val baseRequestOptions = if (finalSystemPrompt.isNotBlank()) {
                if (promptInjection?.memoryInjected == true) {
                    appPreferencesRepository.markMemoryUsedInConversation(conversation.id)
                }
                ChatRequestOptions(systemPrompt = finalSystemPrompt)
            } else {
                ChatRequestOptions()
            }
            val requestOptions = baseRequestOptions.let { options ->
                // The outbound profile and the dormant check must read the same resolution. If the
                // set this side calls active differs from the set `GenerationParameterResolver.apply`
                // actually writes into the body, the panel says it kept N parameters while M went
                // out. Resolve once here and share it.
                val outboundGenerationProfile = selectedModel?.let {
                    ai.oriveo.community.core.provider.GenerationParameterAvailability.profile(provider, it)
                }
                val selectedRecipeRefs = MetadataClient.capabilityRuntimeRequest(
                    providerKind = provider.kind,
                    modelID = modelId,
                    finalTransport = modelControlIdentity?.finalTransport.orEmpty(),
                    webRequested = effectiveWebSearchEnabled,
                    reasoningMode = customReasoningMode,
                    typedWebIntent = "force".takeIf { customTypedPreferences.web == CapabilityWebPreference.Force },
                    typedReasoningIntent = customTypedPreferences.reasoningIntent,
                )?.selections.orEmpty().associate { it.capability to it.id }
                val recipeRejectedSettings = selectedRecipeRefs.mapNotNull { (owner, recipeRef) ->
                    resendSettingPointers.takeIf {
                        resendSettingSource == "provider_recipe" && resendSettingOwner == owner && resendRecipeRef == recipeRef
                    }?.let { owner to mapOf(recipeRef to it) }
                }.toMap()
                options.copy(
                    generationParameters = if ("generation" in customOwners || "generation" in dormantOwners) null else generationParameterSettingsStore.resolve(
                        transient = baseRequestOptions.generationParameters,
                        providerID = provider.id,
                        modelID = modelId,
                        conversationID = conversation.id,
                        profileFingerprint = selectedModel?.let {
                            ai.oriveo.community.core.model.GenerationParameterProfileFingerprint.make(provider, it)
                        },
                        // An explicit reasoning choice on the chip makes the connection-level
                        // reasoning defaults step aside as a group.
                        reasoningMode = effectiveReasoningMode,
                        // Dormant values are stored but never dispatched. Passing null when the
                        // profile cannot be resolved means "do not filter": `apply` still falls
                        // back to the profile it resolves itself, so filtering on a guess here
                        // would silently drop values the user really can send.
                        activeParameterIds = outboundGenerationProfile?.let {
                            ai.oriveo.community.core.provider.GenerationParameterLifecycleRules
                                .declaredParameterIdsForFinalDispatch(it)
                        },
                    )?.let { overrides ->
                        val rejectedRoots = recipeRejectedSettings["generation"]
                            ?.values?.flatten().orEmpty()
                            .map { it.removePrefix("/") }.toSet()
                        overrides.copy(values = overrides.values.filterKeys { it !in rejectedRoots })
                            .takeIf { it.values.isNotEmpty() }
                    },
                    activeModel = selectedModel?.copy(generationProfile = outboundGenerationProfile),
                    capabilityPreferences = customTypedPreferences,
                    localCustomFragment = localCustomFragments["generation"],
                    localCustomFragments = localCustomFragments,
                    // Every provider carries the same identity carrier. It holds only opaque local
                    // generation/epoch/revision values and never reads or forwards a key; the real
                    // transport and endpoint are filled in by the dispatch layer, which fails
                    // closed when the scope is missing.
                    capabilityEvidenceIdentity = capabilityEvidenceIdentity(provider, modelId, evidencePartitionId),
                    modelControlRuntimeIdentity = modelControlIdentity,
                    rejectedRecipeSettings = recipeRejectedSettings,
                    rejectedCustomSettings = resendSettingOwner?.takeIf { resendSettingSource == "custom" }
                        ?.let { owner -> mapOf(owner to resendSettingPointers) }.orEmpty(),
                    dormantCapabilityOwners = dormantOwners,
                )
            }
            chatStreamingManager.startStream(
                StreamRequest(
                    conversation = conversation,
                    text = text,
                    provider = provider,
                    modelID = modelId,
                    existingMessages = existingMessages,
                    attachments = attachments,
                    quoteContext = quoteContext,
                    reasoningMode = customReasoningMode,
                    webSearchEnabled = effectiveWebSearchEnabled && "web" !in customOwners,
                    antiForgetText = antiForgetText,
                    requestOptions = requestOptions,
                    retrieval = promptInjection?.retrieval,
                    persistUserMessage = persistUserMessage,
                    userMessageAlreadyInHistory = userMessageAlreadyInHistory,
                    appendToAssistant = appendToAssistant,
                ),
            )
        }
    }

    private fun finalSystemPrompt(
        basePrompt: String,
        attachments: List<Attachment>?,
    ): String {
        val hasFileAttachments = attachments?.any { it.kind == ai.oriveo.community.core.model.AttachmentKind.File } ?: false
        if (!hasFileAttachments) return basePrompt
        return if (basePrompt.isBlank()) {
            AttachmentInjector.SYSTEM_PROMPT_GUIDANCE
        } else {
            basePrompt + "\n\n" + AttachmentInjector.SYSTEM_PROMPT_GUIDANCE
        }
    }
}
