package ai.oriveo.community.core.provider

/**
 * Outbound max_tokens resolution: explicit value > model maxOutputTokens > protocol default.
 * The protocol default only applies to protocols that require max_tokens (Anthropic Messages, including MiniMax / Relay Anthropic / library legs);
 * protocols where it is optional (OpenAI Chat etc.) do not get a default here. An unmeasured model value (null / non-positive) counts as unknown and falls to the protocol default.
 */
object MaxOutputTokensPolicy {
    /** The Anthropic Messages protocol requires max_tokens; used when neither an explicit value nor a model value exists. */
    const val ANTHROPIC_MESSAGES_DEFAULT = 8192

    fun anthropicMessages(explicit: Int?, modelMaxOutputTokens: Int?): Int =
        explicit?.takeIf { it > 0 }
            ?: modelMaxOutputTokens?.takeIf { it > 0 }
            ?: ANTHROPIC_MESSAGES_DEFAULT
}
