package ai.oriveo.community.core.context

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * Bytes-to-tokens ratio for one (transport instance, model). Samples 1-2 are only collected;
 * the 3rd seeds rho with their mean; later samples apply EWMA. Operand order follows budget.v1 rules.
 * Immutable: recording* return a new value. JSON shape `{n, rho, seeds}`.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class RhoCalibration(
    @EncodeDefault val n: Int = 0,
    @EncodeDefault val rho: Double = ContextBudget.RHO0,
    /** First samples kept until the seed is set (at most MIN_SAMPLES). */
    @EncodeDefault val seeds: List<Double> = emptyList(),
) {
    @Transient
    val rhoHi: Double = if (n >= ContextBudget.MIN_SAMPLES) rho * ContextBudget.SAFETY_FACTOR else rho

    fun recordingSample(observedInput: Int?, mediaTokens: Int, textBytes: Int): RhoCalibration {
        if (observedInput == null || textBytes <= 0) return this
        val sample = (observedInput - mediaTokens).toDouble() / textBytes
        if (sample <= 0.0) return this
        val count = n + 1
        return when {
            count < ContextBudget.MIN_SAMPLES -> copy(n = count, seeds = seeds + sample)
            count == ContextBudget.MIN_SAMPLES -> {
                val all = seeds + sample
                var sum = 0.0
                all.forEach { sum += it }
                copy(n = count, rho = clamp(sum / all.size), seeds = all)
            }
            else -> copy(
                n = count,
                rho = clamp(ContextBudget.EWMA_ALPHA * sample + (1 - ContextBudget.EWMA_ALPHA) * rho),
            )
        }
    }

    /** Predicted fit but the provider reported overflow: raise rho. */
    fun recordingOverflowMiss(): RhoCalibration =
        copy(rho = minOf(ContextBudget.RHO_MAX, rho * ContextBudget.OVERFLOW_MISS_FACTOR))

    private fun clamp(value: Double): Double = value.coerceIn(ContextBudget.RHO_MIN, ContextBudget.RHO_MAX)
}

/** One table row; JSON is flat `{transportInstanceId, modelId, n, rho, seeds}`. */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class RhoCalibrationEntry(
    val transportInstanceId: String,
    val modelId: String,
    @EncodeDefault val n: Int = 0,
    @EncodeDefault val rho: Double = ContextBudget.RHO0,
    @EncodeDefault val seeds: List<Double> = emptyList(),
) {
    val calibration: RhoCalibration get() = RhoCalibration(n = n, rho = rho, seeds = seeds)

    companion object {
        fun of(transportInstanceId: String, modelId: String, calibration: RhoCalibration): RhoCalibrationEntry =
            RhoCalibrationEntry(transportInstanceId, modelId, calibration.n, calibration.rho, calibration.seeds)
    }
}

/**
 * Calibrations keyed by (transportInstanceId, modelId); missing keys read as rho0.
 * JSON `{version: 1, entries: [...]}` with entries sorted by (transportInstanceId, modelId).
 */
@Serializable(with = RhoCalibrationTableSerializer::class)
data class RhoCalibrationTable(
    val entries: List<RhoCalibrationEntry> = emptyList(),
) {
    fun calibration(transportInstanceId: String, modelId: String): RhoCalibration =
        entries.firstOrNull { it.transportInstanceId == transportInstanceId && it.modelId == modelId }
            ?.calibration ?: RhoCalibration()

    fun updating(
        transportInstanceId: String,
        modelId: String,
        transform: (RhoCalibration) -> RhoCalibration,
    ): RhoCalibrationTable {
        val next = transform(calibration(transportInstanceId, modelId))
        val others = entries.filterNot { it.transportInstanceId == transportInstanceId && it.modelId == modelId }
        return copy(entries = sorted(others + RhoCalibrationEntry.of(transportInstanceId, modelId, next)))
    }

    companion object {
        const val VERSION: Int = 1

        internal fun sorted(entries: List<RhoCalibrationEntry>): List<RhoCalibrationEntry> =
            entries.sortedWith(compareBy<RhoCalibrationEntry> { it.transportInstanceId }.thenBy { it.modelId })
    }
}

@Serializable
private class RhoCalibrationTableWire(val version: Int, val entries: List<RhoCalibrationEntry>)

internal object RhoCalibrationTableSerializer : KSerializer<RhoCalibrationTable> {
    override val descriptor: SerialDescriptor = RhoCalibrationTableWire.serializer().descriptor

    override fun serialize(encoder: Encoder, value: RhoCalibrationTable) {
        encoder.encodeSerializableValue(
            RhoCalibrationTableWire.serializer(),
            RhoCalibrationTableWire(RhoCalibrationTable.VERSION, RhoCalibrationTable.sorted(value.entries)),
        )
    }

    override fun deserialize(decoder: Decoder): RhoCalibrationTable {
        val wire = decoder.decodeSerializableValue(RhoCalibrationTableWire.serializer())
        if (wire.version != RhoCalibrationTable.VERSION) {
            throw SerializationException("unsupported RhoCalibrationTable version ${wire.version}")
        }
        return RhoCalibrationTable(RhoCalibrationTable.sorted(wire.entries))
    }
}
