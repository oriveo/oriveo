package ai.oriveo.community.feature.providers.manual

import androidx.annotation.StringRes
import ai.oriveo.community.R

/*
 * "Add model manually" page (ManualModel board): relays and official providers share one page and one layout -
 * one input slot + a description under it; no Hero, preview card, example list or "default capabilities" badge. The view renders strictly from [ManualModelBoardModel.make].
 */

internal enum class ManualModelBlock { ModelSlot, Notes }

internal data class ManualModelBoard(
    val blocks: List<ManualModelBlock>,
    @StringRes val titleRes: Int,
    /** Slot title, also the input slot's screen-reader name. */
    @StringRes val slotTitleRes: Int,
    /** Relay: the flagship model ID delivered by the server (not a hint text); null for official providers, which use [placeholderRes]. */
    val placeholder: String?,
    @StringRes val placeholderRes: Int?,
    val notes: List<Int>,
    @StringRes val primaryRes: Int,
    /** "Retry sync" for official providers; relays have none. */
    @StringRes val secondaryRes: Int?,
    val primaryEnabled: Boolean,
    /** The clear button follows whether the slot has any text (shown even for spaces only). */
    val showsClear: Boolean,
    /** The model ID still runs left to right in RTL languages. */
    val slotIsLtr: Boolean = true,
)

internal object ManualModelBoardModel {
    fun make(isRelay: Boolean, modelID: String, isSaving: Boolean, relayPlaceholder: String): ManualModelBoard =
        ManualModelBoard(
            blocks = listOf(ManualModelBlock.ModelSlot, ManualModelBlock.Notes),
            titleRes = if (isRelay) R.string.add_model else R.string.manual_model_entry_title,
            slotTitleRes = R.string.model_id_label,
            placeholder = relayPlaceholder.takeIf { isRelay },
            placeholderRes = if (isRelay) null else R.string.model_id_placeholder,
            notes = if (isRelay) {
                listOf(R.string.relay_manual_model_entry_note_exact, R.string.relay_manual_model_entry_note_capabilities)
            } else {
                listOf(R.string.model_id_footnote)
            },
            primaryRes = if (isRelay) R.string.save else R.string.save_and_continue,
            secondaryRes = if (isRelay) null else R.string.retry_sync,
            primaryEnabled = modelID.isNotBlank() && !isSaving,
            showsClear = modelID.isNotEmpty(),
        )
}
