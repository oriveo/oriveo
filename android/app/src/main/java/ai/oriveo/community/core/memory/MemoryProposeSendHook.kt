package ai.oriveo.community.core.memory

/**
 * What the chat send reports back about propose_memory on one fresh send in tool mode.
 * The tool itself rides [ai.oriveo.community.core.model.ChatRequestOptions.clientTools]; candidate writing, the
 * suggestion bar and the fallback stay with the implementation (feature layer).
 */
interface MemoryProposeSendHook {
    /** One propose_memory call of this turn (first or tail leg), in call order; failures stay inside the hook. */
    suspend fun onProposeCall(argumentsJson: String)

    /** Rule 6: the first leg carrying tools was deterministically rejected and is resent once without tools. */
    suspend fun onToolsRejected()

    /**
     * The send was judged tool mode but its final request carries no propose_memory (image generation routes,
     * non-streaming Relay): run the same fallback as [onToolsRejected], without degrading the connection.
     * At most once per message together with [onToolsRejected].
     */
    suspend fun onToolsNotAttached() {}
}
