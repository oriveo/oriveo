package ai.oriveo.community.feature.providers.relay

data class RelayConnectionTestResult(
    val isSuccess: Boolean,
    val message: String,
    val failurePresentation: RelayEditFailurePresentation? = null,
)
