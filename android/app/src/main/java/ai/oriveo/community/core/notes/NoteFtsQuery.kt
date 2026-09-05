package ai.oriveo.community.core.notes


object NoteFtsQuery {

    
    private val TERM = Regex("[\\p{L}\\p{N}]+")

    
    fun build(raw: String): String? {
        val terms = TERM.findAll(raw).map { it.value }.filter { it.isNotBlank() }.toList()
        if (terms.isEmpty()) return null
        return terms.joinToString(" ") { term ->
            val escaped = term.replace("\"", "\"\"")
            "\"$escaped\"*"
        }
    }

    
    fun buildAnyTermPrefix(terms: List<String>): String? {
        val valid = terms.filter { TERM.matches(it) }
        if (valid.isEmpty()) return null
        return valid.joinToString(" OR ") { "\"$it\"*" }
    }
}
