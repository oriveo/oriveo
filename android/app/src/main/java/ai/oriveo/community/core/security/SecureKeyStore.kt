package ai.oriveo.community.core.security

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.AEADBadTagException

class SecureKeyStore private constructor(
    context: Context,
    initialPrefs: SharedPreferences?,
) {
    constructor(context: Context) : this(context, null)

    /** Unit-test seam; production always uses encrypted preferences via the public constructor. */
    internal constructor(context: Context, prefs: SharedPreferences, @Suppress("UNUSED_PARAMETER") testOnly: Unit) :
        this(context, prefs)

    private val appContext = context.applicationContext

    @Volatile
    private var prefsRef: SharedPreferences? = initialPrefs

    @Volatile
    private var archivePrefsRef: SharedPreferences? = null

    @Volatile
    private var subscriptionPrefsRef: SharedPreferences? = null

    private val apiKeyCache = ConcurrentHashMap<String, String>()

    fun prewarm() {
        prefs()
    }

    @Synchronized
    fun saveApiKey(accountId: String, providerID: String, key: String) {

        if (key.isBlank()) {
            deleteApiKey(accountId, providerID)
            return
        }
        val storageKey = keyFor(accountId, providerID)
        // Persisting the same credential is not a credential mutation. Do not invalidate
        // connection-local runtime evidence merely because an unchanged provider is re-saved.
        if (getApiKey(accountId, providerID) == key) return
        prefs().edit().putString(storageKey, key).apply()
        apiKeyCache[storageKey] = key
        advanceCredentialEpoch(accountId, providerID)
        CapabilityEvidenceObservationBridge.invalidate()
    }

    @Synchronized
    fun getApiKey(accountId: String, providerID: String): String? {
        val storageKey = keyFor(accountId, providerID)
        apiKeyCache[storageKey]?.let { return it.ifEmpty { null } }
        val stored = prefs().getString(storageKey, null)
        apiKeyCache[storageKey] = stored.orEmpty()
        return stored
    }

    @Synchronized
    internal fun migrateLegacyApiKey(accountId: String, providerID: String) {
        val storageKey = keyFor(accountId, providerID)
        val legacyKey = legacyKeyFor(providerID)
        val prefs = prefs()
        val legacyValue = prefs.getString(legacyKey, null) ?: return
        val editor = prefs.edit()
        if (!prefs.contains(storageKey)) {
            editor.putString(storageKey, legacyValue)
            apiKeyCache[storageKey] = legacyValue
        }
        editor.remove(legacyKey).commit()
        apiKeyCache.remove(legacyKey)
    }

    @Synchronized
    fun deleteApiKey(accountId: String, providerID: String) {
        val storageKey = keyFor(accountId, providerID)
        if (getApiKey(accountId, providerID) == null) {

            prefs().edit().remove(storageKey).apply()
            apiKeyCache[storageKey] = ""
            return
        }
        prefs().edit().remove(storageKey).apply()
        apiKeyCache[storageKey] = ""
        advanceCredentialEpoch(accountId, providerID)
        CapabilityEvidenceObservationBridge.invalidate()
    }

    data class CapabilityEpochs(
        val connectionGeneration: String,
        val credentialEpoch: String,
    )

    @Synchronized
    fun capabilityEpochs(accountId: String, providerID: String): CapabilityEpochs {
        val prefs = prefs()
        val connectionKey = capabilityConnectionGenerationKey(accountId, providerID)
        val credentialKey = capabilityCredentialEpochKey(accountId, providerID)
        val connection = prefs.getString(connectionKey, null) ?: newCapabilityToken()
        val credential = prefs.getString(credentialKey, null) ?: newCapabilityToken()
        if (!prefs.contains(connectionKey) || !prefs.contains(credentialKey)) {
            prefs.edit()
                .putString(connectionKey, connection)
                .putString(credentialKey, credential)
                .apply()
        }
        return CapabilityEpochs(connection, credential)
    }

    @Synchronized
    fun beginCapabilityConnection(accountId: String, providerID: String): CapabilityEpochs {
        val next = CapabilityEpochs(newCapabilityToken(), newCapabilityToken())
        prefs().edit()
            .putString(capabilityConnectionGenerationKey(accountId, providerID), next.connectionGeneration)
            .putString(capabilityCredentialEpochKey(accountId, providerID), next.credentialEpoch)
            .apply()
        CapabilityEvidenceObservationBridge.invalidate()
        return next
    }

    @Synchronized
    fun advanceCapabilityConnection(accountId: String, providerID: String): CapabilityEpochs =
        beginCapabilityConnection(accountId, providerID)

    @Synchronized
    fun advanceCapabilityConnectionGeneration(accountId: String, providerID: String): CapabilityEpochs {
        val current = capabilityEpochs(accountId, providerID)
        val next = current.copy(connectionGeneration = newCapabilityToken())
        prefs().edit()
            .putString(capabilityConnectionGenerationKey(accountId, providerID), next.connectionGeneration)
            .apply()
        CapabilityEvidenceObservationBridge.invalidate()
        return next
    }

    @Synchronized
    private fun advanceCredentialEpoch(accountId: String, providerID: String) {
        prefs().edit()
            .putString(capabilityCredentialEpochKey(accountId, providerID), newCapabilityToken())
            .apply()
    }

    private fun capabilityConnectionGenerationKey(accountId: String, providerID: String): String =
        "capability.connection.$accountId.$providerID"

    private fun capabilityCredentialEpochKey(accountId: String, providerID: String): String =
        "capability.credential.$accountId.$providerID"

    private fun newCapabilityToken(): String = java.util.UUID.randomUUID().toString()

    fun saveSubscriptionCredential(accountId: String, providerID: String, payload: String) {
        subscriptionPrefs().edit()
            .putString(subscriptionKeyFor(accountId, providerID), payload)
            .apply()
    }

    fun loadSubscriptionCredential(accountId: String, providerID: String): String? =
        subscriptionPrefs().getString(subscriptionKeyFor(accountId, providerID), null)

    fun deleteSubscriptionCredential(accountId: String, providerID: String) {
        subscriptionPrefs().edit()
            .remove(subscriptionKeyFor(accountId, providerID))
            .apply()
    }

    private fun subscriptionPrefs(): SharedPreferences =
        subscriptionPrefsRef ?: synchronized(this) {
            subscriptionPrefsRef ?: createSubscriptionPrefsWithRecovery().also { subscriptionPrefsRef = it }
        }

    private fun createSubscriptionPrefsWithRecovery(): SharedPreferences =
        runCatching {
            createEncryptedPrefs(SUBSCRIPTION_PREFS_FILE_NAME)
        }.recoverCatching { error ->
            if (!error.isRecoverableSecurePrefsFailure()) {
                throw error
            }
            subscriptionPrefsRef = null
            runCatching { appContext.deleteSharedPreferences(SUBSCRIPTION_PREFS_FILE_NAME) }
            runCatching {
                File(appContext.applicationInfo.dataDir, "shared_prefs/$SUBSCRIPTION_PREFS_FILE_NAME.xml").delete()
            }
            createEncryptedPrefs(SUBSCRIPTION_PREFS_FILE_NAME)
        }.getOrThrow()

    /**
     * Opens one AES-256-GCM preferences file, keyed by a master key held in the Android Keystore.
     *
     * `androidx.security:security-crypto` marks this whole API deprecated and points at plain
     * `SharedPreferences`, which is not an alternative for API keys: it would put them on disk in
     * clear text. There is no drop-in replacement in AndroidX yet, so the suppression stays until a
     * Keystore-backed replacement exists and a migration for existing files is written.
     */
    @Suppress("DEPRECATION")
    private fun createEncryptedPrefs(fileName: String): SharedPreferences {
        val masterKey = MasterKey.Builder(appContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()

        return EncryptedSharedPreferences.create(
            appContext,
            fileName,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun getOrCreateArchiveMasterKey(uid: String): ByteArray {
        val prefs = archivePrefs()
        val key = archiveKeyForUid(uid)
        val existing = prefs.getString(key, null)
        if (!existing.isNullOrBlank()) {
            runCatching {
                val bytes = Base64.decode(existing, Base64.NO_WRAP)
                if (bytes.size == 32) return bytes
            }

        }
        val generated = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs.edit().putString(key, Base64.encodeToString(generated, Base64.NO_WRAP)).apply()
        return generated
    }

    fun deleteArchiveMasterKey(uid: String) {
        archivePrefs().edit().remove(archiveKeyForUid(uid)).apply()
    }

    private fun archivePrefs(): SharedPreferences =
        archivePrefsRef ?: synchronized(this) {
            archivePrefsRef ?: createArchivePrefsWithRecovery().also { archivePrefsRef = it }
        }

    private fun createArchivePrefsWithRecovery(): SharedPreferences =
        runCatching {
            createArchivePrefs()
        }.recoverCatching { error ->
            if (!error.isRecoverableSecurePrefsFailure()) {
                throw error
            }
            clearCorruptedArchivePrefs()
            createArchivePrefs()
        }.getOrThrow()

    private fun createArchivePrefs(): SharedPreferences = createEncryptedPrefs(ARCHIVE_PREFS_FILE_NAME)

    private fun clearCorruptedArchivePrefs() {
        archivePrefsRef = null
        runCatching { appContext.deleteSharedPreferences(ARCHIVE_PREFS_FILE_NAME) }
        runCatching {
            File(appContext.applicationInfo.dataDir, "shared_prefs/$ARCHIVE_PREFS_FILE_NAME.xml").delete()
        }
    }

    private fun prefs(): SharedPreferences =
        prefsRef ?: synchronized(this) {
            prefsRef ?: createPrefsWithRecovery().also { prefsRef = it }
        }

    private fun createPrefsWithRecovery(): SharedPreferences =
        runCatching {
            createPrefs()
        }.recoverCatching { error ->
            if (!error.isRecoverableSecurePrefsFailure()) {
                throw error
            }
            clearCorruptedPrefs()
            createPrefs()
        }.getOrThrow()

    private fun createPrefs(): SharedPreferences = createEncryptedPrefs(PREFS_FILE_NAME)

    private fun clearCorruptedPrefs() {
        prefsRef = null
        runCatching { appContext.deleteSharedPreferences(PREFS_FILE_NAME) }
        runCatching {
            File(appContext.applicationInfo.dataDir, "shared_prefs/$PREFS_FILE_NAME.xml").delete()
        }
    }

    companion object {
        private const val PREFS_FILE_NAME = "oriveo_secure_keys"
        private const val ARCHIVE_PREFS_FILE_NAME = "oriveo_auto_backup_keys"
        private const val SUBSCRIPTION_PREFS_FILE_NAME = "oriveo_provider_subscription_tokens"

        private fun keyFor(accountId: String, providerID: String) =
            "api_key_v2_${accountId.length}:$accountId:$providerID"
        private fun legacyKeyFor(providerID: String) = "api_key_$providerID"
        private fun archiveKeyForUid(uid: String) = "merge_archive_master_key_$uid"
        private fun subscriptionKeyFor(accountId: String, providerID: String) =
            "subscription_oauth_v1_${accountId.length}:$accountId:$providerID"

        fun maskApiKey(key: String): String {
            val trimmed = key.trim()
            if (trimmed.isEmpty()) return ""
            if (trimmed.length <= 12) return "••••••••"
            val prefix = trimmed.take(4)
            val suffix = trimmed.takeLast(4)
            return "$prefix••••$suffix"
        }

        private fun Throwable.isRecoverableSecurePrefsFailure(): Boolean =
            generateSequence(this) { it.cause }.any { cause ->
                cause is AEADBadTagException ||
                    cause.javaClass.simpleName.contains("KeyStoreException", ignoreCase = true) ||
                    cause.message?.contains("VERIFICATION_FAILED", ignoreCase = true) == true ||
                    cause.message?.contains("Signature/MAC verification failed", ignoreCase = true) == true
            }
    }
}
