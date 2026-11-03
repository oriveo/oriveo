package ai.oriveo.community.core.studio

import ai.oriveo.community.BuildConfig

/**
 * Single source of truth for whether Studio is reachable (shared contract
 * studio-contracts/studio_availability.v1.json). Every entry point asks [evaluate] and
 * nothing else; the remote feature flag keys appear only in this file.
 */
object StudioAvailability {
    const val REMOTE_STUDIO_ENABLED_KEY = "studio_enabled"
    const val REMOTE_MANAGED_ENABLED_KEY = "studio_managed_enabled"

    /** Missing `studio_enabled` means on: the remote flag only hides Studio in an emergency. */
    const val REMOTE_STUDIO_ENABLED_DEFAULT = true

    /** Missing `studio_managed_enabled` means off. */
    const val REMOTE_MANAGED_ENABLED_DEFAULT = false

    /** Compile switch: debug on, release / benchmark off. */
    val compiledIn: Boolean
        get() = BuildConfig.STUDIO_ENABLED

    /** Null remote flags mean "missing" and take the contract default, not false. */
    data class Input(
        val compileFlag: Boolean,
        val remoteStudioEnabled: Boolean? = null,
        val remoteManagedEnabled: Boolean? = null,
        val imageDisabled: Boolean = false,
        val enabledManagedModels: Int = 0,
        val isPro: Boolean,
    )

    data class Result(
        val entryVisible: Boolean,
        val deepLinkOpens: Boolean,
        val badgeRendered: Boolean,
        val managedListed: Boolean,
        val managedInChatPicker: Boolean,
        val chatWorkRegistration: Boolean,
        val syncWorks: Boolean,
    )

    fun evaluate(input: Input): Result {
        val entry = input.compileFlag && (input.remoteStudioEnabled ?: REMOTE_STUDIO_ENABLED_DEFAULT)
        val managed = entry &&
            (input.remoteManagedEnabled ?: REMOTE_MANAGED_ENABLED_DEFAULT) &&
            !input.imageDisabled &&
            input.enabledManagedModels > 0
        return Result(
            entryVisible = entry,
            deepLinkOpens = entry,
            badgeRendered = entry,
            managedListed = managed,
            managedInChatPicker = managed,
            // Chat image works are registered and Pro works sync regardless of the flags.
            chatWorkRegistration = true,
            syncWorks = input.isPro,
        )
    }

    /** Maps metadata runtimeConfig.featureFlags to [Input]; a missing key stays null (default). */
    fun input(
        featureFlags: Map<String, Boolean>?,
        isPro: Boolean,
        compileFlag: Boolean = compiledIn,
        imageDisabled: Boolean = false,
        enabledManagedModels: Int = 0,
    ): Input = Input(
        compileFlag = compileFlag,
        remoteStudioEnabled = featureFlags?.get(REMOTE_STUDIO_ENABLED_KEY),
        remoteManagedEnabled = featureFlags?.get(REMOTE_MANAGED_ENABLED_KEY),
        imageDisabled = imageDisabled,
        enabledManagedModels = enabledManagedModels,
        isPro = isPro,
    )
}
