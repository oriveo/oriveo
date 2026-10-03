package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Failure semantics of the credential store and DCR registration.
 * The medium is in-memory prefs with injectable failures; key construction, isolation and cleanup still run production code.
 */
class McpCredentialStoreRegistrationTest {

    private val prefs = InMemoryPrefs()
    private val store = McpCredentialStore(prefs)

    private fun registration(issuer: String = ISSUER, clientId: String = "dcr_client_secret") =
        McpStoredClientRegistration(clientId, issuer, McpClientMetadata.REDIRECT_URIS)

    @Test
    fun `write failure throws and nothing is treated as saved`() {
        prefs.failWrites = true
        try {
            store.save(McpCredentials(accessToken = "a"), SERVER, UID)
            fail("a failed write must throw")
        } catch (expected: McpCredentialStoreException) {
            assertFalse("the exception message carries no credential", expected.toString().contains("a\""))
        }
        assertNull(store.load(SERVER, UID))
        try {
            store.saveClientRegistration(registration(), UID)
            fail()
        } catch (expected: McpCredentialStoreException) {
        }
    }

    @Test
    fun `delete failure throws and leaves the credential in place while deleting a missing one succeeds`() {
        store.save(McpCredentials(accessToken = "a"), SERVER, UID)
        prefs.failDeletes = true
        try {
            store.delete(SERVER, UID)
            fail("a failed delete must throw")
        } catch (expected: McpCredentialStoreException) {
        }
        assertEquals("a", store.load(SERVER, UID)?.accessToken)
        prefs.failDeletes = false
        store.delete(SERVER, UID)
        store.delete(SERVER, UID)
        assertNull(store.load(SERVER, UID))
    }

    @Test
    fun `dcr registration is keyed by partition and issuer bound to issuer and survives server removal`() {
        store.saveClientRegistration(registration(), UID)
        assertEquals("dcr_client_secret", store.loadClientRegistration(ISSUER, UID)?.clientId)
        assertNull("a different issuer does not match", store.loadClientRegistration("https://other.example.com", UID))
        assertNull("a different partition does not match", store.loadClientRegistration(ISSUER, "other"))
        assertEquals(setOf(McpCredentialStore.registrationKey(ISSUER, UID)), prefs.all.keys)

        store.save(McpCredentials(accessToken = "a"), SERVER, UID)
        store.delete(SERVER, UID)
        assertNotNull("registration is shared per authorization server and survives server removal", store.loadClientRegistration(ISSUER, UID))

        store.deleteClientRegistration(ISSUER, UID)
        assertNull(store.loadClientRegistration(ISSUER, UID))
    }

    @Test
    fun `a stored registration never prints its client id`() {
        val stored = registration()
        assertFalse(stored.toString().contains("dcr_client_secret"))
        assertTrue(stored.toString().contains(ISSUER))
    }

    private companion object {
        const val UID = LOCAL_PARTITION_ID
        const val ISSUER = "https://auth.example.com"
        const val SERVER = "6f1d2c3b-4a59-4e68-9d7c-0b1a2c3d4e5f"
    }
}
