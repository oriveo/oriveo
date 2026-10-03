package ai.oriveo.community.core.mcp

import kotlinx.serialization.Serializable

// Tool steps recorded on a message.
//
// Summary only: server name, tool, argument summary, status. Raw arguments and results live in `mcp_step_payload`.

@Serializable
data class McpToolStep(
    val id: String,
    /** Always `mcp`; leaves room for other sources later. */
    val scope: String = SCOPE_MCP,
    /** Lowercase UUID. */
    val serverId: String,
    /** Stored redundantly so the record stays readable after the server is removed. */
    val serverName: String,
    val toolName: String,
    val title: String,
    val argsSummary: String,
    /** Wire value of [McpToolStepUpdate.Status]; kept as a string so an unknown value drops only this item, not the whole message. */
    val status: String,
    /** A code from the closed error-code set; the server's raw error text is never stored. */
    val errorCode: String? = null,
    val step: Int,
    val durationMs: Int? = null,
) {
    val statusValue: McpToolStepUpdate.Status?
        get() = McpToolStepUpdate.Status.entries.firstOrNull { it.wireValue == status }

    /** Display title: falls back to the raw tool name when the server gave no title. */
    val displayTitle: String get() = title.ifEmpty { toolName }

    /**
     * Turns steps still marked `running` into `interrupted`: when the process was killed, nobody is left to move
     * them to a terminal state.
     */
    val interruptedIfRunning: McpToolStep
        get() = if (status == McpToolStepUpdate.Status.Running.wireValue) {
            copy(status = McpToolStepUpdate.Status.Interrupted.wireValue, errorCode = McpErrorCode.Interrupted.wireValue)
        } else {
            this
        }

    companion object {
        const val SCOPE_MCP = "mcp"

        /** One status callback from the executor → the summary on the message. Payload, permission and read-only hint are not carried over. */
        fun from(update: McpToolStepUpdate): McpToolStep = McpToolStep(
            id = update.id,
            serverId = update.serverId.lowercase(),
            serverName = update.serverName,
            toolName = update.toolName,
            title = update.title,
            argsSummary = update.argsSummary,
            status = update.status.wireValue,
            errorCode = update.errorCode?.wireValue,
            step = update.step,
            durationMs = update.durationMs,
        )

        /** Merges one callback into the existing steps: replaces the step with the same id, otherwise appends. */
        fun merging(update: McpToolStepUpdate, into: List<McpToolStep>): List<McpToolStep> {
            val step = from(update)
            val index = into.indexOfFirst { it.id == step.id }
            return if (index >= 0) into.toMutableList().also { it[index] = step } else into + step
        }

        /** Returns the original list (same reference) when no step needs changing. */
        fun interruptingRunning(steps: List<McpToolStep>): List<McpToolStep> =
            if (steps.none { it.status == McpToolStepUpdate.Status.Running.wireValue }) steps else steps.map { it.interruptedIfRunning }
    }
}
