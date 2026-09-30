package ai.oriveo.community.core.data.remote

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Pure JSON boundary for the index + per-provider catalog views: validates refs, expands models
 * back to their lean shape, and reassembles a lean-shaped `data` object. The result goes through
 * the existing lean decode (parametersRef dereferencing, identity filled in from tree position,
 * evidence normalization), so downstream consumers never need to know the catalog arrived per
 * provider.
 */
internal object MetadataCatalogAssembly {

    /** A catalog whose refs all resolved; only this shape may enter memory or the cache. */
    data class ExpandedCatalog(
        val provider: String,
        val catalogRevision: String,
        val resolveMap: JsonElement?,
        /** Models with the three *Ref fields replaced by capabilityControls / profiles / capabilityEvidenceView. */
        val models: JsonObject,
        val generationParameters: JsonObject,
    )

    sealed interface Expansion {
        data class Accepted(val catalog: ExpandedCatalog) : Expansion
        /** [reason] is structural only (a field name or ref kind) and carries no model content. */
        data class Rejected(val reason: String) : Expansion
    }

    private val REF_FIELDS = listOf(
        Triple("capabilityControlsRef", "capabilityControls", "capabilityControls"),
        Triple("profilesRef", "profiles", "profiles"),
        Triple("capabilityEvidenceRef", "capabilityEvidence", "capabilityEvidenceView"),
    )

    /** Accepts both a bare body and the `{code,data,message}` envelope; returns the data object. */
    fun unwrapData(root: JsonElement): JsonObject? {
        val obj = root as? JsonObject ?: return null
        return (obj["data"] as? JsonObject) ?: obj
    }

    fun indexCatalogRevisions(index: JsonObject): Map<String, String> =
        (index["providers"] as? JsonObject).orEmpty().mapNotNull { (key, raw) ->
            val revision = ((raw as? JsonObject)?.get("catalogRevision") as? JsonPrimitive)?.contentOrNull
                ?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            key to revision
        }.toMap()

    /** The relay official-provider whitelist from the index; null when absent or empty, so the caller uses its fallback. */
    fun relayWhitelist(index: JsonObject): List<String>? =
        ((index["relayRuntimeConfig"] as? JsonObject)?.get("officialProviderWhitelist") as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            ?.takeIf { it.isNotEmpty() }

    /**
     * Validates and expands one catalog. Any unresolved ref rejects the **whole** catalog: models
     * are never dropped one by one, and there is no fallback to inline fields.
     */
    fun expandCatalog(data: JsonObject, expectedProvider: String): Expansion {
        if ((data["view"] as? JsonPrimitive)?.contentOrNull != "catalog") return Expansion.Rejected("view")
        if ((data["provider"] as? JsonPrimitive)?.contentOrNull != expectedProvider) return Expansion.Rejected("provider")
        val revision = (data["catalogRevision"] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
            ?: return Expansion.Rejected("catalogRevision")
        val tables = data["tables"] as? JsonObject ?: return Expansion.Rejected("tables")
        val generationParameters = tableOrEmpty(tables, "generationParameters") ?: return Expansion.Rejected("tables.generationParameters")
        val tableByName = mutableMapOf<String, JsonObject>()
        for ((_, tableName, _) in REF_FIELDS) {
            tableByName[tableName] = tableOrEmpty(tables, tableName) ?: return Expansion.Rejected("tables.$tableName")
        }
        val models = data["models"] as? JsonObject ?: return Expansion.Rejected("models")

        val expanded = LinkedHashMap<String, JsonElement>(models.size)
        for ((modelId, rawModel) in models) {
            val model = rawModel as? JsonObject ?: return Expansion.Rejected("models.entry")
            val out = LinkedHashMap<String, JsonElement>(model.size)
            for ((key, value) in model) {
                if (REF_FIELDS.none { it.first == key }) out[key] = value
            }
            for ((refField, tableName, targetField) in REF_FIELDS) {
                if (!model.containsKey(refField)) continue
                val ref = (model[refField] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: return Expansion.Rejected(refField)
                val resolved = tableByName.getValue(tableName)[ref] ?: return Expansion.Rejected(refField)
                if (targetField == "profiles" && !generationParametersResolve(resolved, generationParameters)) {
                    return Expansion.Rejected("parametersRef")
                }
                out[targetField] = resolved
            }
            expanded[modelId] = JsonObject(out)
        }
        return Expansion.Accepted(
            ExpandedCatalog(
                provider = expectedProvider,
                catalogRevision = revision,
                resolveMap = data["resolveMap"],
                models = JsonObject(expanded),
                generationParameters = generationParameters,
            ),
        )
    }

    /**
     * Builds lean-shaped data: top-level index fields are kept as is and `view` becomes lean.
     * Each provider is its index entry minus modelCount / catalogRevision, plus resolveMap and
     * models when its catalog is loaded; every catalog's generationParameters are merged into
     * generationParameterTables. A provider whose catalog is not loaded keeps only its
     * provider-level fields, which adding a provider or validating a key needs before any catalog.
     */
    fun assembleLeanData(index: JsonObject, catalogs: Map<String, ExpandedCatalog>): JsonObject {
        val indexProviders = index["providers"] as? JsonObject ?: JsonObject(emptyMap())
        val providers = LinkedHashMap<String, JsonElement>(indexProviders.size)
        val parameterTables = LinkedHashMap<String, JsonElement>()
        for ((key, rawProvider) in indexProviders) {
            val provider = rawProvider as? JsonObject ?: continue
            val fields = LinkedHashMap<String, JsonElement>(provider.size + 2)
            for ((field, value) in provider) {
                if (field != "modelCount" && field != "catalogRevision") fields[field] = value
            }
            catalogs[key]?.let { catalog ->
                catalog.resolveMap?.takeUnless { it is JsonNull }?.let { fields["resolveMap"] = it }
                fields["models"] = catalog.models
                parameterTables.putAll(catalog.generationParameters)
            }
            providers[key] = JsonObject(fields)
        }
        val out = LinkedHashMap<String, JsonElement>(index.size + 1)
        for ((field, value) in index) {
            if (field != "providers" && field != "view") out[field] = value
        }
        out["view"] = JsonPrimitive("lean")
        out["generationParameterTables"] = JsonObject(parameterTables)
        out["providers"] = JsonObject(providers)
        return JsonObject(out)
    }

    /** A missing table counts as empty; a present non-object table is a structural error (null). */
    private fun tableOrEmpty(tables: JsonObject, name: String): JsonObject? {
        val raw = tables[name] ?: return JsonObject(emptyMap())
        if (raw is JsonNull) return JsonObject(emptyMap())
        return raw as? JsonObject
    }

    /** An expanded profiles.generation.parametersRef must resolve in this catalog's generationParameters. */
    private fun generationParametersResolve(profiles: JsonElement, generationParameters: JsonObject): Boolean {
        val generation = (profiles as? JsonObject)?.get("generation") as? JsonObject ?: return true
        if (!generation.containsKey("parametersRef")) return true
        val ref = (generation["parametersRef"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return false
        return generationParameters.containsKey(ref)
    }
}
