package ai.oriveo.community.core.mcp

/** The parameters of `WWW-Authenticate: Bearer ...` that matter here. */
data class McpAuthChallenge(
    val resourceMetadata: String? = null,
    val scope: String? = null,
    val error: String? = null,
    val errorDescription: String? = null,
)

object McpWwwAuthenticate {
    /**
     * Parses `WWW-Authenticate` (RFC 7235 auth-param). Header names compare case-insensitively; only the value is
     * parsed here.
     */
    fun parse(header: String?): McpAuthChallenge? {
        if (header.isNullOrBlank()) return null
        val space = header.indexOf(' ')
        if (space < 0) return McpAuthChallenge()
        var challenge = McpAuthChallenge()
        for (token in splitAuthParams(header.substring(space + 1))) {
            val equals = token.indexOf('=')
            if (equals < 0) continue
            val name = token.substring(0, equals).trim().lowercase()
            var value = token.substring(equals + 1).trim()
            if (value.length >= 2 && value.startsWith("\"") && value.endsWith("\"")) {
                value = value.substring(1, value.length - 1)
            }
            challenge = when (name) {
                "resource_metadata" -> challenge.copy(resourceMetadata = value.takeIf { McpOrigin.parse(it) != null })
                "scope" -> challenge.copy(scope = value)
                "error" -> challenge.copy(error = value)
                "error_description" -> challenge.copy(errorDescription = value)
                else -> challenge
            }
        }
        return challenge
    }

    /**
     * Splits on commas, except commas inside quotes (a scope value may contain spaces, an error_description may contain
     * commas).
     */
    private fun splitAuthParams(text: String): List<String> {
        val result = mutableListOf<String>()
        var start = 0
        var inQuotes = false
        for (index in text.indices) {
            val character = text[index]
            if (character == '"') {
                inQuotes = !inQuotes
            } else if (character == ',' && !inQuotes) {
                result += text.substring(start, index)
                start = index + 1
            }
        }
        result += text.substring(start)
        return result
    }
}

/** Maps 401 / 403 responses onto the probe state machine. */
object McpAuthResponseMapping {
    /**
     * Step-up (re-authorizing for a larger scope) is not implemented yet; a 403 `insufficient_scope` is handled as
     * `needs_auth`.
     */
    const val STEP_UP_IMPLEMENTED = false

    fun needsAuthErrorCode(status: Int, wwwAuthenticate: String?): McpErrorCode? {
        if (status == 401) return McpErrorCode.NeedsAuth
        if (status == 403 && McpWwwAuthenticate.parse(wwwAuthenticate)?.error == "insufficient_scope") {
            return McpErrorCode.NeedsAuth
        }
        return null
    }
}
