package ai.oriveo.community.core.mcp

// Presentation rules for the tool-steps block.
//
// Pure function: the message's `toolSteps` + whether the message is still generating → what the block shows.
// The UI only draws the result; copy is resolved per language in the UI layer.

data class McpToolStepsPresentation(
    val header: Header,
    val trailing: Trailing,
    val rows: List<Row>,
    /** Running / waiting for authorization: expanded by default. */
    val isActive: Boolean,
    /** The step waiting for re-authorization (the block offers "Re-authorize / Skip this step"). */
    val pausedForSignIn: McpToolStep?,
    /** Step limit reached: explained in a trailing row inside the block. */
    val limitReached: Boolean,
) {
    sealed interface Header {
        /** "Using tools". */
        data object Running : Header

        /** "Waiting for re-authorization": the loop is parked on a tool that needs a fresh sign-in. */
        data object WaitingForSignIn : Header

        /** "Used N tools": N counts steps that actually completed (denied, failed and interrupted ones do not count). */
        data class Finished(val usedCount: Int) : Header
    }

    sealed interface Trailing {
        /** "Step N". */
        data class Step(val number: Int) : Trailing

        /** Server names, de-duplicated in order of first appearance. */
        data class Servers(val names: List<String>) : Trailing

        data class Declined(val count: Int) : Trailing

        data class Failed(val count: Int) : Trailing
    }

    sealed interface RowDetail {
        /** Argument summary (may be empty). */
        data class ArgsSummary(val text: String) : RowDetail

        data object Declined : RowDetail

        data object Interrupted : RowDetail

        data class SignInExpired(val serverName: String) : RowDetail

        /** Failed: the explanation is looked up by the closed-set error code. */
        data class Failure(val code: String?) : RowDetail
    }

    data class Row(
        val id: String,
        val step: McpToolStep,
        /** Display status: once the message is no longer generating, `running` is always drawn as `interrupted`. */
        val status: McpToolStepUpdate.Status,
        val detail: RowDetail,
        /** Finished steps can be tapped to open the single-step detail. */
        val opensDetail: Boolean,
    )

    /** Number of rows hidden when earlier steps are collapsed; 0 when nothing needs collapsing. */
    val hiddenEarlierCount: Int
        get() = if (rows.size > COLLAPSE_THRESHOLD) rows.size - TAIL_COUNT_WHEN_COLLAPSED else 0

    companion object {
        /** With more steps than this, the earlier ones collapse into "Show previous N steps". */
        const val COLLAPSE_THRESHOLD = 5

        /** Number of trailing steps kept visible when collapsed. */
        const val TAIL_COUNT_WHEN_COLLAPSED = 2

        fun make(
            steps: List<McpToolStep>,
            isGenerating: Boolean,
            limitReached: Boolean = false,
            pausedStepId: String? = null,
        ): McpToolStepsPresentation {
            val rows = steps.map { step ->
                // An unknown status (written by a future version) is drawn as interrupted: it is certainly not running on this device.
                val stored = step.statusValue ?: McpToolStepUpdate.Status.Interrupted
                val status = if (stored == McpToolStepUpdate.Status.Running && !isGenerating) {
                    McpToolStepUpdate.Status.Interrupted
                } else {
                    stored
                }
                Row(
                    id = step.id,
                    step = step,
                    status = status,
                    detail = detail(step, status),
                    opensDetail = status != McpToolStepUpdate.Status.Running,
                )
            }
            val paused = if (isGenerating) pausedStepId?.let { id -> steps.firstOrNull { it.id == id } } else null
            val running = rows.lastOrNull { it.status == McpToolStepUpdate.Status.Running }
            val latestStep = rows.maxOfOrNull { it.step.step } ?: 0

            val header: Header
            val trailing: Trailing
            when {
                paused != null -> {
                    header = Header.WaitingForSignIn
                    trailing = Trailing.Step(paused.step)
                }
                running != null -> {
                    header = Header.Running
                    trailing = Trailing.Step(running.step.step)
                }
                // Between two steps (the model is deciding what to do next): still in progress, reuse the latest step's number.
                isGenerating -> {
                    header = Header.Running
                    trailing = Trailing.Step(latestStep)
                }
                else -> {
                    header = Header.Finished(rows.count { it.status == McpToolStepUpdate.Status.Done })
                    val failed = rows.count {
                        it.status == McpToolStepUpdate.Status.Failed || it.status == McpToolStepUpdate.Status.NeedsAuth
                    }
                    val declined = rows.count { it.status == McpToolStepUpdate.Status.Denied }
                    trailing = when {
                        failed > 0 -> Trailing.Failed(failed)
                        declined > 0 -> Trailing.Declined(declined)
                        else -> Trailing.Servers(steps.map { it.serverName }.filter { it.isNotEmpty() }.distinct())
                    }
                }
            }
            return McpToolStepsPresentation(
                header = header,
                trailing = trailing,
                rows = rows,
                isActive = isGenerating,
                pausedForSignIn = paused,
                limitReached = limitReached,
            )
        }

        private fun detail(step: McpToolStep, status: McpToolStepUpdate.Status): RowDetail = when (status) {
            McpToolStepUpdate.Status.Running, McpToolStepUpdate.Status.Done -> RowDetail.ArgsSummary(step.argsSummary)
            McpToolStepUpdate.Status.Denied -> RowDetail.Declined
            McpToolStepUpdate.Status.Interrupted -> RowDetail.Interrupted
            McpToolStepUpdate.Status.NeedsAuth -> RowDetail.SignInExpired(step.serverName)
            McpToolStepUpdate.Status.Failed -> RowDetail.Failure(step.errorCode)
        }
    }
}
