package ai.oriveo.community.core.voice

/** Classification of system recognizer failures; the first five are reportable as failure_kind, and the last three each have dedicated handling. */
enum class SystemFailureKind(val rawValue: String) {
    Network("network"),
    Busy("busy"),
    LanguageUnsupported("language_unsupported"),
    NoService("no_service"),
    Other("other"),
    NoTranscript("no_transcript"),
    Permission("permission"),
    Cancelled("cancelled"),
    ;

    /** Whether this is one of the five kinds in constants.systemFailure.kinds (dictationOutcome and the failure_kind telemetry accept only these five). */
    val isReportable: Boolean get() = this in SystemFailure.REPORTABLE_KINDS
}

/** Buttons on the failure card. */
enum class SystemFailureAction(val rawValue: String) {
    Retry("retry"),
    Discard("discard"),
    ChangeLanguage("change_language"),
    SwitchEngine("switch_engine"),
    OpenSettings("open_settings"),
}

/** Failure conditions that are not recognizer error codes; determined by our own checks. */
enum class SystemFailureCondition(val rawValue: String) {
    NoService("no_service"),
    LanguageUnsupported("language_unsupported"),
    Timeout("timeout"),
    Cancelled("cancelled"),

    /** The recognition call threw a non-recognizer exception (our side): counted as other, with no automatic retry. */
    Thrown("thrown"),
}

/** Input to classify: a SpeechRecognizer.ERROR_* platform code, or a self-determined condition. */
sealed interface SystemFailureInput {
    data class Code(val code: Int) : SystemFailureInput
    data class Condition(val condition: SystemFailureCondition) : SystemFailureInput
}

/** Failure telemetry fields; recognizerCode is set only for platform codes, and no_transcript carries neither failureKind nor recognizerCode. */
data class SystemFailureTelemetry(
    val errorCode: String,
    val failureKind: SystemFailureKind?,
    val autoRetried: Boolean,
    val recognizerCode: Int?,
) {
    /** Expands to telemetry field names; absent optional fields are omitted. */
    fun toMap(): Map<String, Any> = buildMap {
        put("error_code", errorCode)
        failureKind?.let { put("failure_kind", it.rawValue) }
        put("auto_retried", autoRetried)
        recognizerCode?.let { put("recognizer_code", it) }
    }
}

/** The six fields are always present; when autoRetry is true, the recognizer is also recreated, with no card shown and no telemetry. */
data class SystemFailureDecision(
    val kind: SystemFailureKind,
    val autoRetry: Boolean,
    val recreateRecognizer: Boolean,
    val primaryAction: SystemFailureAction?,
    val secondaryAction: SystemFailureAction?,
    val telemetry: SystemFailureTelemetry?,
)

/** System recognizer failure code table, one entry per constants.systemFailure in dictation.v1.json (reference implementation: scripts/lib/voice-cloud.mjs:systemFailure). */
object SystemFailure {
    const val BUSY_AUTO_RETRIES = DictationRules.MAX_AUTO_RETRIES
    const val ERROR_CODE_RECOGNIZER = "recognizer"
    const val ERROR_CODE_EMPTY_TRANSCRIPT = "empty_transcript"

    val REPORTABLE_KINDS: List<SystemFailureKind> = listOf(
        SystemFailureKind.Network,
        SystemFailureKind.Busy,
        SystemFailureKind.LanguageUnsupported,
        SystemFailureKind.NoService,
        SystemFailureKind.Other,
    )

    /** AOSP SpeechRecognizer.ERROR_* codes; anything outside the table maps to other. */
    val ANDROID_CODES: Map<Int, SystemFailureKind> = mapOf(
        1 to SystemFailureKind.Network,
        2 to SystemFailureKind.Network,
        3 to SystemFailureKind.Other,
        4 to SystemFailureKind.Other,
        5 to SystemFailureKind.Other,
        6 to SystemFailureKind.NoTranscript,
        7 to SystemFailureKind.NoTranscript,
        8 to SystemFailureKind.Busy,
        9 to SystemFailureKind.Permission,
        10 to SystemFailureKind.Busy,
        11 to SystemFailureKind.Busy,
        12 to SystemFailureKind.LanguageUnsupported,
        13 to SystemFailureKind.LanguageUnsupported,
        14 to SystemFailureKind.Other,
        15 to SystemFailureKind.Other,
    )

    val CONDITIONS: Map<SystemFailureCondition, SystemFailureKind> = mapOf(
        SystemFailureCondition.NoService to SystemFailureKind.NoService,
        SystemFailureCondition.LanguageUnsupported to SystemFailureKind.LanguageUnsupported,
        SystemFailureCondition.Timeout to SystemFailureKind.Busy,
        SystemFailureCondition.Cancelled to SystemFailureKind.Cancelled,
        SystemFailureCondition.Thrown to SystemFailureKind.Other,
    )

    /** Primary / secondary buttons; permission and cancelled are not in the table (they mean open settings and stay silent, respectively). */
    val ACTIONS: Map<SystemFailureKind, Pair<SystemFailureAction, SystemFailureAction>> = mapOf(
        SystemFailureKind.Network to (SystemFailureAction.Retry to SystemFailureAction.Discard),
        SystemFailureKind.Busy to (SystemFailureAction.Retry to SystemFailureAction.Discard),
        SystemFailureKind.LanguageUnsupported to (SystemFailureAction.ChangeLanguage to SystemFailureAction.Discard),
        SystemFailureKind.NoService to (SystemFailureAction.SwitchEngine to SystemFailureAction.Discard),
        SystemFailureKind.Other to (SystemFailureAction.Retry to SystemFailureAction.Discard),
        SystemFailureKind.NoTranscript to (SystemFailureAction.ChangeLanguage to SystemFailureAction.Retry),
    )

    fun kindOf(input: SystemFailureInput): SystemFailureKind = when (input) {
        is SystemFailureInput.Code -> ANDROID_CODES[input.code] ?: SystemFailureKind.Other
        is SystemFailureInput.Condition -> CONDITIONS.getValue(input.condition)
    }

    /**
     * attempt starts at 1 (a manual retry restarts counting from 1). canRetry = whether this failure can be retried losslessly:
     * true for recorded-file recognition; false for realtime sessions and recognizer self-recording (the failure goes to dictationOutcome).
     */
    fun classify(input: SystemFailureInput, attempt: Int, canRetry: Boolean = true): SystemFailureDecision {
        val kind = kindOf(input)
        val none = SystemFailureDecision(kind, false, false, null, null, null)
        when (kind) {
            SystemFailureKind.Cancelled -> return none
            SystemFailureKind.Permission -> return none.copy(primaryAction = SystemFailureAction.OpenSettings)
            SystemFailureKind.Busy -> if (canRetry && attempt <= BUSY_AUTO_RETRIES) {
                return none.copy(autoRetry = true, recreateRecognizer = true)
            }
            else -> Unit
        }
        val (primary, secondary) = ACTIONS.getValue(kind)
        val autoRetried = attempt > 1
        val telemetry = if (kind == SystemFailureKind.NoTranscript) {
            SystemFailureTelemetry(ERROR_CODE_EMPTY_TRANSCRIPT, null, autoRetried, null)
        } else {
            SystemFailureTelemetry(ERROR_CODE_RECOGNIZER, kind, autoRetried, (input as? SystemFailureInput.Code)?.code)
        }
        return none.copy(primaryAction = primary, secondaryAction = secondary, telemetry = telemetry)
    }
}
