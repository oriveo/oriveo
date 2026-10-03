package ai.oriveo.community.core.mcp

import android.content.SharedPreferences
import ai.oriveo.community.core.security.SecureKeyStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * All MCP credentials of one server.
 *
 * **No field ever goes into logs.** [toString] therefore only reports which fields are present: `$credentials`
 * interpolation and string concatenation are the most common way values end up in logs, and without redaction that
 * would hand the tokens over.
 */
@Serializable
data class McpCredentials(
    val accessToken: String? = null,
    val refreshToken: String? = null,
    val expiresAtMillis: Long? = null,
    val issuer: String? = null,
    /** The CIMD document URL, or the `client_id` obtained through DCR. Treated as a credential and redacted. */
    val clientId: String? = null,
    /** The canonical URI of the MCP server this credential may be sent to (RFC 8707). `resource` is mandatory on refresh. */
    val resource: String? = null,
    /** An access token pasted by the user (the "access token" sign-in method). */
    val pastedToken: String? = null,
) {
    override fun toString(): String = redacted()

    private fun redacted(): String {
        val fields = mutableListOf<String>()
        if (accessToken != null) fields += "accessToken=<redacted>"
        if (refreshToken != null) fields += "refreshToken=<redacted>"
        if (pastedToken != null) fields += "pastedToken=<redacted>"
        if (clientId != null) fields += "clientId=<redacted>"
        if (expiresAtMillis != null) fields += "expiresAtMillis=$expiresAtMillis"
        if (issuer != null) fields += "issuer=$issuer"
        // `resource` is deliberately not printed: it is the server address, and an
        // address may carry a secret (query parameter / userinfo / long random path segment).
        return "McpCredentials(${fields.joinToString(", ")})"
    }
}

/**
 * A DCR registration cached on this device. Bound to the authorization server's `issuer` and never reused across
 * authorization servers; several MCP servers behind the same authorization server share one registration instead of
 * registering again.
 */
@Serializable
data class McpStoredClientRegistration(
    val clientId: String,
    val issuer: String,
    /** The redirect URIs reported to the authorization server at registration. Once a release changes the redirect URI, the old registration can no longer be used. */
    val redirectUris: List<String>,
) {
    override fun toString(): String = "McpStoredClientRegistration(issuer=$issuer, clientId=<redacted>)"
}

/** Writing or deleting a credential failed. Carries only the operation name, never any credential content. */
class McpCredentialStoreException(operation: String) : Exception("mcp credential $operation failed")

/**
 * Credential storage for remote MCP.
 *
 * Access token, refresh token, expiry, issuer, the `client_id` obtained through DCR and a user-pasted access token all
 * go through here. **None of them goes into logs**, nor into Room; the prefs file that holds them is excluded from
 * system backup and device-to-device transfer (credentials stay on this device).
 *
 * The medium is injected through the constructor: production uses a dedicated encrypted prefs file from
 * `SecureKeyStore`, tests pass in-memory prefs. Key construction (`uid:serverId`) and cleanup on server removal live
 * in this class, so tests still exercise the production path with only the medium swapped. `uid` is the storage
 * partition, as in the other [SecureKeyStore] keys.
 */
class McpCredentialStore(
    /** The medium is obtained lazily: opening encrypted prefs for the first time goes through the Keystore, which must not happen while the dependency graph is being assembled. */
    private val prefsProvider: () -> SharedPreferences,
    private val json: Json = Json { ignoreUnknownKeys = true },
) {
    constructor(prefs: SharedPreferences) : this(prefsProvider = { prefs })

    /**
     * Production entry point: reuses the single in-process [SecureKeyStore] (a Koin singleton). Creating another one
     * would add a second encrypted prefs instance, each with its own in-memory cache, so a write on one side would be
     * invisible to the other.
     */
    constructor(secureKeyStore: SecureKeyStore) : this(prefsProvider = secureKeyStore::mcpCredentialPrefs)

    private val prefs: SharedPreferences by lazy(prefsProvider)

    /**
     * A failed write throws [McpCredentialStoreException]. If it were swallowed, the caller would treat a token that
     * was never stored as persisted; a persistence failure has to count as a failure. That is why this uses the
     * synchronous `commit()` rather than `apply()`.
     */
    fun save(credentials: McpCredentials, serverId: String, uid: String) {
        write(SecureKeyStore.mcpCredentialKey(uid, serverId), json.encodeToString(credentials))
    }

    fun load(serverId: String, uid: String): McpCredentials? {
        val raw = read(SecureKeyStore.mcpCredentialKey(uid, serverId)) ?: return null
        return runCatching { json.decodeFromString<McpCredentials>(raw) }.getOrNull()
    }

    /**
     * Deletes all credentials of a server when it is removed. Throws when deletion fails, so the caller can tell the
     * user instead of silently leaving behind a credential nobody will ever clean up. An entry that was already absent
     * counts as success.
     */
    fun delete(serverId: String, uid: String) {
        // The full address (`localOnly`) is deleted as well: it is a credential of this server too.
        commit("delete") {
            remove(SecureKeyStore.mcpCredentialKey(uid, serverId))
            remove(SecureKeyStore.mcpEndpointKey(uid, serverId))
        }
    }

    // -- Full address (localOnly) --------------------------------

    /**
     * The full address of a server whose address looks like it carries a secret. Room only holds the display address
     * (the main database is covered by system backup); the full address lives only in these encrypted prefs, which are
     * excluded from backup. A failed write throws: the caller uses that to decide whether the server is still usable
     * (no request can be sent without the full address).
     */
    fun saveEndpoint(url: String, serverId: String, uid: String) {
        write(SecureKeyStore.mcpEndpointKey(uid, serverId), url)
    }

    fun loadEndpoint(serverId: String, uid: String): String? = read(SecureKeyStore.mcpEndpointKey(uid, serverId))

    /** Deletes only the full address (when the record is no longer `localOnly`). */
    fun deleteEndpoint(serverId: String, uid: String) {
        commit("delete") { remove(SecureKeyStore.mcpEndpointKey(uid, serverId)) }
    }

    // -- DCR registration ----------------------------------------

    fun saveClientRegistration(registration: McpStoredClientRegistration, uid: String) {
        write(registrationKey(registration.issuer, uid), json.encodeToString(registration))
    }

    /** Bound to the issuer: a stored registration for a different issuer is not accepted. */
    fun loadClientRegistration(issuer: String, uid: String): McpStoredClientRegistration? {
        val raw = read(registrationKey(issuer, uid)) ?: return null
        val registration = runCatching { json.decodeFromString<McpStoredClientRegistration>(raw) }.getOrNull()
        return registration?.takeIf { it.issuer == issuer }
    }

    /**
     * Clears a registration that the authorization server rejected as invalid. Does not throw when deletion fails: a
     * registration is not a token, and keeping it only means the next sign-in is rejected once more and it is cleared
     * again. Real tokens go through [delete], which does throw.
     */
    fun deleteClientRegistration(issuer: String, uid: String) {
        runCatching { commit("delete") { remove(registrationKey(issuer, uid)) } }
    }

    private fun read(key: String): String? = runCatching { prefs.getString(key, null) }.getOrNull()

    private fun write(key: String, value: String) = commit("write") { putString(key, value) }

    private fun commit(operation: String, change: SharedPreferences.Editor.() -> Unit) {
        val committed = try {
            val editor = prefs.edit()
            editor.change()
            editor.commit()
        } catch (error: Exception) {
            // Keystore failures of the encrypted prefs surface here as exceptions; the cause is not propagated (it may carry context beyond key names).
            throw McpCredentialStoreException(operation)
        }
        if (!committed) throw McpCredentialStoreException(operation)
    }

    /** All credential keys in the current medium (for tests and diagnostics; **values are never read out**). */
    fun keys(): Set<String> = prefs.all.keys

    companion object {
        /**
         * The key of a DCR registration: the `uid` prefix + `dcr:` + issuer. The `dcr:` in the middle is not a valid
         * UUID, so it cannot collide with a `uid:serverId` key.
         */
        fun registrationKey(issuer: String, uid: String): String = SecureKeyStore.mcpCredentialKeyPrefix(uid) + "dcr:" + issuer
    }
}
