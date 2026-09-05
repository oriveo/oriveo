package ai.oriveo.community.feature.providers

/**
 *
 *
 *
 */
interface SubscriptionAuthorizationSnapshotStore {

    /** Provider subscription device-code authorization host. */
    fun read(): String?

    /** Provider subscription device-code authorization host. */
    fun write(value: String?)

    /** Provider subscription device-code authorization host. */
    object None : SubscriptionAuthorizationSnapshotStore {
        override fun read(): String? = null
        override fun write(value: String?) = Unit
    }
}
