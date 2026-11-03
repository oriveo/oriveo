package ai.oriveo.community.core.studio

/**
 * Mechanical model id normalization (shared contract model-contracts/model_id_normalization.v1.json):
 * trim, lowercase, drop everything up to the last "/", drop one trailing date suffix
 * (-YYYY-MM-DD or -YYYYMMDD). Nothing else: aliases such as -preview / -latest / community names
 * are resolved by the Server alias table, never here. The result is only a lookup key; the wire
 * always sends the id exactly as the connection lists it.
 */
object ModelIdNormalization {
    private val trailingDate = Regex("-(?:\\d{4}-\\d{2}-\\d{2}|\\d{8})$")

    fun normalize(raw: String): String {
        val lowered = raw.trim().lowercase()
        val unprefixed = lowered.substring(lowered.lastIndexOf('/') + 1)
        return trailingDate.replace(unprefixed, "")
    }
}
