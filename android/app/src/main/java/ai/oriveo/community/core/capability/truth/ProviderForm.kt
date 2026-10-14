package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind

/**
 * The capability-truth form of a connection (the `forms` of the contract).
 *
 * Derived once from the Provider; every branch in the capability chain reads it instead of comparing `kind` / `authMode` on its own:
 * scattered comparisons sooner or later miss a new form, while `when` is exhaustive over the enum and fails to compile if one is missed.
 * Declaration order is the evaluation order, consistent with the contract `forms.order`.
 */
enum class ProviderForm {
    Relay,
    Subscription,
    Official;

    companion object {
        fun of(provider: Provider): ProviderForm = of(provider.kind, provider.authMode)

        /**
         * Order is fixed, first match wins. Relay comes before Subscription: subscription login is only
         * implemented for official providers, and the Relay catalog comes from the user's own machine, so even with subscription-shaped credentials truth is taken as Relay.
         */
        fun of(kind: ProviderKind, authMode: ProviderAuthMode): ProviderForm = when {
            kind == ProviderKind.Relay -> Relay
            authMode == ProviderAuthMode.Subscription -> Subscription
            else -> Official
        }
    }
}
