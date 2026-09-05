package ai.oriveo.community.feature.providers

import androidx.compose.ui.graphics.Color


internal fun Color.blendedWith(other: Color, fraction: Float): Color {
    val f = fraction.coerceIn(0f, 1f)
    return Color(
        red = red + (other.red - red) * f,
        green = green + (other.green - green) * f,
        blue = blue + (other.blue - blue) * f,
        alpha = alpha + (other.alpha - alpha) * f,
    )
}


internal fun Color.hsbAdjusted(saturation: Float = 1f, brightness: Float = 1f): Color {
    val r = red
    val g = green
    val b = blue
    val maxC = maxOf(r, g, b)
    val minC = minOf(r, g, b)
    val delta = maxC - minC
    val v = maxC
    val s = if (maxC == 0f) 0f else delta / maxC
    val h = when {
        delta == 0f -> 0f
        maxC == r -> ((g - b) / delta) % 6f
        maxC == g -> ((b - r) / delta) + 2f
        else -> ((r - g) / delta) + 4f
    } * 60f
    val newS = (s * saturation).coerceIn(0f, 1f)
    val newV = (v * brightness).coerceIn(0f, 1f)
    return hsvToRgb(if (h < 0f) h + 360f else h, newS, newV, alpha)
}

private fun hsvToRgb(h: Float, s: Float, v: Float, alpha: Float): Color {
    val c = v * s
    val hh = h / 60f
    val x = c * (1f - kotlin.math.abs(hh % 2f - 1f))
    val (r1, g1, b1) = when {
        hh < 1f -> Triple(c, x, 0f)
        hh < 2f -> Triple(x, c, 0f)
        hh < 3f -> Triple(0f, c, x)
        hh < 4f -> Triple(0f, x, c)
        hh < 5f -> Triple(x, 0f, c)
        else -> Triple(c, 0f, x)
    }
    val m = v - c
    return Color(r1 + m, g1 + m, b1 + m, alpha)
}
