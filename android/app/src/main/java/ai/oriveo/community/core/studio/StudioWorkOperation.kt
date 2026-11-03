package ai.oriveo.community.core.studio

/**
 * What the composer starts for the current context (studio_data_model.v1 operationTable): the round operation,
 * which image becomes its base, whether the first subject image is imported as v1 first, or why the selected
 * model cannot run. Values are the fixture wire strings.
 */
data class StudioWorkOperation(
    val operation: String?,
    val base: String?,
    val importFirst: Boolean,
    val blocked: String? = null,
) {
    companion object {
        const val OPERATION_GENERATE = "generate"
        const val OPERATION_EDIT = "edit"
        const val BASE_CURRENT_VERSION = "current_version"
        const val BASE_FIRST_SUBJECT_AS_V1 = "first_subject_as_v1"
        const val BLOCKED_CANNOT_REFERENCE_IMAGES = "model_cannot_reference_images"
        const val BLOCKED_NEEDS_IMAGE = "model_needs_image"
        const val ROLE_SUBJECT = "subject"

        /** [images] = reference roles in composer order; [modelOps] = operations the selected model supports. */
        fun resolve(inWorkDetail: Boolean, images: List<String>, modelOps: Collection<String>): StudioWorkOperation {
            val hasImages = inWorkDetail || images.isNotEmpty()
            return when {
                hasImages && OPERATION_EDIT !in modelOps ->
                    StudioWorkOperation(null, null, importFirst = false, blocked = BLOCKED_CANNOT_REFERENCE_IMAGES)
                !hasImages && OPERATION_GENERATE !in modelOps ->
                    StudioWorkOperation(null, null, importFirst = false, blocked = BLOCKED_NEEDS_IMAGE)
                inWorkDetail -> StudioWorkOperation(OPERATION_EDIT, BASE_CURRENT_VERSION, importFirst = false)
                images.isEmpty() -> StudioWorkOperation(OPERATION_GENERATE, null, importFirst = false)
                ROLE_SUBJECT in images ->
                    StudioWorkOperation(OPERATION_EDIT, BASE_FIRST_SUBJECT_AS_V1, importFirst = true)
                else -> StudioWorkOperation(OPERATION_EDIT, null, importFirst = false)
            }
        }
    }
}
