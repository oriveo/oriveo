package ai.oriveo.community.ui.component

private const val MAX_REPRESENTABLE_HEIGHT_PX = 262_142

private const val HEIGHT_CONSTRAINT_ROUNDING_MARGIN_PX = 64

internal const val MAX_HEIGHT_CONSTRAINT_PX =
    MAX_REPRESENTABLE_HEIGHT_PX - HEIGHT_CONSTRAINT_ROUNDING_MARGIN_PX

internal fun coerceHeightConstraintPx(measuredPx: Int): Int {
    if (measuredPx <= 0) return 0
    if (measuredPx <= MAX_HEIGHT_CONSTRAINT_PX) return measuredPx
    return MAX_HEIGHT_CONSTRAINT_PX
}
