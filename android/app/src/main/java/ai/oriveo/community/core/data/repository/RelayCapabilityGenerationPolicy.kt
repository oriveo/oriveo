package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind

internal fun relayConnectionSemanticsChanged(current: Provider, candidate: Provider): Boolean {
    if (current.kind != ProviderKind.Relay || candidate.kind != ProviderKind.Relay) return false
    if (current.baseUrlText?.trim() != candidate.baseUrlText?.trim()) return true
    // relayKind is a display value derived from the default protocol at save time and is not read when sending, so it is not part of the connection identity.
    val before = current.relayRequested
    val after = candidate.relayRequested
    return before?.transport != after?.transport ||
        before?.transportKind != after?.transportKind ||
        before?.authMode != after?.authMode ||
        before?.securityMode != after?.securityMode ||
        before?.resolvedAPIBaseURL != after?.resolvedAPIBaseURL ||
        before?.headers != after?.headers ||
        before?.queryParams != after?.queryParams ||
        before?.certificateFingerprint != after?.certificateFingerprint ||
        before?.engineProfile != after?.engineProfile
}
