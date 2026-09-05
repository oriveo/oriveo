package ai.oriveo.community.core.security

import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SecureKeyStoreAccountIsolationTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Before
    fun setUp() {
        context.deleteSharedPreferences(PREFS_NAME)
    }

    @After
    fun tearDown() {
        context.deleteSharedPreferences(PREFS_NAME)
    }

    @Test
    fun sameDeterministicProviderIdKeepsKeysIsolatedByAccount() {
        val store = SecureKeyStore(context)

        store.saveApiKey("user-a", "PROVIDER-1", "sk-a")
        store.saveApiKey("user-b", "PROVIDER-1", "sk-b")

        assertEquals("sk-a", store.getApiKey("user-a", "PROVIDER-1"))
        assertEquals("sk-b", store.getApiKey("user-b", "PROVIDER-1"))

        store.deleteApiKey("user-a", "PROVIDER-1")

        assertNull(store.getApiKey("user-a", "PROVIDER-1"))
        assertEquals("sk-b", store.getApiKey("user-b", "PROVIDER-1"))
    }

    @Test
    fun legacyProviderOnlyKeyMigratesToDatabaseAssignedAccount() {
        encryptedPrefs().edit().putString("api_key_PROVIDER-1", "sk-legacy").commit()
        val store = SecureKeyStore(context)

        store.migrateLegacyApiKey("user-a", "PROVIDER-1")

        assertEquals("sk-legacy", store.getApiKey("user-a", "PROVIDER-1"))
        assertNull(store.getApiKey("user-b", "PROVIDER-1"))
        assertNull(encryptedPrefs().getString("api_key_PROVIDER-1", null))
    }

    @Test
    fun deletingAnotherAccountDoesNotRemoveUnclaimedLegacyKey() {
        encryptedPrefs().edit().putString("api_key_PROVIDER-1", "sk-legacy-a").commit()
        val store = SecureKeyStore(context)

        store.saveApiKey("user-b", "PROVIDER-1", "sk-b")
        store.deleteApiKey("user-b", "PROVIDER-1")
        store.migrateLegacyApiKey("user-a", "PROVIDER-1")

        assertEquals("sk-legacy-a", store.getApiKey("user-a", "PROVIDER-1"))
        assertNull(store.getApiKey("user-b", "PROVIDER-1"))
    }

    private fun encryptedPrefs() = EncryptedSharedPreferences.create(
        context,
        PREFS_NAME,
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    private companion object {
        const val PREFS_NAME = "oriveo_secure_keys"
    }
}
