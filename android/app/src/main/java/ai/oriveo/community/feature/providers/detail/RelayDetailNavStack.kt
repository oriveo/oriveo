package ai.oriveo.community.feature.providers.detail

import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.listSaver

/** Sub-page layers of the relay detail page: model library, keys page, model advanced ([readOnly] = entered from a catalog row, zero requests). */
sealed interface RelayDetailLayer {
    /** [keyFilter] = opened filtered by key(id) (the keys page's "view this key's models"); null = no filter. */
    data class Library(val keyFilter: String? = null) : RelayDetailLayer
    data object Keys : RelayDetailLayer
    /** Detail > web-search settings page. */
    data object WebSearch : RelayDetailLayer
    data class Advanced(val modelId: String, val readOnly: Boolean) : RelayDetailLayer
}

/**
 * Layer stack for detail -> model library -> advanced and detail -> keys: back pops one layer at a time, and rotation / process recreation restores it unchanged via [Saver].
 * It does not use NavHost routes: all layers must share the same detail ViewModel. An empty stack = the detail page itself.
 */
data class RelayDetailNavStack(val layers: List<RelayDetailLayer> = emptyList()) {
    val top: RelayDetailLayer? get() = layers.lastOrNull()
    val isEmpty: Boolean get() = layers.isEmpty()

    /** The advanced page is drawn above the model library; when the advanced page's model cannot be found, the host falls back to drawing the model library. */
    val showsLibrary: Boolean get() = top is RelayDetailLayer.Library || top is RelayDetailLayer.Advanced
    val showsKeys: Boolean get() = top == RelayDetailLayer.Keys
    val showsWebSearch: Boolean get() = top == RelayDetailLayer.WebSearch
    val advanced: RelayDetailLayer.Advanced? get() = top as? RelayDetailLayer.Advanced

    fun push(layer: RelayDetailLayer): RelayDetailNavStack = copy(layers = layers + layer)
    fun pop(): RelayDetailNavStack = copy(layers = layers.dropLast(1))

    companion object {
        private const val LIBRARY = "library"
        private const val KEYS = "keys"
        private const val WEB_SEARCH = "web_search"
        private const val ADVANCED = "advanced"

        /**
         * One string per layer; the advanced layer is `advanced|<0/1>|<modelId>` with the model id last, so ids containing `|` can still be restored;
         * a model library with a key filter is `library|<keyId>`.
         */
        fun encode(stack: RelayDetailNavStack): List<String> = stack.layers.map { layer ->
            when (layer) {
                is RelayDetailLayer.Library -> layer.keyFilter?.let { "$LIBRARY|$it" } ?: LIBRARY
                RelayDetailLayer.Keys -> KEYS
                RelayDetailLayer.WebSearch -> WEB_SEARCH
                is RelayDetailLayer.Advanced -> "$ADVANCED|${if (layer.readOnly) 1 else 0}|${layer.modelId}"
            }
        }

        fun decode(encoded: List<String>): RelayDetailNavStack = RelayDetailNavStack(
            encoded.mapNotNull { item ->
                when {
                    item == LIBRARY -> RelayDetailLayer.Library()
                    item.startsWith("$LIBRARY|") -> RelayDetailLayer.Library(keyFilter = item.removePrefix("$LIBRARY|"))
                    item == KEYS -> RelayDetailLayer.Keys
                    item == WEB_SEARCH -> RelayDetailLayer.WebSearch
                    item.startsWith("$ADVANCED|") -> {
                        val parts = item.split("|", limit = 3)
                        parts.getOrNull(2)?.let { RelayDetailLayer.Advanced(modelId = it, readOnly = parts[1] == "1") }
                    }
                    else -> null
                }
            },
        )

        val Saver: Saver<RelayDetailNavStack, Any> = listSaver(
            save = { encode(it) },
            restore = { decode(it) },
        )
    }
}
