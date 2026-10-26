package ai.oriveo.community.core.voice

import java.io.File

/**
 * A recording to transcribe: the slot's .aac plus a recording-time range (seconds, null = whole clip).
 * primingFrames converts recording time to file time, see [RecordingExporter.toM4a].
 */
data class STTSegment(
    val aac: File,
    val range: ClosedFloatingPointRange<Double>? = null,
    val primingFrames: Int = RecordingWriter.DEFAULT_PRIMING_FRAMES,
    /** 50 ms volume envelope from the slot sidecar (recording time); cloud over-limit splitting cuts at silence points, and hard-cuts at Lmax when empty. */
    val envelope: List<Double?> = emptyList(),
)

/** Result of one transcription; on failure the recording stays in the slot and primaryAction decides the primary button in the UI. */
sealed interface STTResult {
    data class Success(val text: String) : STTResult

    data class Failed(
        val failure: DictationFailure,
        val primaryAction: DictationPrimaryAction,
        /** Whether an automatic retry already happened before this failure. */
        val autoRetried: Boolean = false,
    ) : STTResult
}

/** Dictation engine: the shared entry point for system recognition and cloud transcription. */
interface STTEngine {
    /** Engine identifier. */
    val engineName: String

    /** language is the recognition language (e.g. zh-Hans); null means no language hint. */
    suspend fun transcribe(segment: STTSegment, language: String?): STTResult
}
