package ai.oriveo.community.feature.providers

/**
 * Somewhere to park a device-code authorization while it is still pending.
 *
 * Signing in with a provider subscription means showing the user a code, sending them to the
 * provider's site, and polling until they approve it. That window is long enough for the activity to
 * be recreated, so the pending authorization plus its deadline is written here as one opaque string
 * and read back on the way in. The value is not a credential: the token is only issued once polling
 * succeeds, and it goes to the encrypted key store.
 */
interface SubscriptionAuthorizationSnapshotStore {

    /** Returns the pending authorization, or null when there is none to resume. */
    fun read(): String?

    /** Stores a pending authorization, or clears it when [value] is null. */
    fun write(value: String?)

    /** Discards everything, for callers that have no state to survive - tests and previews. */
    object None : SubscriptionAuthorizationSnapshotStore {
        override fun read(): String? = null
        override fun write(value: String?) = Unit
    }
}
