package ai.oriveo.community.feature.providers

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Job


enum class CustomLLMConnectionMethod { Relay, Local }

enum class CustomLLMSetupPhase { Ready, Detecting, Saving, Testing, Failed }

enum class CustomLLMVerificationEvidence {
    GenerationVerified,
    ManualModelRequired,
    UnverifiedManual,
}

class CustomLLMSetupAttempt internal constructor(
    internal val generation: Long,
    val method: CustomLLMConnectionMethod,
)

data class CustomLLMConnectionEvidence(
    val verification: CustomLLMVerificationEvidence,
    val catalogAvailable: Boolean,
) {
    val canCommit: Boolean
        get() = verification == CustomLLMVerificationEvidence.GenerationVerified ||
            verification == CustomLLMVerificationEvidence.ManualModelRequired ||
            verification == CustomLLMVerificationEvidence.UnverifiedManual
}

class CustomLLMSetupCoordinator(
    initialMethod: CustomLLMConnectionMethod = CustomLLMConnectionMethod.Relay,
) {
    var method: CustomLLMConnectionMethod by mutableStateOf(initialMethod)
        private set
    var phase: CustomLLMSetupPhase by mutableStateOf(CustomLLMSetupPhase.Ready)
        private set
    var evidence: CustomLLMConnectionEvidence? by mutableStateOf(null)
        private set

    private var generation = 0L
    private var activeJob: Job? = null

    val canCommit: Boolean
        get() = phase == CustomLLMSetupPhase.Ready && evidence?.canCommit == true

    fun selectMethod(next: CustomLLMConnectionMethod) {
        if (method == next) return
        method = next
        invalidate()
    }

    fun begin(
        method: CustomLLMConnectionMethod,
        phase: CustomLLMSetupPhase,
    ): CustomLLMSetupAttempt {
        check(method == this.method) { "Only the selected Custom LLM method may start work" }
        invalidate()
        this.phase = phase
        return CustomLLMSetupAttempt(generation, method)
    }

    fun registerCancellation(attempt: CustomLLMSetupAttempt, job: Job) {
        if (isCurrent(attempt)) activeJob = job else job.cancel()
    }

    fun isCurrent(attempt: CustomLLMSetupAttempt): Boolean =
        attempt.generation == generation && attempt.method == method

    fun acceptEvidence(attempt: CustomLLMSetupAttempt, value: CustomLLMConnectionEvidence): Boolean {
        if (!isCurrent(attempt)) return false
        evidence = value
        phase = CustomLLMSetupPhase.Ready
        return true
    }

    fun acceptFailure(attempt: CustomLLMSetupAttempt): Boolean {
        if (!isCurrent(attempt)) return false
        evidence = null
        phase = CustomLLMSetupPhase.Failed
        activeJob = null
        return true
    }

    fun finish(attempt: CustomLLMSetupAttempt): Boolean {
        if (!isCurrent(attempt)) return false
        phase = CustomLLMSetupPhase.Ready
        activeJob = null
        return true
    }

    
    fun beginCommit(method: CustomLLMConnectionMethod): CustomLLMSetupAttempt? {
        if (method != this.method || !canCommit) return null
        phase = CustomLLMSetupPhase.Saving
        return CustomLLMSetupAttempt(generation, method)
    }

    fun canPersist(attempt: CustomLLMSetupAttempt): Boolean =
        isCurrent(attempt) && phase == CustomLLMSetupPhase.Saving && evidence?.canCommit == true

    fun finishCommit(attempt: CustomLLMSetupAttempt): Boolean {
        if (!canPersist(attempt)) return false
        phase = CustomLLMSetupPhase.Ready
        activeJob = null
        return true
    }

    
    fun canNavigate(method: CustomLLMConnectionMethod): Boolean =
        this.method == method && phase == CustomLLMSetupPhase.Ready && evidence?.canCommit == true

    fun invalidate() {
        generation += 1
        activeJob?.cancel()
        activeJob = null
        evidence = null
        phase = CustomLLMSetupPhase.Ready
    }
}
