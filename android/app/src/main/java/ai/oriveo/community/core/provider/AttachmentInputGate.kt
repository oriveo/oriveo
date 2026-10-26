package ai.oriveo.community.core.provider

/**
 * Which inputs the current connection x model can attach: images / native files / video follow the editable flag of the input capability projection,
 * while inline text files are not gated by file_input. Relay reads the envelope (no envelope means attachable); official providers read metadata.
 * Produced by [ai.oriveo.community.feature.chat.ChatModelCapabilityResolver.attachmentInputGate].
 */
data class AttachmentInputGate(
    val image: Boolean = false,
    val nativeFile: Boolean = false,
    val textFileInline: Boolean = false,
    val video: Boolean = false,
) {
    val file: Boolean get() = nativeFile || textFileInline

    companion object {
        val NONE = AttachmentInputGate()
    }
}
