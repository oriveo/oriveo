package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind

internal fun relayConnectionSemanticsChanged(current: Provider, candidate: Provider): Boolean {
    if (current.kind != ProviderKind.Relay || candidate.kind != ProviderKind.Relay) return false
    if (current.baseUrlText?.trim() != candidate.baseUrlText?.trim()) return true
    if (current.relayKind != candidate.relayKind) return true
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
