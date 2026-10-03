package ai.oriveo.community.core.mcp

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject

// Local model layer for remote MCP.
//
// Server records, device-local state, slug rules, runtime configuration, the closed set of error codes, and tool
// definitions and protocol constants. Credentials live in `McpCredentialStore.kt`.

/** The sign-in method chosen by the user. */
enum class McpAuthKind(val wireValue: String) {
    /** The probe succeeded without signing in. */
    Auto("auto"),

    /** The user pastes an access token. */
    Token("token"),
    ;

    companion object {
        fun fromWireValue(value: String): McpAuthKind? = entries.firstOrNull { it.wireValue == value }
    }
}

/** A server record. Credentials go to secure storage separately. */
data class McpServerRecord(
    val id: String,
    val name: String,
    val slug: String,
    val url: String,
    val authKind: McpAuthKind,
    /**
     * True when the address looks like it carries a secret. The database then holds only a display address, and the
     * full one lives in the credential store.
     */
    val localOnly: Boolean,
    val iconURL: String?,
    val createdAt: Long,
    val updatedAt: Long,
) {
    companion object {
        /** `url` <= 2048 (UTF-8 bytes), `name` <= 64 (UTF-16 code units). */
        const val MAX_URL_LENGTH = 2048
        const val MAX_NAME_LENGTH = 64
    }
}

/**
 * Everything one addition persists ([McpServerStore.addServer]). The slug is not here: it is generated inside the write
 * transaction. [url] is the full address; for `localOnly` records the storage layer persists only the display address.
 */
data class McpServerAddition(
    val id: String,
    val name: String,
    val url: String,
    val authKind: McpAuthKind,
    val localOnly: Boolean,
    val iconURL: String?,
    val createdAt: Long,
    val snapshots: List<McpToolSnapshot>,
    val permissions: Map<String, McpToolPermission>,
    val connectionState: McpConnectionState,
    /**
     * "Pending confirmation": true when the add flow persists the record, cleared only when the user taps "Done" on the
     * default-permissions step ([McpServerStore.confirmAddition]). A record carrying it is not listed and is swept at
     * startup.
     */
    val pendingAdd: Boolean = false,
)

/** Storage-layer errors. Hitting the limit and a slug collision are both user-correctable states, so the UI must be able to tell them apart. */
sealed class McpStoreError(message: String) : Exception(message) {
    class LimitReached(val max: Int) : McpStoreError("MCP server limit reached: $max")

    class SlugConflict(val slug: String) : McpStoreError("MCP server slug already in use: $slug")

    /** The primary key already exists. The existing record is unaffected. */
    class ServerExists(val id: String) : McpStoreError("MCP server already exists")
}

/**
 * Slug generation (fixture: `shared/test-fixtures/mcp/identifiers.json`).
 *
 * The slug is the prefix of the tool names sent to the model. The web validation regex and upstream providers only accept
 * `[a-z0-9]`, so **`-` never appears**, and the rules are literally identical on the other clients.
 */
object McpSlug {
    const val MAX_LENGTH = 16
    const val FALLBACK = "server"

    /**
     * `A-Z` map to their lowercase letters, `a-z` and `0-9` are kept, everything else is **dropped**; truncated to 16;
     * `server` when the result is empty.
     *
     * The mapping is deliberately written out per character instead of calling `lowercase()`: Unicode case folding turns
     * the Kelvin sign `K` (U+212A) into `k` and `İ` into `i̇`, and the folding tables differ between platforms, so the
     * same name would produce different prefixes.
     */
    fun make(name: String): String {
        val result = StringBuilder()
        for (character in name) {
            when (character) {
                in 'a'..'z', in '0'..'9' -> result.append(character)
                in 'A'..'Z' -> result.append(character + ('a' - 'A'))
                else -> Unit
            }
            if (result.length == MAX_LENGTH) break
        }
        return if (result.isEmpty()) FALLBACK else result.toString()
    }

    /** `[a-z0-9]{1,16}`. */
    fun isValid(slug: String): Boolean =
        slug.length in 1..MAX_LENGTH && slug.all { it in 'a'..'z' || it in '0'..'9' }

    /**
     * Picks a unique value against the existing slugs: on a collision `n` counts up from 2, and the first
     * `16 - digits(n)` characters of the candidate are followed by `n` (a purely numeric suffix, no separator).
     */
    fun unique(name: String, existing: Set<String>): String {
        val candidate = make(name)
        if (candidate !in existing) return candidate
        var index = 2
        while (true) {
            val suffix = index.toString()
            val next = candidate.take(MAX_LENGTH - suffix.length) + suffix
            if (next !in existing) return next
            index += 1
        }
    }
}

/** Connection status. */
enum class McpConnectionStatus(val wireValue: String) {
    Connected("connected"),
    NeedsAuth("needsAuth"),
    Unreachable("unreachable"),
    Unknown("unknown"),
    ;

    companion object {
        fun fromWireValue(value: String): McpConnectionStatus? = entries.firstOrNull { it.wireValue == value }
    }
}

/** The negotiated protocol generation. */
enum class McpProtocolGeneration(val wireValue: String) {
    Stateless("stateless"),
    Session("session"),
    ;

    companion object {
        fun fromWireValue(value: String): McpProtocolGeneration? = entries.firstOrNull { it.wireValue == value }
    }
}

/** Tool permission. */
enum class McpToolPermission(val wireValue: String) {
    Auto("auto"),
    Ask("ask"),
    Off("off"),
    ;

    companion object {
        fun fromWireValue(value: String): McpToolPermission? = entries.firstOrNull { it.wireValue == value }

        /** Tools that declare themselves read-only default to "run automatically"; all others (including those with no declaration) to "ask every time". */
        fun defaultFor(readOnly: Boolean): McpToolPermission = if (readOnly) Auto else Ask
    }
}

/** Connection state record. A legacy-protocol session id is kept only in memory and here; it is never logged. */
data class McpConnectionState(
    val serverId: String,
    val status: McpConnectionStatus = McpConnectionStatus.Unknown,
    val lastSuccessAt: Long? = null,
    val negotiatedVersion: String? = null,
    val generation: McpProtocolGeneration? = null,
    val sessionId: String? = null,
)

/**
 * Tool snapshot: `serverId` + original tool name -> title, description, parameter definition, read-only declaration,
 * content hash, quarantine flag and oversized flag.
 *
 * [inputSchema] is persisted with the original property order (the parameter summary takes the first 3 in that order),
 * not as key-sorted canonical JSON; canonical JSON is only used for hashing.
 */
data class McpToolSnapshot(
    val serverId: String,
    val toolName: String,
    val title: String,
    val description: String?,
    val inputSchema: JsonElement,
    val annotations: JsonElement,
    val contentHash: String,
    val readOnly: Boolean,
    val pendingReview: Boolean = false,
    val oversized: Boolean = false,
    val updatedAt: Long,
)

/** The kind of a tool change. */
enum class McpToolChangeKind { Added, Changed, Removed }

/** A single tool change. */
data class McpToolChange(val kind: McpToolChangeKind, val toolName: String, val title: String)

/** The payload of a single step. */
data class McpStepPayload(val arguments: String?, val resultPrefix: String?)

/**
 * Runtime limits (the `mcpRuntimeConfig` block of the model catalog).
 *
 * When the catalog carries no such block (or no catalog is configured), [fallback] is used and the feature is not
 * disabled. Out-of-range values are clamped to the bounds ([fromJson]) instead of falling back as a whole.
 */
data class McpRuntimeConfig(
    val version: Int = 1,
    val enabled: Boolean = true,
    val maxServers: Int = 20,
    val maxToolsPerRequest: Int = 40,
    val maxToolDefinitionBytes: Int = 16_384,
    val maxResultChars: Int = 24_000,
    /** Seconds, may be fractional (tests use sub-second timeouts). */
    val callTimeoutSeconds: Double = 60.0,
    val maxSteps: Int = 6,
) {
    /** Step limit: the smaller of the two, in line with the existing tool loop (default 6, at most 8). */
    val effectiveMaxSteps: Int get() = minOf(maxSteps, 8)

    companion object {
        /** Built-in defaults: used when the catalog does not carry the block or it fails to parse. */
        val fallback: McpRuntimeConfig = McpRuntimeConfig()

        // Allowed ranges of the numeric fields. One mistyped number in the configuration (0, a negative value, a few extra
        // zeros) must not disable the feature as a whole (a limit of 0 = no server can be added, a timeout of 0 = every call
        // times out immediately) or void a protective limit. The upper bounds are the client's hard ceiling.
        val MAX_SERVERS_BOUNDS = 1..100
        val MAX_TOOLS_PER_REQUEST_BOUNDS = 1..128
        val MAX_TOOL_DEFINITION_BYTES_BOUNDS = 1_024..262_144
        val MAX_RESULT_CHARS_BOUNDS = 1_000..200_000
        val CALL_TIMEOUT_SECONDS_BOUNDS = 5.0..600.0
        val MAX_STEPS_BOUNDS = 1..8

        /**
         * Parses the top-level `mcpRuntimeConfig` of the catalog. Missing or mistyped fields use the fallback values; a
         * missing section returns the fallback; out-of-range numbers are clamped to the bounds. The version number is not
         * a quantity and is not clamped: only integers >= 1 are accepted.
         */
        fun fromJson(element: JsonElement?): McpRuntimeConfig {
            val root = element as? JsonObject ?: return fallback
            var config = fallback
            root["version"].longOrNull?.takeIf { it in 1..Int.MAX_VALUE.toLong() }?.let { config = config.copy(version = it.toInt()) }
            root["enabled"].booleanOrNull?.let { config = config.copy(enabled = it) }
            clamped(root["maxServers"], MAX_SERVERS_BOUNDS)?.let { config = config.copy(maxServers = it) }
            clamped(root["maxToolsPerRequest"], MAX_TOOLS_PER_REQUEST_BOUNDS)?.let {
                config = config.copy(maxToolsPerRequest = it)
            }
            clamped(root["maxToolDefinitionBytes"], MAX_TOOL_DEFINITION_BYTES_BOUNDS)?.let {
                config = config.copy(maxToolDefinitionBytes = it)
            }
            clamped(root["maxResultChars"], MAX_RESULT_CHARS_BOUNDS)?.let { config = config.copy(maxResultChars = it) }
            root["callTimeoutSeconds"].doubleOrNull?.let {
                config = config.copy(callTimeoutSeconds = it.coerceIn(CALL_TIMEOUT_SECONDS_BOUNDS))
            }
            clamped(root["maxSteps"], MAX_STEPS_BOUNDS)?.let { config = config.copy(maxSteps = it) }
            return config
        }

        /** Clamps on the Double first and then truncates (downwards): converting values such as `1e30` straight to Int would overflow. Returns null for non-finite numbers. */
        private fun clamped(value: JsonElement?, range: IntRange): Int? {
            val number = value.doubleOrNull ?: return null
            return Math.floor(number.coerceIn(range.first.toDouble(), range.last.toDouble())).toInt()
        }
    }
}

/**
 * The closed set of error codes. This is what is fed back to the model, written to `toolSteps.errorCode` and used for
 * display; **it never carries the server's own text**.
 */
enum class McpErrorCode(val wireValue: String) {
    UserDenied("user_denied"),
    NeedsAuth("needs_auth"),
    AuthSkipped("auth_skipped"),
    Timeout("timeout"),
    Unreachable("unreachable"),
    ServerError("server_error"),
    ToolError("tool_error"),
    ResultTooLarge("result_too_large"),
    NeedsInputUnsupported("needs_input_unsupported"),
    ToolUnavailable("tool_unavailable"),
    Cancelled("cancelled"),
    Interrupted("interrupted"),
    ;

    companion object {
        fun fromWireValue(value: String): McpErrorCode? = entries.firstOrNull { it.wireValue == value }
    }
}

/**
 * A tool returned by the server (an item of `tools[]` in `tools/list`). Everything in `annotations` is a self-reported
 * third-party hint and is treated as untrusted.
 */
data class McpToolDefinition(
    val name: String,
    val title: String? = null,
    val description: String? = null,
    val inputSchema: JsonElement = JsonObject(emptyMap()),
    val annotations: JsonElement = JsonObject(emptyMap()),
) {
    /** Display name precedence: `title` -> `annotations.title` -> `name`. */
    val displayTitle: String
        get() {
            if (!title.isNullOrEmpty()) return title
            val annotationTitle = annotations["title"].stringOrNull
            if (!annotationTitle.isNullOrEmpty()) return annotationTitle
            return name
        }

    /** Read-only declaration. Missing = not declared = treated as modifying data. */
    val readOnlyHint: Boolean? get() = annotations["readOnlyHint"].booleanOrNull

    val readOnly: Boolean get() = readOnlyHint == true

    companion object {
        /** Builds from a single tool object of `tools/list`; an item without `name` is invalid and skipped. */
        fun fromJson(json: JsonElement): McpToolDefinition? {
            val name = json["name"].stringOrNull?.takeIf { it.isNotEmpty() } ?: return null
            return McpToolDefinition(
                name = name,
                title = json["title"].stringOrNull,
                description = json["description"].stringOrNull,
                inputSchema = json["inputSchema"]?.takeUnless { it is JsonNull } ?: JsonObject(emptyMap()),
                annotations = json["annotations"]?.takeUnless { it is JsonNull } ?: JsonObject(emptyMap()),
            )
        }
    }
}

/** Protocol constants. */
object McpProtocol {
    /** The newest version supported by this client. */
    const val MODERN_VERSION = "2026-07-28"

    /** In the legacy handshake the client SHOULD send the newest version it supports; the server may answer with another version it supports. */
    const val LEGACY_INITIALIZE_VERSION = "2025-11-25"

    /** The legacy versions supported by this client. */
    val LEGACY_VERSIONS = setOf("2025-11-25", "2025-06-18", "2025-03-26")

    /** `UnsupportedProtocolVersion`: carries `data.supported`, from which a version is picked for the retry. */
    const val UNSUPPORTED_VERSION_ERROR_CODE = -32022L
    const val INVALID_PARAMS_ERROR_CODE = -32602L
    const val METHOD_NOT_FOUND_ERROR_CODE = -32601L

    /** Recognizable modern JSON-RPC error codes: seeing one means the server is modern and must not be retried with initialize. */
    val MODERN_ERROR_CODES = setOf(-32020L, -32021L, UNSUPPORTED_VERSION_ERROR_CODE)

    /**
     * Identifiers exclusive to the modern protocol: any of them in an error's `message` / `data` means modern.
     * The generic `-32602` a legacy server returns before `initialize` contains none of these strings, so the fallback
     * still happens correctly.
     */
    val MODERN_ERROR_MARKERS = listOf("io.modelcontextprotocol/", "_meta", "resultType")

    /**
     * **Request header names** exclusive to the modern protocol (lowercase; header names are case-insensitive).
     *
     * They are deliberately listed one by one rather than matched by an `Mcp-` prefix, and **`MCP-Protocol-Version` is not
     * included**: the `Mcp-Session-Id` and `MCP-Protocol-Version` headers are used by legacy versions too. If their
     * appearance in a legacy server's error text counted as a modern identifier, such servers would be misclassified as
     * modern, never fall back to `initialize`, and therefore never connect.
     */
    val MODERN_HEADER_MARKERS = listOf("mcp-method", "mcp-name", "mcp-param-")

    fun containsModernMarker(text: String): Boolean {
        if (MODERN_ERROR_MARKERS.any { text.contains(it) }) return true
        val lowered = text.lowercase()
        return MODERN_HEADER_MARKERS.any { lowered.contains(it) }
    }

    /** Page limit for `tools/list` (a limit set by this client, not by the specification). */
    const val MAX_TOOLS_LIST_PAGES = 20

    const val META_PROTOCOL_VERSION_KEY = "io.modelcontextprotocol/protocolVersion"
    const val META_CLIENT_INFO_KEY = "io.modelcontextprotocol/clientInfo"
    const val META_CLIENT_CAPABILITIES_KEY = "io.modelcontextprotocol/clientCapabilities"
    const val CLIENT_INFO_NAME = "Oriveo"
    const val CLIENT_INFO_VERSION = "1.0.0"
}
