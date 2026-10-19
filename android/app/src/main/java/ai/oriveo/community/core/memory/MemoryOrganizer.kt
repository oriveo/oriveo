package ai.oriveo.community.core.memory

import ai.oriveo.community.core.context.MemoryItems
import ai.oriveo.community.core.context.MemoryOrganizeRequest
import ai.oriveo.community.core.context.MemoryOrganizedItem
import ai.oriveo.community.core.context.RequestPurpose
import ai.oriveo.community.core.data.repository.ChatContextProjector
import ai.oriveo.community.core.data.repository.PlannedChatRequest
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource
import ai.oriveo.community.core.util.generateUuidString

/**
 * "Organize into items": sends a memory's body to the model per organizeRequest, collects the full reply, then organizeParse.
 * [complete] is one full request (returns the model's whole reply); unit tests inject a stand-in so no real Provider is hit.
 */
class MemoryOrganizer(private val complete: suspend (MemoryOrganizeRequest) -> String) {

    /** Returns an empty list when no items can be parsed; a failed request throws as usual so the caller can show the failure. */
    suspend fun organize(content: String): List<MemoryOrganizedItem> =
        MemoryItems.organizeParse(reply(content))

    /** The model's whole reply for one request (unparsed); callers use it to tell an "empty reply" from "parsed to empty". */
    suspend fun reply(content: String): String =
        complete(MemoryItems.organizeRequest(content))

    companion object {
        /** Production implementation: the same outbound path as "AI draft" (purpose memoryExtraction, non-streaming sendMessage). */
        fun forModel(providerRepository: ProviderRepository, provider: Provider, model: AIModel): MemoryOrganizer =
            MemoryOrganizer { request ->
                val service = providerRepository.serviceFor(provider, model)
                val transport = projection(request, provider, model).transportInput(ChatRequestOptions())
                service.sendMessage(
                    apiKey = ProviderCredentialResolver.apiKey(provider, model.id),
                    modelID = model.id,
                    messages = transport.messages,
                    baseUrl = OfficialEndpointSource.effectiveBaseUrlText(provider),
                    supportsImageGen = false,
                    reasoningMode = ReasoningMode.Automatic,
                    webSearchEnabled = false,
                    requestOptions = transport.options,
                ).result.text
            }

        /** The organize prompt goes into the purpose system; the item body is the only user message. */
        internal fun projection(request: MemoryOrganizeRequest, provider: Provider, model: AIModel): PlannedChatRequest =
            ChatContextProjector.projectPurpose(
                purpose = RequestPurpose.MEMORY_EXTRACTION,
                messages = request.messages.map { message ->
                    ChatMessage(
                        id = generateUuidString(),
                        role = message.role,
                        text = message.text,
                        providerID = provider.id,
                        providerKind = provider.kind,
                        providerName = provider.displayName,
                        modelID = model.id,
                        modelName = model.name,
                        state = ChatMessageState.Delivered,
                    )
                },
                window = ChatContextProjector.window(provider, model, ChatRequestOptions()),
                purposeSystem = request.system,
            )
    }
}
