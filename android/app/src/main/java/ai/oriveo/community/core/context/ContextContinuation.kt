package ai.oriveo.community.core.context

import ai.oriveo.community.core.model.ChatRole

/** How a stateful leg treats `instructions` next to `previous_response_id` (wire-system.v1 continuationCases). */
enum class ContinuationInstructionsMode(val wire: String) {
    RESEND("resend"),
    OMIT("omit"),
    ;

    companion object {
        /** Null or unknown wire means the provider did not declare a mode: no stateful continuation. */
        fun fromWire(wire: String?): ContinuationInstructionsMode? = entries.firstOrNull { it.wire == wire }
    }
}

/** What the host knows about the previous leg when continuing. */
data class ContinuationState(
    val previousResponseId: String?,
    val instructionsMode: ContinuationInstructionsMode?,
    val systemChangedSinceLastLeg: Boolean,
    val modelChanged: Boolean,
    val checkpointChanged: Boolean,
)

sealed interface ContinuationDecision {
    /** Send the whole plan: instructions plus history plus the continue prompt. */
    data object FullPlan : ContinuationDecision

    /** Chain on the previous response; send only the continue prompt. */
    data class Stateful(val previousResponseId: String, val sendInstructions: Boolean) : ContinuationDecision
}

data class ContinuationTurn(val role: ChatRole, val text: String)

/** Wire-level projection: `instructions`, `previous_response_id` and `input`. */
data class ContinuationRequest(
    val instructions: String?,
    val previousResponseId: String?,
    val input: List<ContinuationTurn>,
)

/** Pure function deciding stateful continuation; the rules are the continuationCases in wire-system.v1.json. */
object ContextContinuation {

    fun decide(state: ContinuationState): ContinuationDecision {
        val previous = state.previousResponseId?.takeIf { it.isNotEmpty() } ?: return ContinuationDecision.FullPlan
        val mode = state.instructionsMode ?: return ContinuationDecision.FullPlan
        if (state.systemChangedSinceLastLeg || state.modelChanged || state.checkpointChanged) {
            return ContinuationDecision.FullPlan
        }
        return ContinuationDecision.Stateful(previous, sendInstructions = mode == ContinuationInstructionsMode.RESEND)
    }

    fun project(
        decision: ContinuationDecision,
        system: String?,
        history: List<ContinuationTurn>,
        current: String,
    ): ContinuationRequest {
        val prompt = ContinuationTurn(ChatRole.User, current)
        return when (decision) {
            ContinuationDecision.FullPlan -> ContinuationRequest(system, null, history + prompt)
            is ContinuationDecision.Stateful -> ContinuationRequest(
                instructions = if (decision.sendInstructions) system else null,
                previousResponseId = decision.previousResponseId,
                input = listOf(prompt),
            )
        }
    }
}
