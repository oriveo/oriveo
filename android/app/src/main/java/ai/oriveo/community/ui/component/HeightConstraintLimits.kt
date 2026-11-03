package ai.oriveo.community.ui.component

/**
 * The largest height in px that Compose [androidx.compose.ui.unit.Constraints] can represent when the **width axis has no value**.
 *
 * Constraints packs min/max into a single Long: `createConstraints` first computes the bit width needed for `widthVal`
 * (degrades to minWidth when maxWidth is Infinity) and for `heightVal`. If the two together exceed 31 bits it throws
 * `IllegalArgumentException: Can't represent a width of W and height of H in Constraints`.
 * `Modifier.heightIn(min=)` / `Modifier.height()` set no width, so widthVal = 0 and the width takes only the minimum 13 bits,
 * leaving 18 bits for height (`MaxFocusMask = 0x3FFFF`), so the representable ceiling is 262142 px.
 */
private const val MAX_REPRESENTABLE_HEIGHT_PX = 262_142

private const val HEIGHT_CONSTRAINT_ROUNDING_MARGIN_PX = 64

internal const val MAX_HEIGHT_CONSTRAINT_PX =
    MAX_REPRESENTABLE_HEIGHT_PX - HEIGHT_CONSTRAINT_ROUNDING_MARGIN_PX

internal fun coerceHeightConstraintPx(measuredPx: Int): Int {
    if (measuredPx <= 0) return 0
    if (measuredPx <= MAX_HEIGHT_CONSTRAINT_PX) return measuredPx
    return MAX_HEIGHT_CONSTRAINT_PX
}
