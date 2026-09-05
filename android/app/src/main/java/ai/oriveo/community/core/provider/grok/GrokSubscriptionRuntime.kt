package ai.oriveo.community.core.provider.grok

import ai.oriveo.community.core.security.SecureKeyStore
import kotlinx.serialization.json.Json

/**
 * Facade over OAuth credential storage for Grok subscription sign-in.
 *
 * It only converts between serialized form and encrypted storage; when and why a write
 * happens is decided by [GrokSubscriptionRuntime]. The underlying namespace is separate from
 * the apiKey slot, see [SecureKeyStore.saveSubscriptionCredential].
 */
class GrokSubscriptionCredentialStore(
    private val secureKeyStore: SecureKeyStore,
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun save(accountId: String, providerID: String, tokens: GrokSubscriptionTokens) {
        secureKeyStore.saveSubscriptionCredential(
            accountId = accountId,
            providerID = providerID,
            payload = json.encodeToString(GrokSubscriptionTokens.serializer(), tokens),
        )
    }

    fun load(accountId: String, providerID: String): GrokSubscriptionTokens? {
        val raw = secureKeyStore.loadSubscriptionCredential(accountId, providerID)
            ?.takeIf { it.isNotBlank() } ?: return null
        return runCatching {
            json.decodeFromString(GrokSubscriptionTokens.serializer(), raw)
        }.getOrNull()
    }

    fun delete(accountId: String, providerID: String) {
        secureKeyStore.deleteSubscriptionCredential(accountId, providerID)
    }
}

/**
 * Credential preparation before an outbound subscription request: fetch the current access
 * token, renew it when needed, and assemble the outbound context.
 *
 * Kept separate from [GrokSubscriptionOAuthClient] (pure networking) and
 * [GrokSubscriptionCredentialStore] (pure storage): this is the layer that strings the two
 * together around "what has to happen before one send", and the single place that decides
 * between renewing, demanding a fresh sign-in, and simply letting the request through.
 */
class GrokSubscriptionRuntime(
    private val credentialStore: GrokSubscriptionCredentialStore,
    private val oauthClient: GrokSubscriptionOAuthClient,
    private val availabilityProvider: () -> GrokSubscriptionAvailability,
    private val now: () -> Long = System::currentTimeMillis,
) {
    data class Prepared(
        val accessToken: String,
        val context: GrokSubscriptionRequestContext,
        /**
         * Whether a renewal happened on this call. If it did, the refresh token in storage
         * has been rotated, so a caller still holding an older snapshot has to re-read it.
         */
        val didRefresh: Boolean,
    )

    sealed class PrepareResult {
        data class Success(val prepared: Prepared) : PrepareResult()
        data class Failure(val error: GrokSubscriptionError) : PrepareResult()
    }

    /**
     * Assembles everything one subscription request needs.
     *
     * Failures always return a specific meaning rather than a generic error, because the
     * caller decides which sentence the user sees from it: "please authorize again" and
     * "your subscription tier does not cover this" call for completely different next steps.
     */
    suspend fun prepare(accountId: String, providerID: String): PrepareResult {
        val availability = availabilityProvider()
        val config = (availability as? GrokSubscriptionAvailability.Available)?.config
            // Switched off by the kill switch, or absent from the config: stop sending.
            // Degradation notices for already-connected instances are the UI's job; all
            // this does is guarantee we never keep hitting upstream with a config that
            // may already be invalid.
            ?: return PrepareResult.Failure(GrokSubscriptionError.ConfigurationUnavailable)

        val stored = credentialStore.load(accountId, providerID)
            ?: return PrepareResult.Failure(GrokSubscriptionError.Unauthorized)

        val context = GrokSubscriptionRequestContext(
            chatUrl = config.chatUrl,
            responsesUrl = config.responsesUrl,
            requiredHeaders = config.requiredHeaders,
            transport = GrokSubscriptionAuthResolver.transportKind(config.apiBackend)
                ?: ai.oriveo.community.core.provider.transport.TransportKind.OpenAIResponses.wireValue,
        )

        val timestamp = now()
        if (!stored.needsRefresh(timestamp)) {
            return PrepareResult.Success(Prepared(stored.accessToken, context, didRefresh = false))
        }

        // Expired with no refresh token in hand: the only way out is a fresh authorization.
        val refreshToken = stored.refreshToken
            ?: return PrepareResult.Failure(GrokSubscriptionError.Unauthorized)

        return try {
            val refreshed = oauthClient.refreshTokens(config, refreshToken)
            // xAI rotates refresh_token on every refresh, so the whole record is written
            // back; otherwise the next renewal would present an already-revoked token.
            credentialStore.save(accountId, providerID, refreshed)
            PrepareResult.Success(Prepared(refreshed.accessToken, context, didRefresh = true))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            // The refresh failed but the old token has not truly expired yet, so let it
            // through: needsRefresh fires 5 minutes early and the old token is still valid
            // inside that window. Kicking the user back to sign-in over one network blip
            // would be far too blunt.
            val expiresAt = stored.expiresAt
            if (expiresAt != null && timestamp < expiresAt) {
                PrepareResult.Success(Prepared(stored.accessToken, context, didRefresh = false))
            } else {
                PrepareResult.Failure(GrokSubscriptionError.Unauthorized)
            }
        }
    }

    /** Persists tokens after a first or repeat authorization succeeds. */
    fun persist(accountId: String, providerID: String, tokens: GrokSubscriptionTokens) {
        credentialStore.save(accountId, providerID, tokens)
    }

    fun load(accountId: String, providerID: String): GrokSubscriptionTokens? =
        credentialStore.load(accountId, providerID)

    /**
     * Disconnects the subscription: best-effort revoke upstream first, then delete locally.
     *
     * A failed revoke does not block the local delete - the user pressed Disconnect, so this
     * device should not keep a usable token lying around either way.
     */
    suspend fun disconnect(accountId: String, providerID: String) {
        val config = (availabilityProvider() as? GrokSubscriptionAvailability.Available)?.config
        val stored = credentialStore.load(accountId, providerID)
        if (config != null && stored != null) {
            oauthClient.revoke(config, stored.accessToken)
        }
        credentialStore.delete(accountId, providerID)
    }
}

/**
 * Translates a subscription-route failure into a user-visible Provider error.
 *
 * Intermediate states (pending / slow_down) and transport or unclassified upstream errors
 * are deliberately not in this table: the former are absorbed by the state machine itself,
 * and the latter stay on the generic network error path rather than being crammed into one
 * of the four subscription categories to fake a precise diagnosis.
 */
fun GrokSubscriptionError.toProviderServiceError(): ai.oriveo.community.core.model.ProviderServiceError =
    when (this) {
        is GrokSubscriptionError.ClientVersionRejected,
        is GrokSubscriptionError.ConfigurationUnavailable,
        -> ai.oriveo.community.core.model.ProviderServiceError.GrokSubscription(
            ai.oriveo.community.core.model.GrokSubscriptionFailureReason.ClientVersionRejected,
            detail = toString(),
        )

        is GrokSubscriptionError.SubscriptionNotEligible ->
            ai.oriveo.community.core.model.ProviderServiceError.GrokSubscription(
                ai.oriveo.community.core.model.GrokSubscriptionFailureReason.NotEligible,
                detail = toString(),
            )

        is GrokSubscriptionError.Unauthorized ->
            ai.oriveo.community.core.model.ProviderServiceError.GrokSubscription(
                ai.oriveo.community.core.model.GrokSubscriptionFailureReason.Expired,
                detail = toString(),
            )

        is GrokSubscriptionError.QuotaExhausted ->
            ai.oriveo.community.core.model.ProviderServiceError.GrokSubscription(
                ai.oriveo.community.core.model.GrokSubscriptionFailureReason.QuotaExhausted,
                detail = toString(),
            )

        is GrokSubscriptionError.Transport ->
            ai.oriveo.community.core.model.ProviderServiceError.Network(detail)

        is GrokSubscriptionError.Upstream ->
            ai.oriveo.community.core.model.ProviderServiceError.Upstream(status, body)

        is GrokSubscriptionError.AuthorizationPending,
        is GrokSubscriptionError.SlowDown,
        is GrokSubscriptionError.CodeExpired,
        is GrokSubscriptionError.AccessDenied,
        -> ai.oriveo.community.core.model.ProviderServiceError.Upstream(0, toString())
    }
