package ai.oriveo.community.feature.chat.modelcontrols

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.AdditionalRequestBody
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver

/** Reads, writes and copy selection for the additional request body page. Storage goes only through `additionalBody` / `setAdditionalBody` and validation only through the production [AdditionalRequestBody]. */
internal object AdditionalBodyEditor {
    /** The same key as the send path (`ChatSendCoordinator`): the canonical model id when a runtime identity exists. */
    fun modelKey(provider: Provider, model: AIModel): String =
        ModelControlRuntimeIdentityResolver.resolve(provider, model)?.canonicalModelId ?: model.id

    fun load(store: LocalCapabilityCustomFragmentStore, provider: Provider, model: AIModel, conversationId: String?) =
        store.additionalBody(provider.id, modelKey(provider, model), conversationId)

    fun save(
        store: LocalCapabilityCustomFragmentStore,
        provider: Provider,
        model: AIModel,
        conversationId: String?,
        body: LocalCapabilityCustomFragmentStore.AdditionalBody,
    ) = store.setAdditionalBody(body, provider.id, modelKey(provider, model), conversationId)

    /** The "N fields" on the entry row: how many leaf fields join the request; 0 when the syntax is invalid. */
    fun fieldCount(raw: String?): Int =
        AdditionalRequestBody.preview(raw).entries.count { it.status == AdditionalRequestBody.PreviewStatus.Included }

    /** The additional request body entry row in the advanced settings: carries a summary when it can be entered. */
    data class EntryRow(val enterable: Boolean, @StringRes val trailingRes: Int, val fieldCount: Int? = null)

    fun entryRow(sendWithRequest: Boolean, fieldCount: Int): EntryRow =
        when {
            sendWithRequest && fieldCount > 0 -> EntryRow(true, R.string.advanced_fields_count, fieldCount)
            else -> EntryRow(true, R.string.advanced_not_in_use)
        }

    /** The reason sentence for "cannot be changed": it says per field who fills it in, rather than a vague "protected". */
    @StringRes
    fun reasonRes(entry: AdditionalRequestBody.PreviewEntry): Int = when (entry.status) {
        AdditionalRequestBody.PreviewStatus.BlockedName -> R.string.additional_body_field_name_invalid
        AdditionalRequestBody.PreviewStatus.Included,
        AdditionalRequestBody.PreviewStatus.Protected,
        -> when (entry.path) {
            "messages", "input", "contents", "prompt" -> R.string.additional_body_conversation_filled
            "attachments" -> R.string.additional_body_attachments_filled
            "instructions", "system" -> R.string.additional_body_system_prompt_filled
            "tools", "tool_choice", "plugins" -> R.string.additional_body_tools_managed
            "model" -> R.string.additional_body_model_chosen
            "stream", "stream_options" -> R.string.additional_body_streaming_by_oriveo
            else -> R.string.additional_body_field_filled
        }
    }

    data class EngineDocs(val engineName: String, val url: String)

    @StringRes
    val ENGINE_DOCS_LINK_RES: Int = R.string.additional_body_docs_link

    /** Each local engine's documentation on which fields it supports; other connections get no link. Only the connection's declared engineProfile is read. */
    fun engineDocs(provider: Provider): EngineDocs? = when (provider.relayRequested?.engineProfile) {
        "llamacpp" -> EngineDocs("llama.cpp", "https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md")
        "ollama" -> EngineDocs("Ollama", "https://docs.ollama.com/api/openai-compatibility")
        "lmstudio" -> EngineDocs("LM Studio", "https://lmstudio.ai/docs/developer/openai-compat/chat-completions")
        "vllm" -> EngineDocs("vLLM", "https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/")
        else -> null
    }
}
