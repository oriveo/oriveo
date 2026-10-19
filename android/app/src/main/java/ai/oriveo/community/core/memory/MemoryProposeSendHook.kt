package ai.oriveo.community.core.memory

/**
 * P10 rules 4-6: what the chat send reports back about propose_memory on one fresh send in tool mode.
 * The tool itself rides [ai.oriveo.community.core.model.ChatRequestOptions.clientTools]; candidate writing, the
 * suggestion bar and the fallback stay with the implementation (feature layer).
 */
interface MemoryProposeSendHook {
    /** One propose_memory call of this turn (first or tail leg), in call order; failures stay inside the hook. */
    suspend fun onProposeCall(argumentsJson: String)

    /** Rule 6: the first leg carrying tools was deterministically rejected and is resent once without tools. */
    suspend fun onToolsRejected()
}
