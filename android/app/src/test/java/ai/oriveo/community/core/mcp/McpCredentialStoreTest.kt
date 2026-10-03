package ai.oriveo.community.core.mcp

import android.content.Context
import ai.oriveo.community.core.security.SecureKeyStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * MCP credentials: keys are isolated per `uid`, cleaned up when a server is removed, and **never reach logs**.
 *
 * The medium is in-memory prefs (production uses the encrypted file of `SecureKeyStore`), but key construction, isolation and cleanup all run
 * the production code path of `McpCredentialStore`.
 */
@RunWith(RobolectricTestRunner::class)
class McpCredentialStoreTest {

    private lateinit var store: McpCredentialStore

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication()
        store = McpCredentialStore(
            context.getSharedPreferences("mcp-credential-unit", Context.MODE_PRIVATE),
        )
    }

    @Test
    fun `save and load round trip every field`() {
        val credentials = McpCredentials(
            accessToken = "access-1",
            refreshToken = "refresh-1",
            expiresAtMillis = 1_700_000_000_000L,
            issuer = "https://auth.example.com",
            clientId = "client-1",
            resource = "https://mcp.example.com",
            pastedToken = "pasted-1",
        )

        store.save(credentials, serverId = "s1", uid = "uid-1")

        assertEquals(credentials, store.load(serverId = "s1", uid = "uid-1"))
    }

    @Test
    fun `credentials are isolated per uid`() {
        store.save(McpCredentials(accessToken = "uid-1-token"), serverId = "s1", uid = "uid-1")
        store.save(McpCredentials(accessToken = "uid-2-token"), serverId = "s1", uid = "uid-2")

        assertEquals("uid-1-token", store.load(serverId = "s1", uid = "uid-1")?.accessToken)
        assertEquals("uid-2-token", store.load(serverId = "s1", uid = "uid-2")?.accessToken)

        assertNull(store.load(serverId = "s1", uid = "uid-3"))
        assertTrue(
            "one separate entry per uid",
            store.keys().containsAll(
                listOf(
                    SecureKeyStore.mcpCredentialKey("uid-1", "s1"),
                    SecureKeyStore.mcpCredentialKey("uid-2", "s1"),
                ),
            ),
        )
    }

    @Test
    fun `removing a server deletes only that server credential`() {
        store.save(McpCredentials(accessToken = "a1"), serverId = "s1", uid = "uid-1")
        store.save(McpCredentials(accessToken = "a2"), serverId = "s2", uid = "uid-1")
        store.save(McpCredentials(accessToken = "a3"), serverId = "s1", uid = "uid-2")

        store.delete(serverId = "s1", uid = "uid-1")

        assertNull(store.load(serverId = "s1", uid = "uid-1"))
        assertEquals("a2", store.load(serverId = "s2", uid = "uid-1")?.accessToken)
        assertEquals("a same-named server under another uid is unaffected", "a3", store.load(serverId = "s1", uid = "uid-2")?.accessToken)
    }

    /** The key prefix length-delimits `uid`: the keys of `a` must not be confused with entries owned by `a:b`. */
    @Test
    fun `a uid that merely starts with another uid has its own entries`() {
        store.save(McpCredentials(accessToken = "short"), serverId = "s1", uid = "a")
        store.save(McpCredentials(accessToken = "long"), serverId = "s1", uid = "a:b")
        store.save(McpCredentials(accessToken = "longer"), serverId = "s1", uid = "ab")

        store.delete(serverId = "s1", uid = "a")

        assertNull(store.load(serverId = "s1", uid = "a"))
        assertEquals("long", store.load(serverId = "s1", uid = "a:b")?.accessToken)
        assertEquals("longer", store.load(serverId = "s1", uid = "ab")?.accessToken)
        assertFalse(SecureKeyStore.mcpCredentialKey("a:b", "s1").startsWith(SecureKeyStore.mcpCredentialKeyPrefix("a")))
        assertFalse(SecureKeyStore.mcpCredentialKey("ab", "s1").startsWith(SecureKeyStore.mcpCredentialKeyPrefix("a")))
    }

    /** Every key of a `uid` starts with that `uid`'s prefix and with no other one's. */
    @Test
    fun `the key prefix is derived from the same source as the key`() {
        val key = SecureKeyStore.mcpCredentialKey("uid-1", "s1")
        assertTrue(key.startsWith(SecureKeyStore.mcpCredentialKeyPrefix("uid-1")))
        assertFalse(key.startsWith(SecureKeyStore.mcpCredentialKeyPrefix("uid-2")))
    }

    /** Server ids are NOCASE in the database; removing with a different letter case must still delete the credentials. */
    @Test
    fun `server id case variants address the same credential`() {
        store.save(McpCredentials(accessToken = "a1"), serverId = "ABCDEF-01", uid = "uid-1")

        assertEquals("a1", store.load(serverId = "abcdef-01", uid = "uid-1")?.accessToken)
        store.delete(serverId = "abcdef-01", uid = "uid-1")

        assertNull(store.load(serverId = "ABCDEF-01", uid = "uid-1"))
        assertTrue("no entry is left after deletion", store.keys().isEmpty())
    }

    @Test
    fun `uid stays case sensitive`() {
        store.save(McpCredentials(accessToken = "upper"), serverId = "s1", uid = "UID")

        assertNull(store.load(serverId = "s1", uid = "uid"))
    }

    /** `$credentials` is the most common way into logs, so it must only report which fields exist. */
    @Test
    fun `printing credentials never leaks a secret`() {
        val credentials = McpCredentials(
            accessToken = "sk-access-top-secret",
            refreshToken = "sk-refresh-top-secret",
            pastedToken = "sk-pasted-top-secret",
            clientId = "sk-client-top-secret",
            issuer = "https://auth.example.com",
            // The address itself may carry a secret (query parameter / long random path segment).
            resource = "https://mcp.example.com/k/sk-url-embedded-secret?token=sk-query-secret",
            expiresAtMillis = 1_700_000_000_000L,
        )

        val printed = "$credentials"
        val interpolated = "credentials=${credentials}"
        val concatenated = "credentials=" + credentials

        listOf(printed, interpolated, concatenated).forEach { text ->
            assertFalse("the token must not appear in the stringified result: $text", text.contains("sk-access-top-secret"))
            assertFalse(text.contains("sk-refresh-top-secret"))
            assertFalse(text.contains("sk-pasted-top-secret"))
            assertFalse("client_id counts as a credential", text.contains("sk-client-top-secret"))
            assertFalse("resource is the server address; a secret inside the address must not leak", text.contains("sk-url-embedded-secret"))
            assertFalse(text.contains("sk-query-secret"))
            assertFalse("the resource field is not printed at all", text.contains("resource"))
            assertTrue("the fields present must be visible, otherwise there is nothing to debug with", text.contains("accessToken=<redacted>"))
            assertTrue(text.contains("refreshToken=<redacted>"))
            assertTrue(text.contains("pastedToken=<redacted>"))
            assertTrue(text.contains("clientId=<redacted>"))
        }
        // issuer is not a secret (it is the authorization server address, and the UI shows its host name anyway).
        assertTrue(printed.contains("issuer=https://auth.example.com"))
    }

    /** Credentials stay on this device. The prefs file must be excluded from legacy full backup, cloud backup and device transfer. */
    @Test
    fun `credential prefs file is excluded from every backup path`() {
        var dir = java.io.File(System.getProperty("user.dir") ?: ".")
        while (!java.io.File(dir, "app/src/main/res/xml").isDirectory) {
            dir = dir.parentFile ?: error("Android project root not found")
        }
        val xml = java.io.File(dir, "app/src/main/res/xml")
        // The file name is the prefs name production code actually uses, so a rename fails here instead of silently disabling the exclusion rule
        val marker = "domain=\"sharedpref\" path=\"${SecureKeyStore.MCP_PREFS_FILE_NAME}.xml\""

        val legacy = java.io.File(xml, "backup_rules.xml").readText()
        val extraction = java.io.File(xml, "data_extraction_rules.xml").readText()
        assertEquals("excluded from legacy full backup", 1, Regex(Regex.escape(marker)).findAll(legacy).count())
        assertEquals("excluded once each for cloud backup and device transfer", 2, Regex(Regex.escape(marker)).findAll(extraction).count())
    }

    /** The production medium is encrypted prefs, whose first open goes through the Keystore: construction must not open it, and afterwards it is fetched only once. */
    @Test
    fun `medium is opened lazily and only once`() {
        var opened = 0
        val backing = RuntimeEnvironment.getApplication()
            .getSharedPreferences("mcp-credential-lazy", Context.MODE_PRIVATE)
        val lazyStore = McpCredentialStore(prefsProvider = { opened += 1; backing })

        assertEquals("building the dependency graph must not open the encrypted prefs (that goes through the Keystore)", 0, opened)
        lazyStore.save(McpCredentials(accessToken = "a1"), serverId = "s1", uid = "uid-1")
        lazyStore.load(serverId = "s1", uid = "uid-1")
        assertEquals("the medium is fetched once and reused afterwards", 1, opened)
    }
}
