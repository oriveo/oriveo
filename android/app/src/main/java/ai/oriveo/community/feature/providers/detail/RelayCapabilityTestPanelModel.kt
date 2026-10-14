package ai.oriveo.community.feature.providers.detail

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.RelayCapabilityTestItemResult
import ai.oriveo.community.core.provider.relay.RelayCapabilityTestKind
import ai.oriveo.community.core.provider.relay.RelayCapabilityTestReason
import ai.oriveo.community.core.provider.relay.RelayCapabilityTestStopReason
import ai.oriveo.community.core.provider.relay.RelayCapabilityVerdict

enum class RelayCapTestPhase { Running, Completed, Stopped }

enum class RelayCapTestIcon { Waiting, Running, Accepted, Rejected, Undetermined, NotRun }

enum class RelayCapTestButton { Cancel, Done }

sealed interface RelayCapTestHeader {
    /** In progress: item [current] (starting from 1) / [total] items in all. */
    data class Progress(val current: Int, val total: Int) : RelayCapTestHeader
    data object Done : RelayCapTestHeader
    data object Stopped : RelayCapTestHeader
}

/** The %s / %d argument in the subtitle: a status code, or a reason sentence (which may itself carry a status code). */
sealed interface RelayCapTestArg {
    data class Code(val code: Int) : RelayCapTestArg
    data class Text(@StringRes val res: Int, val code: Int? = null) : RelayCapTestArg
}

/** Row trailing: waiting / elapsed / running timer; [tenths] is tenths of a second, rounded half up to one decimal. */
sealed interface RelayCapTestTrailing {
    data object Waiting : RelayCapTestTrailing
    data class Elapsed(val tenths: Long) : RelayCapTestTrailing
    data class Running(val tenths: Long) : RelayCapTestTrailing
}

data class RelayCapTestRow(
    val kind: RelayCapabilityTestKind,
    val icon: RelayCapTestIcon,
    @StringRes val subtitle: Int?,
    val subtitleArg: RelayCapTestArg?,
    val trailing: RelayCapTestTrailing?,
)

/** One line at the bottom of the panel: when [plural] [res] is a plurals resource; [reason] is the interruption reason sentence. */
data class RelayCapTestFooter(
    val res: Int,
    val plural: Boolean = false,
    val count: Int? = null,
    val keyName: String? = null,
    @StringRes val reason: Int? = null,
)

data class RelayCapTestPresentation(
    val header: RelayCapTestHeader,
    /** Completed items / total items (completed state = total / total). */
    val progressFraction: Pair<Int, Int>,
    val transport: RelayTransport,
    /** Bound key name when there are 2+ keys (key chip); null for 1 key. */
    val keyName: String?,
    val rows: List<RelayCapTestRow>,
    val footer: RelayCapTestFooter,
    val button: RelayCapTestButton,
    /** Whether it can be swiped away / dismissed by tapping outside: not while in progress. */
    val dismissible: Boolean,
)

data class RelayCapTestPanelInput(
    val transport: RelayTransport,
    val items: List<RelayCapabilityTestKind>,
    val keyName: String?,
    val phase: RelayCapTestPhase,
    val results: List<RelayCapabilityTestItemResult>,
    val running: RelayCapabilityTestKind? = null,
    val runningElapsedMs: Long = 0L,
    val written: Boolean = false,
    val stopReason: RelayCapabilityTestStopReason? = null,
)

/** Pure display rules of the "Test capabilities" bottom panel (fixture `panelCases`). */
object RelayCapabilityTestPanelModel {
    fun present(input: RelayCapTestPanelInput): RelayCapTestPresentation {
        val total = input.items.size
        val results = input.results.associateBy { it.kind }
        val finished = input.items.count { it in results }
        val textFailed = results[RelayCapabilityTestKind.Text]?.let { it.verdict != RelayCapabilityVerdict.Accepted } == true
        val rows = input.items.map { kind ->
            val result = results[kind]
            when {
                result != null -> finishedRow(result, input.written)
                input.phase == RelayCapTestPhase.Running && kind == input.running ->
                    RelayCapTestRow(kind, RelayCapTestIcon.Running, runningRes(kind), null, RelayCapTestTrailing.Running(tenths(input.runningElapsedMs)))
                input.phase == RelayCapTestPhase.Running ->
                    RelayCapTestRow(kind, RelayCapTestIcon.Waiting, null, null, RelayCapTestTrailing.Waiting)
                input.phase == RelayCapTestPhase.Completed && textFailed ->
                    RelayCapTestRow(kind, RelayCapTestIcon.NotRun, R.string.relay_cap_test_not_run, null, null)
                else -> RelayCapTestRow(kind, RelayCapTestIcon.NotRun, R.string.relay_cap_test_not_tested, null, null)
            }
        }
        val header = when (input.phase) {
            RelayCapTestPhase.Running -> RelayCapTestHeader.Progress(
                current = input.running?.let { input.items.indexOf(it) + 1 }?.takeIf { it > 0 }
                    ?: (finished + 1).coerceAtMost(total),
                total = total,
            )
            RelayCapTestPhase.Completed -> RelayCapTestHeader.Done
            RelayCapTestPhase.Stopped -> RelayCapTestHeader.Stopped
        }
        // When a web-search item is listed, tell the user to use the sentence that includes the web-search billing note.
        val withWeb = RelayCapabilityTestKind.Web in input.items
        val footer = when (input.phase) {
            RelayCapTestPhase.Running -> if (input.keyName != null) {
                RelayCapTestFooter(
                    if (withWeb) R.plurals.relay_cap_test_info_web_named_key else R.plurals.relay_cap_test_info_named_key,
                    plural = true,
                    count = total,
                    keyName = input.keyName,
                )
            } else {
                RelayCapTestFooter(if (withWeb) R.plurals.relay_cap_test_info_web else R.plurals.relay_cap_test_info, plural = true, count = total)
            }
            RelayCapTestPhase.Completed ->
                RelayCapTestFooter(if (input.written) R.string.relay_cap_test_footer_saved else R.string.relay_cap_test_footer_nothing)
            RelayCapTestPhase.Stopped -> RelayCapTestFooter(
                R.string.relay_cap_test_stopped,
                reason = stopReasonRes(input.stopReason ?: RelayCapabilityTestStopReason.Cancelled),
            )
        }
        val running = input.phase == RelayCapTestPhase.Running
        return RelayCapTestPresentation(
            header = header,
            progressFraction = (if (input.phase == RelayCapTestPhase.Completed) total else finished) to total,
            transport = input.transport,
            keyName = input.keyName,
            rows = rows,
            footer = footer,
            button = if (running) RelayCapTestButton.Cancel else RelayCapTestButton.Done,
            dismissible = !running,
        )
    }

    /** Tenths of a second, rounded half up to one decimal. */
    fun tenths(elapsedMs: Long): Long = (elapsedMs.coerceAtLeast(0L) + 50L) / 100L

    @StringRes
    fun titleRes(kind: RelayCapabilityTestKind): Int = when (kind) {
        RelayCapabilityTestKind.Text -> R.string.relay_cap_test_item_text
        RelayCapabilityTestKind.Image -> R.string.relay_cap_test_item_image
        RelayCapabilityTestKind.Tool -> R.string.relay_cap_test_item_tool
        RelayCapabilityTestKind.Web -> R.string.relay_cap_test_item_web
    }

    private fun finishedRow(result: RelayCapabilityTestItemResult, written: Boolean): RelayCapTestRow {
        val kind = result.kind
        val trailing = RelayCapTestTrailing.Elapsed(tenths(result.elapsedMs))
        val text = kind == RelayCapabilityTestKind.Text
        // A web-search item gets its sentence from the probe result, regardless of whether it is written.
        if (kind == RelayCapabilityTestKind.Web) {
            when (result.verdict) {
                RelayCapabilityVerdict.Searched, RelayCapabilityVerdict.Accepted ->
                    return RelayCapTestRow(kind, RelayCapTestIcon.Accepted, R.string.model_options_relay_web_search_confirmed, null, trailing)
                RelayCapabilityVerdict.Silent, RelayCapabilityVerdict.NotObserved ->
                    return RelayCapTestRow(kind, RelayCapTestIcon.Undetermined, R.string.model_options_relay_web_no_search_in_test, null, trailing)
                RelayCapabilityVerdict.Rejected ->
                    return RelayCapTestRow(kind, RelayCapTestIcon.Rejected, R.string.model_options_relay_web_rejected, null, trailing)
                RelayCapabilityVerdict.Undetermined -> Unit
            }
        }
        return when (result.verdict) {
            RelayCapabilityVerdict.Accepted, RelayCapabilityVerdict.Searched -> RelayCapTestRow(
                kind,
                RelayCapTestIcon.Accepted,
                when {
                    text -> R.string.relay_cap_test_text_ok
                    written -> R.string.relay_cap_test_supported_saved
                    else -> R.string.relay_capability_test_supported
                },
                null,
                trailing,
            )
            RelayCapabilityVerdict.Rejected -> when {
                text && result.reason == RelayCapabilityTestReason.NotFound ->
                    RelayCapTestRow(kind, RelayCapTestIcon.Rejected, R.string.relay_cap_test_text_not_found, null, trailing)
                text -> RelayCapTestRow(
                    kind,
                    RelayCapTestIcon.Rejected,
                    R.string.relay_cap_test_text_rejected,
                    RelayCapTestArg.Code(result.status ?: 0),
                    trailing,
                )
                else -> RelayCapTestRow(
                    kind,
                    RelayCapTestIcon.Rejected,
                    when {
                        !written -> R.string.relay_capability_test_unsupported
                        kind == RelayCapabilityTestKind.Image -> R.string.relay_cap_test_image_rejected
                        else -> R.string.relay_cap_test_tool_rejected
                    },
                    null,
                    trailing,
                )
            }
            RelayCapabilityVerdict.Undetermined -> RelayCapTestRow(
                kind,
                RelayCapTestIcon.Undetermined,
                R.string.relay_cap_test_undetermined,
                reasonArg(result),
                trailing,
            )
            // 2xx but no evidence in the response: not confirmed, not written.
            RelayCapabilityVerdict.NotObserved, RelayCapabilityVerdict.Silent -> RelayCapTestRow(
                kind,
                RelayCapTestIcon.Undetermined,
                if (kind == RelayCapabilityTestKind.Image) {
                    R.string.relay_cap_test_image_not_observed
                } else {
                    R.string.relay_cap_test_tool_not_observed
                },
                null,
                trailing,
            )
        }
    }

    private fun reasonArg(result: RelayCapabilityTestItemResult): RelayCapTestArg.Text = when (result.reason) {
        RelayCapabilityTestReason.Unauthorized -> RelayCapTestArg.Text(R.string.relay_cap_test_reason_unauthorized)
        RelayCapabilityTestReason.Forbidden -> RelayCapTestArg.Text(R.string.relay_cap_test_reason_forbidden)
        RelayCapabilityTestReason.RateLimited -> RelayCapTestArg.Text(R.string.relay_cap_test_reason_rate_limited)
        RelayCapabilityTestReason.Html -> RelayCapTestArg.Text(R.string.relay_cap_test_reason_html)
        RelayCapabilityTestReason.Server -> RelayCapTestArg.Text(R.string.relay_cap_test_reason_server, result.status ?: 0)
        RelayCapabilityTestReason.Http -> RelayCapTestArg.Text(R.string.relay_cap_test_reason_http, result.status ?: 0)
        RelayCapabilityTestReason.Timeout -> RelayCapTestArg.Text(R.string.relay_cap_test_reason_timeout)
        RelayCapabilityTestReason.Network,
        RelayCapabilityTestReason.Ok,
        RelayCapabilityTestReason.UpstreamRejected,
        RelayCapabilityTestReason.NotFound,
        RelayCapabilityTestReason.NotObserved,
        -> RelayCapTestArg.Text(R.string.relay_cap_test_reason_network)
    }

    @StringRes
    private fun runningRes(kind: RelayCapabilityTestKind): Int = when (kind) {
        RelayCapabilityTestKind.Text -> R.string.relay_cap_test_running_text
        RelayCapabilityTestKind.Image -> R.string.relay_cap_test_running_image
        RelayCapabilityTestKind.Tool -> R.string.relay_cap_test_running_tool
        RelayCapabilityTestKind.Web -> R.string.relay_cap_test_running_web
    }

    @StringRes
    private fun stopReasonRes(reason: RelayCapabilityTestStopReason): Int = when (reason) {
        RelayCapabilityTestStopReason.Cancelled -> R.string.relay_cap_test_stop_cancelled
        RelayCapabilityTestStopReason.Connection -> R.string.relay_cap_test_stop_connection
        RelayCapabilityTestStopReason.Protocol -> R.string.relay_cap_test_stop_protocol
        RelayCapabilityTestStopReason.Unavailable -> R.string.relay_cap_test_stop_unavailable
    }
}
