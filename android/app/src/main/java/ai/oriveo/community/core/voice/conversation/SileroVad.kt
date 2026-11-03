package ai.oriveo.community.core.voice.conversation

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.LongBuffer

/** Silero VAD model load or inference failure; the caller falls back to the non-model VAD. */
class SileroVadUnavailableException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Silero VAD (silero_vad_16k_op15.onnx) on-device inference: input is a 16 kHz mono PCM16 sample stream; one inference runs per full [CHUNK] samples,
 * and the result is written to [latestProb].
 *
 * Model input = the last [CONTEXT] samples of the previous chunk + this chunk's [CHUNK] samples (normalized to [-1, 1]); the recurrent state has shape [2,1,128],
 * sr = 16000. Input and output names are resolved at load time from session.inputNames / outputNames; a mismatch throws
 * [SileroVadUnavailableException].
 *
 * Zero per-frame allocation: input, state and output are tensors on direct buffers created at load time; the output is written back to its buffer via pinned output;
 * two state buffers are used in ping-pong fashion so the same memory is never both input and output.
 *
 * Not thread-safe: [feed] / [reset] / [close] must be called on the same audio thread. The OrtSession is a process singleton shared by all instances.
 */
class SileroVad private constructor(private val model: Model) : AutoCloseable {
    private val env: OrtEnvironment = model.env

    private val inputBuffer: FloatBuffer = directFloats(CONTEXT + CHUNK)
    private val stateBuffers = arrayOf(directFloats(STATE_SIZE), directFloats(STATE_SIZE))
    private val probBuffer: FloatBuffer = directFloats(1)
    private val srBuffer: LongBuffer = ByteBuffer.allocateDirect(Long.SIZE_BYTES).order(ByteOrder.nativeOrder()).asLongBuffer()
        .also { it.put(0, SAMPLE_RATE.toLong()) }

    private val inputTensor = OnnxTensor.createTensor(env, inputBuffer, longArrayOf(1, (CONTEXT + CHUNK).toLong()))
    private val stateTensors = Array(2) { OnnxTensor.createTensor(env, stateBuffers[it], STATE_SHAPE) }
    private val probTensor = OnnxTensor.createTensor(env, probBuffer, longArrayOf(1, 1))
    private val srTensor = OnnxTensor.createTensor(env, srBuffer, longArrayOf())

    /** The i-th copy: uses stateTensors[i] as input state and stateTensors[1 - i] as output state. */
    private val inputs = Array(2) {
        mapOf(model.inputName to inputTensor, model.stateInName to stateTensors[it], model.srName to srTensor)
    }
    private val outputs = Array(2) { mapOf(model.probName to probTensor, model.stateOutName to stateTensors[1 - it]) }

    /** Context from the end of the previous chunk + this chunk's pending samples (normalized); inference runs when CONTEXT + CHUNK is reached. */
    private val window = FloatArray(CONTEXT + CHUNK)
    private var filled = CONTEXT
    private var current = 0
    private var closed = false

    /** Speech probability of the latest chunk; 0 after reset and before the first chunk is inferred. */
    var latestProb: Float = 0f
        private set

    /** Inference time of the latest chunk (nanoseconds, for diagnostics); 0 if never inferred. */
    var lastInferenceNanos: Long = 0L
        private set

    /** Number of chunks inferred since the last reset. */
    var chunkCount: Long = 0L
        private set

    /**
     * Accumulates the first [count] samples of [samples]; inference runs every full [CHUNK] samples and updates [latestProb].
     * Inference failure throws [SileroVadUnavailableException].
     */
    fun feed(samples: ShortArray, count: Int = samples.size) {
        check(!closed) { "SileroVad closed" }
        require(count in 0..samples.size) { "count $count out of 0..${samples.size}" }
        var at = 0
        while (at < count) {
            val take = minOf(count - at, window.size - filled)
            for (index in 0 until take) window[filled + index] = samples[at + index] / PCM_SCALE
            filled += take
            at += take
            if (filled == window.size) infer()
        }
    }

    /** Clears the recurrent state and context, discards samples short of a full chunk, and sets the probability to 0. */
    fun reset() {
        check(!closed) { "SileroVad closed" }
        for (buffer in stateBuffers) for (index in 0 until STATE_SIZE) buffer.put(index, 0f)
        window.fill(0f)
        filled = CONTEXT
        current = 0
        latestProb = 0f
        lastInferenceNanos = 0L
        chunkCount = 0L
    }

    override fun close() {
        if (closed) return
        closed = true
        inputTensor.close()
        stateTensors.forEach { it.close() }
        probTensor.close()
        srTensor.close()
    }

    private fun infer() {
        for (index in window.indices) inputBuffer.put(index, window[index])
        val started = SystemClock.elapsedRealtimeNanos()
        try {
            // All outputs are pinned to our own buffers; Result holds no values, so closing it does not release our tensors.
            model.session.run(inputs[current], outputs[current]).close()
        } catch (error: Exception) {
            throw SileroVadUnavailableException("Silero VAD inference failed", error)
        }
        lastInferenceNanos = SystemClock.elapsedRealtimeNanos() - started
        latestProb = probBuffer.get(0)
        current = 1 - current
        chunkCount++
        // The last CONTEXT samples of this chunk become the context for the next chunk.
        System.arraycopy(window, CHUNK, window, 0, CONTEXT)
        filled = CONTEXT
    }

    private class Model(
        val env: OrtEnvironment,
        val session: OrtSession,
        val inputName: String,
        val stateInName: String,
        val srName: String,
        val probName: String,
        val stateOutName: String,
    )

    companion object {
        const val ASSET = "silero_vad_16k_op15.onnx"
        const val SAMPLE_RATE = 16_000
        const val CHUNK = 512
        const val CONTEXT = 64
        private const val STATE_SIZE = 2 * 1 * 128
        private val STATE_SHAPE = longArrayOf(2, 1, 128)
        private const val PCM_SCALE = 32768f

        private val lock = Any()

        @Volatile
        private var model: Model? = null

        /**
         * Creates a new inference instance; the first call lazily loads the process-singleton OrtEnvironment / OrtSession.
         * Model read, session creation, or input/output name resolution failure throws [SileroVadUnavailableException]; the next call retries loading.
         */
        @Throws(SileroVadUnavailableException::class)
        fun create(context: Context): SileroVad {
            val loaded = model ?: synchronized(lock) { model ?: load(context).also { model = it } }
            return try {
                SileroVad(loaded)
            } catch (error: Exception) {
                throw SileroVadUnavailableException("Silero VAD tensor allocation failed", error)
            }
        }

        private fun load(context: Context): Model {
            val bytes = try {
                context.applicationContext.assets.open(ASSET).use { it.readBytes() }
            } catch (error: Exception) {
                throw SileroVadUnavailableException("Silero VAD model asset $ASSET unreadable", error)
            }
            val env: OrtEnvironment
            val session: OrtSession
            try {
                env = OrtEnvironment.getEnvironment()
                val options = OrtSession.SessionOptions().apply {
                    setIntraOpNumThreads(1)
                    setInterOpNumThreads(1)
                    setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
                }
                session = options.use { env.createSession(bytes, it) }
            } catch (error: Throwable) {
                throw SileroVadUnavailableException("Silero VAD session creation failed", error)
            }
            val inputNames = session.inputNames
            val outputNames = session.outputNames
            fun pick(names: Set<String>, label: String, match: (String) -> Boolean): String =
                names.singleOrNull(match) ?: run {
                    session.close()
                    throw SileroVadUnavailableException("Silero VAD $label not found in inputs=$inputNames outputs=$outputNames")
                }
            val stateIn = pick(inputNames, "state input") { it.contains("state", ignoreCase = true) }
            val sr = pick(inputNames, "sr input") { it.equals("sr", ignoreCase = true) }
            val input = pick(inputNames, "audio input") { it != stateIn && it != sr }
            val stateOut = pick(outputNames, "state output") { it.contains("state", ignoreCase = true) }
            val prob = pick(outputNames, "probability output") { it != stateOut }
            return Model(env, session, input, stateIn, sr, prob, stateOut)
        }

        private fun directFloats(size: Int): FloatBuffer =
            ByteBuffer.allocateDirect(size * Float.SIZE_BYTES).order(ByteOrder.nativeOrder()).asFloatBuffer()
    }
}
