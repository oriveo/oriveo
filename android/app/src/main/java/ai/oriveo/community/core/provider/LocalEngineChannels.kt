package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayTransport

/**
 * Channels of a local-engine connection (connection level) and the thinking write path.
 *
 * Looked up by `engineProfile` only, never guessed from the protocol or model name; returns null when `engineProfile` is empty or unknown,
 * and callers keep the existing Relay rules.
 */
object LocalEngineChannels {
    private val chat = RelayTransport.OpenAIChatCompletions
    private val native = RelayTransport.LlamaCppNative

    private val byEngine: Map<String, List<RelayTransport>> = mapOf(
        "llamacpp" to listOf(chat, native),
        "ollama" to listOf(chat),
        "lmstudio" to listOf(chat),
        "vllm" to listOf(chat),
        "openwebui" to listOf(chat),
    )

    /** The (engine, channel) pairs that can write `chat_template_kwargs.enable_thinking`; all other combinations in the table are not writable. */
    private val thinkingWritable: Set<Pair<String, RelayTransport>> = setOf("llamacpp" to chat)

    /** Channel candidates; null = not a local-engine connection, so the edit page keeps the full protocol menu. */
    fun candidates(engineProfile: String?): List<RelayTransport>? =
        engineProfile?.let(byEngine::get)

    /** The selector is not shown when there is only one candidate. */
    fun showsSelector(engineProfile: String?): Boolean =
        candidates(engineProfile)?.let { it.size > 1 } ?: true

    /** Whether the thinking switch can be written; null = this (engine, channel) pair is not in the write-path table. */
    fun thinkingWritable(engineProfile: String, channel: RelayTransport): Boolean? {
        val candidates = candidates(engineProfile) ?: return null
        if (channel !in candidates) return null
        return (engineProfile to channel) in thinkingWritable
    }
}
