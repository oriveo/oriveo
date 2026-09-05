package ai.oriveo.community.testing

import android.content.SharedPreferences


class TestSharedPreferences : SharedPreferences {
    private val values = linkedMapOf<String, Any?>()

    @Synchronized
    override fun getAll(): MutableMap<String, *> = values.toMutableMap()

    @Synchronized
    override fun getString(key: String?, defValue: String?): String? =
        values[key] as? String ?: defValue

    @Suppress("UNCHECKED_CAST")
    @Synchronized
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
        (values[key] as? Set<String>)?.toMutableSet() ?: defValues

    @Synchronized
    override fun getInt(key: String?, defValue: Int): Int =
        values[key] as? Int ?: defValue

    @Synchronized
    override fun getLong(key: String?, defValue: Long): Long =
        values[key] as? Long ?: defValue

    @Synchronized
    override fun getFloat(key: String?, defValue: Float): Float =
        values[key] as? Float ?: defValue

    @Synchronized
    override fun getBoolean(key: String?, defValue: Boolean): Boolean =
        values[key] as? Boolean ?: defValue

    @Synchronized
    override fun contains(key: String?): Boolean = values.containsKey(key)

    override fun edit(): SharedPreferences.Editor = Editor()

    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    
    @Synchronized
    private fun commitUpdates(updates: Map<String, Any?>, clearRequested: Boolean) {
        if (clearRequested) values.clear()
        updates.forEach { (key, value) ->
            if (value == null) values.remove(key) else values[key] = value
        }
    }

    private inner class Editor : SharedPreferences.Editor {
        private val updates = linkedMapOf<String, Any?>()
        private var clearRequested = false

        override fun putString(key: String?, value: String?): SharedPreferences.Editor = apply {
            updates[key.orEmpty()] = value
        }

        override fun putStringSet(key: String?, values: MutableSet<String>?): SharedPreferences.Editor = apply {
            updates[key.orEmpty()] = values?.toSet()
        }

        override fun putInt(key: String?, value: Int): SharedPreferences.Editor = apply {
            updates[key.orEmpty()] = value
        }

        override fun putLong(key: String?, value: Long): SharedPreferences.Editor = apply {
            updates[key.orEmpty()] = value
        }

        override fun putFloat(key: String?, value: Float): SharedPreferences.Editor = apply {
            updates[key.orEmpty()] = value
        }

        override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor = apply {
            updates[key.orEmpty()] = value
        }

        override fun remove(key: String?): SharedPreferences.Editor = apply {
            updates[key.orEmpty()] = null
        }

        override fun clear(): SharedPreferences.Editor = apply {
            clearRequested = true
        }

        override fun commit(): Boolean {
            apply()
            return true
        }

        override fun apply() {
            commitUpdates(updates, clearRequested)
            updates.clear()
            clearRequested = false
        }
    }
}
