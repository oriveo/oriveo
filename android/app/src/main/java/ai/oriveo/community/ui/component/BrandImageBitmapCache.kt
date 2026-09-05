package ai.oriveo.community.ui.component

import android.content.res.Resources
import android.graphics.BitmapFactory
import android.util.TypedValue
import androidx.annotation.DrawableRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.roundToInt


@Stable
class BrandImageBitmapCache(private val resources: Resources) {
    private data class CacheKey(@DrawableRes val resId: Int, val sampleSize: Int)
    private data class BitmapResourceInfo(val displayMaxEdgePx: Int)

    private val cache = ConcurrentHashMap<CacheKey, ImageBitmap>()
    private val resourceInfo = ConcurrentHashMap<Int, BitmapResourceInfo>()
    
    private val nonBitmap = ConcurrentHashMap.newKeySet<Int>()

    
    fun getOrNull(@DrawableRes resId: Int, targetEdgePx: Int): ImageBitmap? {
        if (nonBitmap.contains(resId)) return null

        val info = resourceInfo[resId] ?: readBitmapResourceInfo(resId)?.also {
            resourceInfo.putIfAbsent(resId, it)
        }
        if (info == null) {
            nonBitmap.add(resId)
            return null
        }

        val sampleSize = calculateResourceSampleSize(info.displayMaxEdgePx, targetEdgePx)
        val key = CacheKey(resId, sampleSize)
        cache[key]?.let { return it }

        val decoded = runCatching {
            BitmapFactory.decodeResource(
                resources,
                resId,
                BitmapFactory.Options().apply { inSampleSize = sampleSize },
            )
        }.getOrNull()
        if (decoded == null) {
            nonBitmap.add(resId)
            return null
        }
        val imageBitmap = decoded.asImageBitmap()
        
        
        return cache.putIfAbsent(key, imageBitmap) ?: imageBitmap
    }

    
    internal suspend fun preload(requests: List<BrandImageRequest>) = withContext(Dispatchers.IO) {
        requests.forEach { getOrNull(it.resId, it.targetEdgePx) }
    }

    private fun readBitmapResourceInfo(resId: Int): BitmapResourceInfo? = runCatching {
        val value = TypedValue()
        resources.getValue(resId, value, true)
        val path = value.string?.toString().orEmpty()
        val isBitmap = path.endsWith(".png", ignoreCase = true) ||
            path.endsWith(".jpg", ignoreCase = true) ||
            path.endsWith(".jpeg", ignoreCase = true) ||
            path.endsWith(".webp", ignoreCase = true)
        if (!isBitmap) return@runCatching null

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeResource(resources, resId, bounds)
        val rawMaxEdge = max(bounds.outWidth, bounds.outHeight)
        if (rawMaxEdge <= 0) return@runCatching null

        val densityScale = if (bounds.inScaled && bounds.inDensity > 0 && bounds.inTargetDensity > 0) {
            bounds.inTargetDensity.toFloat() / bounds.inDensity.toFloat()
        } else {
            1f
        }
        BitmapResourceInfo((rawMaxEdge * densityScale).roundToInt().coerceAtLeast(1))
    }.getOrNull()
}

internal data class BrandImageRequest(@DrawableRes val resId: Int, val targetEdgePx: Int)

internal data class BrandPreloadSpec(@DrawableRes val resId: Int, val targetSize: Dp)


internal fun calculateResourceSampleSize(sourceEdgePx: Int, targetEdgePx: Int): Int {
    if (sourceEdgePx <= 0 || targetEdgePx <= 0 || sourceEdgePx <= targetEdgePx) return 1

    var sampleSize = 1
    while (sourceEdgePx / (sampleSize * 2) >= targetEdgePx) {
        sampleSize *= 2
    }
    return sampleSize
}

val LocalBrandImageBitmapCache = staticCompositionLocalOf<BrandImageBitmapCache?> { null }


private object EmptyPainter : Painter() {
    override val intrinsicSize: Size = Size.Unspecified
    override fun DrawScope.onDraw() = Unit
}


internal fun canResolveResource(resources: Resources, @DrawableRes resId: Int): Boolean =
    runCatching { resources.getValue(resId, TypedValue(), true) }.isSuccess


@Composable
fun rememberBrandPainter(@DrawableRes resId: Int, targetSize: Dp): Painter {
    val resources = LocalContext.current.resources
    val resolvable = remember(resources, resId) { canResolveResource(resources, resId) }
    if (!resolvable) return EmptyPainter

    val cache = LocalBrandImageBitmapCache.current ?: return painterResource(resId)
    val density = LocalDensity.current
    val targetEdgePx = remember(targetSize, density) {
        with(density) { targetSize.roundToPx().coerceAtLeast(1) }
    }
    val bitmap = remember(cache, resId, targetEdgePx) {
        cache.getOrNull(resId, targetEdgePx)
    }
    if (bitmap == null) return painterResource(resId)
    return remember(bitmap) { BitmapPainter(bitmap) }
}


internal object BrandLogoResources {
    val commonBrandLogos: List<BrandPreloadSpec> = listOf(
        
        BrandPreloadSpec(R.drawable.ic_provider_openai, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_openai_dark, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_anthropic, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_anthropic_dark, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_gemini, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_gemini_dark, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_deepseek, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_deepseek_dark, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_grok, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_grok_dark, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_openrouter, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_openrouter_dark, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_groq, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_groq_dark, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_together, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_together_dark, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_fireworks, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_fireworks_dark, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_minimax, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_minimax_dark, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_zhipu, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_zhipu_dark, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_qwen, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_qwen_dark, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_kimi, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_kimi_dark, 64.dp),
        
        BrandPreloadSpec(R.drawable.ic_provider_mistral, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_siliconflow, 64.dp),
        BrandPreloadSpec(R.drawable.ic_provider_siliconflow_dark, 64.dp),
        
        BrandPreloadSpec(R.drawable.ic_oriveo_logo, 92.dp),
        BrandPreloadSpec(R.drawable.ic_guest_avatar, 72.dp),
        
        BrandPreloadSpec(R.drawable.ic_vendor_meta, 24.dp),
        BrandPreloadSpec(R.drawable.ic_vendor_mistral, 24.dp),
        BrandPreloadSpec(R.drawable.ic_vendor_perplexity, 24.dp),
        BrandPreloadSpec(R.drawable.ic_vendor_cohere, 24.dp),
        BrandPreloadSpec(R.drawable.ic_vendor_microsoft, 24.dp),
        BrandPreloadSpec(R.drawable.ic_vendor_nvidia, 24.dp),
        BrandPreloadSpec(R.drawable.ic_vendor_baidu, 24.dp),
    )
}
