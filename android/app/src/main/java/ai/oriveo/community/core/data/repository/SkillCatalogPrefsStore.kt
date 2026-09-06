package ai.oriveo.community.core.data.repository

import android.content.Context
import android.content.SharedPreferences
import ai.oriveo.community.core.model.SkillCategory
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

class SkillCatalogPrefsStore(
    private val context: Context,
) {
    private companion object {
        private const val PREFS_NAME = "skills_catalog"
        private const val KEY_VERSION = "catalog_version"
        private const val KEY_CATEGORIES = "catalog_categories"
        private const val VERSION_UNSET = -1
    }

    private val prefs: SharedPreferences by lazy(LazyThreadSafetyMode.PUBLICATION) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    data class Snapshot(
        val version: Int?,
        val categories: List<SkillCategory>,
    )

    fun load(): Snapshot {
        val version = prefs.getInt(KEY_VERSION, VERSION_UNSET).takeIf { it != VERSION_UNSET }
        val categoriesText = prefs.getString(KEY_CATEGORIES, null)
        val categories = runCatching {
            if (categoriesText.isNullOrBlank()) {
                emptyList()
            } else {
                json.decodeFromString(ListSerializer(SkillCategory.serializer()), categoriesText)
            }
        }.getOrDefault(emptyList())

        return Snapshot(version = version, categories = categories)
    }

    fun save(version: Int, categories: List<SkillCategory>) {
        prefs.edit()
            .putInt(KEY_VERSION, version)
            .putString(KEY_CATEGORIES, json.encodeToString(ListSerializer(SkillCategory.serializer()), categories))
            .apply()
    }
}
