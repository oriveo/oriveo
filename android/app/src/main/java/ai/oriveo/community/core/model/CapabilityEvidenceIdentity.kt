package ai.oriveo.community.core.model

data class CapabilityEvidenceIdentity(
    val partitionId: String,
    val connectionInstanceId: String,
    val connectionGeneration: String,
    val credentialEpoch: String,
    val providerKind: String,
    val canonicalModelId: String? = null,
    val metadataRevision: String? = null,
    val generationRevision: String? = null,
)
