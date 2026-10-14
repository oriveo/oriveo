package ai.oriveo.community.feature.providers.relay

import ai.oriveo.community.core.model.OriveoError

data class RelayConnectionTestResult(
    val isSuccess: Boolean,
    val message: String,
    val failurePresentation: RelayEditFailurePresentation? = null,
    /** The error obtained from the same exception via [ai.oriveo.community.core.error.ErrorMapper] (the failure card takes title and severity); null for a failure without an exception. */
    val error: OriveoError? = null,
)
