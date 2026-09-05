package ai.oriveo.community.core.provider.openai

import ai.oriveo.community.core.security.SecureKeyStore
import kotlinx.serialization.json.Json

/**
 * Storage facade for the OAuth credentials of Codex, the ChatGPT subscription sign-in path.
 *
 * It only converts between the serialized form and encrypted storage. When to write and what
 * a write means is decided by [OpenAISubscriptionRuntime].
 *
 * It reuses the subscription namespace [SecureKeyStore] already has
 * (`oriveo_provider_subscription_tokens`) rather than opening a third prefs file just for
 * Codex. That is safe because `subscriptionKeyFor(accountId, providerID)` is indexed by
 * *provider instance*, and an instance has exactly one kind and one auth mode: the same
 * providerID can never be both a Grok subscription and a Codex subscription. The
 * deterministic id of a first-party provider encodes its kind (see
 * `DeterministicProviderId.forProvider`), and a second account of the same provider gets a
 * random id. So the two paths cannot collide on a key.
 *
 * The price of that assumption is that the read and write sides must dispatch on kind. The
 * slot is shared, and because of `ignoreUnknownKeys` handing a Codex credential to Grok's
 * decoder will appear to succeed - after which Grok's disconnect would ship a ChatGPT access
 * token off to x.ai's revocation endpoint. The dispatch lives in the three kind checks in
 * `ProviderRepository`.
 */
class OpenAISubscriptionCredentialStore(
    private val secureKeyStore: SecureKeyStore,
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun save(accountId: String, providerID: String, tokens: OpenAISubscriptionTokens) {
        secureKeyStore.saveSubscriptionCredential(
            accountId = accountId,
            providerID = providerID,
            payload = json.encodeToString(OpenAISubscriptionTokens.serializer(), tokens),
        )
    }

    fun load(accountId: String, providerID: String): OpenAISubscriptionTokens? {
        val raw = secureKeyStore.loadSubscriptionCredential(accountId, providerID)
            ?.takeIf { it.isNotBlank() } ?: return null
        return runCatching {
            json.decodeFromString(OpenAISubscriptionTokens.serializer(), raw)
        }.getOrNull()
    }

    fun delete(accountId: String, providerID: String) {
        secureKeyStore.deleteSubscriptionCredential(accountId, providerID)
    }
}

/**
 * Prepares credentials before a Codex subscription request goes out: take the current access
 * token, refresh it if needed, assemble the outbound context.
 *
 * Kept separate from [OpenAISubscriptionOAuthClient] (pure network) and
 * [OpenAISubscriptionCredentialStore] (pure storage): this is the layer that strings the two
 * together into "what has to happen before one send", and the only place that decides between
 * refreshing, demanding a fresh sign-in, and letting the request through as is. Structurally
 * the same as `GrokSubscriptionRuntime`.
 */
class OpenAISubscriptionRuntime(
    private val credentialStore: OpenAISubscriptionCredentialStore,
    private val oauthClient: OpenAISubscriptionOAuthClient,
    private val availabilityProvider: () -> OpenAISubscriptionAvailability,
    private val now: () -> Long = System::currentTimeMillis,
) {
    data class Prepared(
        val accessToken: String,
        val context: OpenAISubscriptionRequestContext,
        /**
         * Whether a refresh happened on this call. If it did, the stored credential has been
         * rewritten in full, so a caller still holding an older snapshot must re-read it.
         */
        val didRefresh: Boolean,
    )

    sealed class PrepareResult {
        data class Success(val prepared: Prepared) : PrepareResult()
        data class Failure(val error: OpenAISubscriptionError) : PrepareResult()
    }

    /**
     * Gathers everything one subscription request needs.
     *
     * Failures always carry a specific meaning rather than a generic error, because the caller
     * decides from it which sentence the user sees: "sign in again" and "your ChatGPT plan does
     * not include Codex" call for completely different next steps.
     */
    suspend fun prepare(accountId: String, providerID: String): PrepareResult {
        val availability = availabilityProvider()
        val config = (availability as? OpenAISubscriptionAvailability.Available)?.config
            // Either the kill switch turned it off or the catalog does not publish it: stop
            // before making a request. The UI is responsible for telling an already connected
            // instance that it is degraded; all this has to guarantee is that we do not keep
            // hitting upstream with a configuration that may already be invalid.
            ?: return PrepareResult.Failure(OpenAISubscriptionError.ConfigurationUnavailable)

        val stored = credentialStore.load(accountId, providerID)
            ?: return PrepareResult.Failure(OpenAISubscriptionError.Unauthorized)
        // A credential with no accountId would go out without the `chatgpt-account-id` header
        // and be rejected outright. Ask for a fresh sign-in instead of sending it anyway:
        // failing here is more honest than letting the user hit an error one step later that
        // gives them nothing to act on.
        val accountKey = stored.accountId.trim()
        if (accountKey.isEmpty()) return PrepareResult.Failure(OpenAISubscriptionError.Unauthorized)

        // The accountId comes from the copy stored in the credential, which was decoded and
        // validated at token-exchange time, rather than being decoded from the access token
        // here: `chatgpt_account_id` lives in the id_token and is not guaranteed to be present
        // in the access token.
        fun contextFor(id: String) = OpenAISubscriptionRequestContext(
            responsesUrl = config.responsesUrl,
            accountId = id,
            requiredHeaders = config.requiredHeaders,
        )

        val timestamp = now()
        if (!stored.needsRefresh(timestamp)) {
            return PrepareResult.Success(
                Prepared(stored.accessToken, contextFor(accountKey), didRefresh = false),
            )
        }

        // Expired with no refresh token left: the only way forward is a fresh authorization.
        val refreshToken = stored.refreshToken
            ?: return PrepareResult.Failure(OpenAISubscriptionError.Unauthorized)

        return try {
            // A refresh response usually carries back neither a refresh_token nor an id_token,
            // so the previous values have to be passed in and carried forward. Otherwise the
            // refresh would wipe out both the ability to refresh again and the account
            // identity.
            val refreshed = oauthClient.refreshTokens(
                config = config,
                refreshToken = refreshToken,
                previousAccountId = accountKey,
                previousPlanType = stored.planType,
            )
            credentialStore.save(accountId, providerID, refreshed)
            PrepareResult.Success(
                Prepared(
                    refreshed.accessToken,
                    contextFor(refreshed.accountId.trim().ifEmpty { accountKey }),
                    didRefresh = true,
                ),
            )
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (error: Exception) {
            // Let the request through if the refresh failed but the old token has not actually
            // expired yet: needsRefresh fires five minutes early, the old token is still valid
            // across that window, and kicking the user back to a sign-in screen over one
            // network hiccup is far too blunt.
            val expiresAt = stored.expiresAt
            if (expiresAt != null && timestamp < expiresAt) {
                PrepareResult.Success(
                    Prepared(stored.accessToken, contextFor(accountKey), didRefresh = false),
                )
            } else {
                // When upstream said something more specific - plan not eligible, quota
                // exhausted, 426 - keep its meaning instead of flattening everything into
                // "please sign in again".
                PrepareResult.Failure(
                    (error as? OpenAISubscriptionException)?.error
                        ?: OpenAISubscriptionError.Unauthorized,
                )
            }
        }
    }

    /** Persists tokens after a first authorization or a re-authorization succeeds. */
    fun persist(accountId: String, providerID: String, tokens: OpenAISubscriptionTokens) {
        credentialStore.save(accountId, providerID, tokens)
    }

    fun load(accountId: String, providerID: String): OpenAISubscriptionTokens? =
        credentialStore.load(accountId, providerID)

    /**
     * Disconnects the subscription.
     *
     * Codex publishes no revocation endpoint - the key difference from Grok - so this only
     * deletes locally; there is no "notify upstream on a best-effort basis" step. Do not
     * substitute Grok's revocationEndpoint here: that would send a ChatGPT token to x.ai.
     */
    fun disconnect(accountId: String, providerID: String) {
        credentialStore.delete(accountId, providerID)
    }
}

/**
 * Translates the failure semantics of the Codex subscription path into a user-facing provider
 * error.
 *
 * Intermediate states (pending / slow_down) and transport or unclassified upstream errors do
 * not belong in this table: the former are absorbed by the state machine itself, and the
 * latter still travel as generic network errors rather than being forced into one of the four
 * subscription categories where they would masquerade as a precise diagnosis.
 */
fun OpenAISubscriptionError.toProviderServiceError(): ai.oriveo.community.core.model.ProviderServiceError =
    when (this) {
        is OpenAISubscriptionError.ClientVersionRejected,
        is OpenAISubscriptionError.ConfigurationUnavailable,
        -> ai.oriveo.community.core.model.ProviderServiceError.OpenAISubscription(
            ai.oriveo.community.core.model.OpenAISubscriptionFailureReason.Unavailable,
            detail = toString(),
        )

        is OpenAISubscriptionError.SubscriptionNotEligible ->
            ai.oriveo.community.core.model.ProviderServiceError.OpenAISubscription(
                ai.oriveo.community.core.model.OpenAISubscriptionFailureReason.NotEligible,
                detail = toString(),
            )

        is OpenAISubscriptionError.Unauthorized ->
            ai.oriveo.community.core.model.ProviderServiceError.OpenAISubscription(
                ai.oriveo.community.core.model.OpenAISubscriptionFailureReason.Expired,
                detail = toString(),
            )

        is OpenAISubscriptionError.QuotaExhausted ->
            ai.oriveo.community.core.model.ProviderServiceError.OpenAISubscription(
                ai.oriveo.community.core.model.OpenAISubscriptionFailureReason.QuotaExhausted,
                detail = toString(),
            )

        is OpenAISubscriptionError.Transport ->
            ai.oriveo.community.core.model.ProviderServiceError.Network(detail)

        is OpenAISubscriptionError.Upstream ->
            ai.oriveo.community.core.model.ProviderServiceError.Upstream(status, body)

        is OpenAISubscriptionError.AuthorizationPending,
        is OpenAISubscriptionError.SlowDown,
        is OpenAISubscriptionError.CodeExpired,
        is OpenAISubscriptionError.AccessDenied,
        -> ai.oriveo.community.core.model.ProviderServiceError.Upstream(0, toString())
    }
