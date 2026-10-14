package ai.oriveo.community.core.model

data class CapabilityEvidenceIdentity(
    val partitionId: String,
    val connectionInstanceId: String,
    val connectionGeneration: String,
    val credentialEpoch: String,
    val providerKind: String,
    /** `ProviderAuthMode.rawValue`: the request boundary needs it to derive the form, since the same kind has a different source of truth under API Key and under a subscription. */
    val authMode: String,
    val canonicalModelId: String? = null,
    val metadataRevision: String? = null,
    val generationRevision: String? = null,
)
