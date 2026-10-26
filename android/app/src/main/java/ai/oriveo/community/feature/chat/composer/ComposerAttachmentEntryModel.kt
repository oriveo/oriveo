package ai.oriveo.community.feature.chat.composer

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.attachments.AttachmentRoute
import ai.oriveo.community.core.attachments.AttachmentRouter
import ai.oriveo.community.core.capability.InputCapabilityHintStore
import ai.oriveo.community.core.capability.truth.InputCapabilityProjections
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.AttachmentInputGate
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityDisabledReason
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityHint
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityProjection

/** Media item of the attachment menu; `key` is the media suffix of the reason / hint string keys. */
internal enum class ComposerAttachmentMedia(val key: String) {
    Image("image"),
    File("file"),
    Video("video"),
}

/**
 * One menu item: [shown] whether it appears in the menu, [enabled] whether it is tappable, [disabledReasonKey] the reason
 * string key when disabled (`capability_input_disabled_<reason>_<media>`), [firstAttachHint] whether a successful attach shows the first-time hint.
 */
internal data class ComposerAttachmentMenuItem(
    val media: ComposerAttachmentMedia,
    val shown: Boolean,
    val enabled: Boolean,
    val disabledReasonKey: String? = null,
    val firstAttachHint: Boolean = false,
    /**
     * Reason string key when the projection itself is unavailable (ignores the gate): the file item may stay tappable via text inlining,
     * but the reason native files are unavailable still belongs on the file card of the model options panel.
     */
    val nativeDisabledReasonKey: String? = null,
) {
    @get:StringRes
    val disabledReasonRes: Int? get() = disabledReasonKey?.let(::inputCapabilityStringRes)

    @get:StringRes
    val nativeDisabledReasonRes: Int? get() = nativeDisabledReasonKey?.let(::inputCapabilityStringRes)
}

/**
 * Pure model of the composer attachment entry: derives the image / file / video items from the input capability projection + entry gate.
 *
 * - With a projection: all three items are shown; unusable ones are visibly disabled with a reason, so the attach button stays even when all three are disabled.
 * - Without a projection: the legacy behavior: unsupported items are hidden, with no reason.
 * - Tappability reads [AttachmentInputGate]: the file item includes text inlining (not subject to file_input gating).
 * The camera item has the same availability as the image item and is hidden on devices without a camera, see [camera].
 */
internal data class ComposerAttachmentEntryModel(
    val image: ComposerAttachmentMenuItem,
    val file: ComposerAttachmentMenuItem,
    val video: ComposerAttachmentMenuItem,
) {
    val items: List<ComposerAttachmentMenuItem> get() = listOf(image, video, file)

    /** Whether the attach button is shown: shown if any item is shown (disabled items count too). */
    val showsEntry: Boolean get() = items.any { it.shown }

    fun camera(deviceHasCamera: Boolean): ComposerAttachmentMenuItem =
        image.copy(shown = image.shown && deviceHasCamera)

    fun item(kind: AttachmentKind): ComposerAttachmentMenuItem = when (kind) {
        AttachmentKind.Image -> image
        AttachmentKind.File -> file
        AttachmentKind.Video -> video
    }

    /**
     * One-line hint shown after the first successful attach of [attachment]; recorded once per `provider|model`, regardless of media.
     * Only media going through native parts hint: no hint and no record when that media's projection lacks first_attach_once (confirmed available / disabled);
     * files routed by [AttachmentRouter] through text inlining (not subject to file_input gating, always delivered) also neither hint nor record.
     */
    @StringRes
    fun firstAttachHintRes(
        attachment: Attachment,
        provider: Provider,
        model: AIModel,
        store: InputCapabilityHintStore,
    ): Int? {
        val item = item(attachment.kind)
        if (!item.firstAttachHint) return null
        if (attachment.kind == AttachmentKind.File &&
            AttachmentRouter.decide(attachment, provider.kind, model) != AttachmentRoute.Native
        ) {
            return null
        }
        if (!store.consume(provider.id, model.id)) return null
        return inputCapabilityStringRes("capability_input_hint_first_attach_${item.media.key}")
    }

    companion object {
        val NONE = from(projections = null, gate = AttachmentInputGate.NONE)

        fun from(projections: InputCapabilityProjections?, gate: AttachmentInputGate): ComposerAttachmentEntryModel =
            ComposerAttachmentEntryModel(
                image = menuItem(ComposerAttachmentMedia.Image, projections?.vision, gate.image),
                file = menuItem(ComposerAttachmentMedia.File, projections?.file, gate.file),
                video = menuItem(ComposerAttachmentMedia.Video, projections?.video, gate.video),
            )

        private fun menuItem(
            media: ComposerAttachmentMedia,
            projection: InputCapabilityProjection?,
            enabled: Boolean,
        ): ComposerAttachmentMenuItem {
            if (projection == null) return ComposerAttachmentMenuItem(media = media, shown = enabled, enabled = enabled)
            val nativeReasonKey = projection.disabledReason?.let { reasonKey(it, media) }
            if (enabled) {
                return ComposerAttachmentMenuItem(
                    media = media,
                    shown = true,
                    enabled = true,
                    firstAttachHint = projection.hint == InputCapabilityHint.FIRST_ATTACH_ONCE,
                    nativeDisabledReasonKey = nativeReasonKey,
                )
            }
            // Reason comes only from the projection (the Relay vision negative cache is already reported there as rejected_recently).
            return ComposerAttachmentMenuItem(
                media = media,
                shown = true,
                enabled = false,
                disabledReasonKey = nativeReasonKey,
                nativeDisabledReasonKey = nativeReasonKey,
            )
        }

        private fun reasonKey(reason: InputCapabilityDisabledReason, media: ComposerAttachmentMedia): String =
            "capability_input_disabled_${reason.keySegment}_${media.key}"

        private val InputCapabilityDisabledReason.keySegment: String
            get() = when (this) {
                InputCapabilityDisabledReason.MODEL_ABSENT -> "model_absent"
                InputCapabilityDisabledReason.WIRE_NOT_IMPLEMENTED -> "wire_not_implemented"
                InputCapabilityDisabledReason.KILL_SWITCH -> "kill_switch"
                InputCapabilityDisabledReason.REJECTED_RECENTLY -> "rejected_recently"
                InputCapabilityDisabledReason.USER_REMOVED -> "user_removed"
            }
    }
}

/** Reason / hint string key -> resource id (explicit table, no getIdentifier). */
@StringRes
private fun inputCapabilityStringRes(key: String): Int? = when (key) {
    "capability_input_disabled_model_absent_image" -> R.string.capability_input_disabled_model_absent_image
    "capability_input_disabled_model_absent_file" -> R.string.capability_input_disabled_model_absent_file
    "capability_input_disabled_model_absent_video" -> R.string.capability_input_disabled_model_absent_video
    "capability_input_disabled_wire_not_implemented_image" -> R.string.capability_input_disabled_wire_not_implemented_image
    "capability_input_disabled_wire_not_implemented_file" -> R.string.capability_input_disabled_wire_not_implemented_file
    "capability_input_disabled_wire_not_implemented_video" -> R.string.capability_input_disabled_wire_not_implemented_video
    "capability_input_disabled_kill_switch_image" -> R.string.capability_input_disabled_kill_switch_image
    "capability_input_disabled_kill_switch_file" -> R.string.capability_input_disabled_kill_switch_file
    "capability_input_disabled_kill_switch_video" -> R.string.capability_input_disabled_kill_switch_video
    "capability_input_disabled_rejected_recently_image" -> R.string.capability_input_disabled_rejected_recently_image
    "capability_input_disabled_rejected_recently_file" -> R.string.capability_input_disabled_rejected_recently_file
    "capability_input_disabled_rejected_recently_video" -> R.string.capability_input_disabled_rejected_recently_video
    "capability_input_disabled_user_removed_image" -> R.string.capability_input_disabled_user_removed_image
    "capability_input_disabled_user_removed_file" -> R.string.capability_input_disabled_user_removed_file
    "capability_input_disabled_user_removed_video" -> R.string.capability_input_disabled_user_removed_video
    "capability_input_hint_first_attach_image" -> R.string.capability_input_hint_first_attach_image
    "capability_input_hint_first_attach_file" -> R.string.capability_input_hint_first_attach_file
    "capability_input_hint_first_attach_video" -> R.string.capability_input_hint_first_attach_video
    else -> null
}
