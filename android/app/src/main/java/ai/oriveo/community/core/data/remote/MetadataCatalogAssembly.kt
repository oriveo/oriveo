package ai.oriveo.community.core.data.remote

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

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
        /**
         * Tombstone snapshot (contract section 9.8): the tombstones in effect when this catalog was adopted. Schema 3 takes the catalog's own (empty array by default),
         * for schema 2 the caller fills in the index's retiredModels for that provider at the time and persists them with the cache row (top-level data.retiredModels).
         * null = the old cache row has no snapshot. Assembly only uses it when the index is schema 3; a schema 2 index keeps using its own.
         */
        val retiredModels: JsonElement? = null,
    )

    /** Result of expanding a schema 3 compact catalog: [Expanded.data] is already the schema 2 equivalent (metadataSchema recorded as 2). */
    sealed interface CompactExpansion {
        data class Expanded(val data: JsonObject) : CompactExpansion
        /** [reason] is structural only (a field name) and carries no model content. */
        data class Rejected(val reason: String) : CompactExpansion
    }

    sealed interface Expansion {
        /** [droppedRefs]: models under schema 2 dropped during expansion because a ref did not resolve (invisible to the shared schema check); reported by the caller. */
        data class Accepted(
            val catalog: ExpandedCatalog,
            val droppedRefs: List<DroppedRef> = emptyList(),
        ) : Expansion
        /** Entry-level drop other than Rejected: [reason] is only the ref field name (e.g. `parametersRef`) and carries no model content. */
        data class DroppedRef(val modelId: String, val reason: String)
        /** [reason] is structural only (a field name or ref kind) and carries no model content, so it can go straight into diagnostics. */
        data class Rejected(val reason: String) : Expansion
    }

    /** (ref field, table name in tables, expanded field); the schema 2 validator's ref expansion also only honors this table. */
    internal val REF_FIELDS = listOf(
        Triple("capabilityControlsRef", "capabilityControls", "capabilityControls"),
        Triple("profilesRef", "profiles", "profiles"),
        Triple("capabilityEvidenceRef", "capabilityEvidence", "capabilityEvidenceView"),
    )

    /**
     * Schema 3 compact catalog to its schema 2 equivalent, in a fixed order (shared corpus schema3.expansion):
     * 1. keys missing on a model are filled from catalog.modelDefaults;
     * 2. billingSku defaults to the model key, explicit null removes the key (canonicalModelId is still filled from the tree id by lean decoding);
     * 3. when uiHints is an object, missing groupKey / groupName take the model's vendorKey / vendorName, explicit null removes the key;
     * 4. parameterSupportRef is put back into parameterSupport from tables.parameterSupport[ref]; a miss rejects the whole catalog.
     * Under schema 3 the other refs (the three *Ref fields and parametersRef inside profiles) are also checked here first: any miss rejects the whole catalog
     * (contract section 9.2); the schema 2 behavior of dropping only that model does not apply to 3.
     * The result drops modelDefaults and tables.parameterSupport and records metadataSchema as 2: the later shared schema check, the three *Ref expansions,
     * persistence and cold-start replay all follow schema 2, so expansion is never applied twice (an explicit-null key removal cannot be replayed).
     * retiredModels stays at the catalog top level and is carried into [ExpandedCatalog.retiredModels] by [expandCatalog].
     * Data that is not schema 3 is returned unchanged.
     */
    fun expandCompactCatalog(data: JsonObject): CompactExpansion {
        if ((data["metadataSchema"] as? JsonPrimitive)?.intOrNull != 3) return CompactExpansion.Expanded(data)
        val defaults = when (val raw = data["modelDefaults"]) {
            null, JsonNull -> JsonObject(emptyMap())
            is JsonObject -> raw
            else -> return CompactExpansion.Rejected("modelDefaults")
        }
        val tables = data["tables"] as? JsonObject
        val parameterSupport = when (val raw = tables?.get("parameterSupport")) {
            null, JsonNull -> JsonObject(emptyMap())
            is JsonObject -> raw
            else -> return CompactExpansion.Rejected("tables.parameterSupport")
        }
        val models = data["models"] as? JsonObject ?: return CompactExpansion.Rejected("models")
        val expanded = LinkedHashMap<String, JsonElement>(models.size)
        for ((modelId, rawModel) in models) {
            // Non-object entries go to the later schema check / expansion unchanged (same behavior as schema 2).
            val model = rawModel as? JsonObject ?: run { expanded[modelId] = rawModel; continue }
            val out = LinkedHashMap<String, JsonElement>(model)
            for ((key, value) in defaults) {
                if (!out.containsKey(key)) out[key] = value
            }
            when (out["billingSku"]) {
                null -> out["billingSku"] = JsonPrimitive(modelId)
                JsonNull -> out.remove("billingSku")
                else -> Unit
            }
            (out["uiHints"] as? JsonObject)?.let { hints ->
                val hintsOut = LinkedHashMap<String, JsonElement>(hints)
                for ((field, source) in UI_HINT_GROUP_SOURCES) {
                    when (hints[field]) {
                        null -> out[source]?.takeUnless { it is JsonNull }?.let { hintsOut[field] = it }
                        JsonNull -> hintsOut.remove(field)
                        else -> Unit
                    }
                }
                out["uiHints"] = JsonObject(hintsOut)
            }
            if (out.containsKey("parameterSupportRef")) {
                // null / empty string / non-string are all invalid refs and reject the whole catalog just like a miss.
                val ref = (out.remove("parameterSupportRef") as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?.takeIf { it.isNotEmpty() }
                out["parameterSupport"] = ref?.let { parameterSupport[it] }
                    ?: return CompactExpansion.Rejected("parameterSupportRef")
            }
            unresolvedSchema2Ref(out, tables)?.let { return CompactExpansion.Rejected(it) }
            expanded[modelId] = JsonObject(out)
        }
        val result = LinkedHashMap<String, JsonElement>(data.size)
        for ((field, value) in data) {
            when (field) {
                "modelDefaults" -> Unit
                "metadataSchema" -> result[field] = JsonPrimitive(2)
                "models" -> result[field] = JsonObject(expanded)
                "retiredModels" -> result[field] = value.takeUnless { it is JsonNull } ?: JsonArray(emptyList())
                "tables" -> result[field] = (value as? JsonObject)?.let { JsonObject(it - "parameterSupport") } ?: value
                else -> result[field] = value
            }
        }
        // Schema 3 tombstones live only in the catalog: a missing field is also recorded as an empty array, to tell it apart from "old cache row has no snapshot" (null).
        if (!result.containsKey("retiredModels")) result["retiredModels"] = JsonArray(emptyList())
        return CompactExpansion.Expanded(JsonObject(result))
    }

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
     * Removes model entries the schema 2 check judged bad, together with resolveMap aliases pointing at them.
     * resolveMap is pruned by target only (same as Web pruneResolveMap): an alias whose key merely equals a bad model's name but targets a good model is kept.
     * All other fields are kept as is; when [modelIds] is empty the data is returned unchanged.
     */
    fun withoutModels(data: JsonObject, modelIds: Set<String>): JsonObject {
        if (modelIds.isEmpty()) return data
        val out = LinkedHashMap<String, JsonElement>(data)
        (data["models"] as? JsonObject)?.let { models -> out["models"] = JsonObject(models - modelIds) }
        (data["resolveMap"] as? JsonObject)?.let { resolveMap ->
            out["resolveMap"] = JsonObject(
                resolveMap.filter { (_, target) ->
                    (target as? JsonPrimitive)?.takeIf { it.isString }?.content !in modelIds
                },
            )
        }
        return JsonObject(out)
    }

    /**
     * Validates and expands one catalog. Any unresolved ref rejects the **whole** catalog (contract section 9.2):
     * models are never dropped one by one, and there is no fallback to inline fields.
     * A schema 2 catalog first goes through the shared schema check by the caller, which lists bad entries in [droppedModelIds]:
     * those entries (and resolveMap aliases pointing at them) are dropped individually without taking the whole catalog down; under schema 2 a missing tables counts as empty,
     * a non-string / unresolvable *Ref or unresolvable parametersRef also drops only that model. Schema 1 still rejects the whole catalog per section 9.2.
     */
    fun expandCatalog(
        rawData: JsonObject,
        expectedProvider: String,
        droppedModelIds: Set<String> = emptySet(),
    ): Expansion {
        val schema2Data = when (val compact = expandCompactCatalog(rawData)) {
            is CompactExpansion.Rejected -> return Expansion.Rejected(compact.reason)
            is CompactExpansion.Expanded -> compact.data
        }
        val data = withoutModels(schema2Data, droppedModelIds)
        if ((data["view"] as? JsonPrimitive)?.contentOrNull != "catalog") return Expansion.Rejected("view")
        if ((data["provider"] as? JsonPrimitive)?.contentOrNull != expectedProvider) return Expansion.Rejected("provider")
        val revision = (data["catalogRevision"] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
            ?: return Expansion.Rejected("catalogRevision")
        val schemaV2 = (data["metadataSchema"] as? JsonPrimitive)?.intOrNull == 2
        val tables = data["tables"] as? JsonObject
            ?: if (schemaV2 && data["tables"] == null) JsonObject(emptyMap()) else return Expansion.Rejected("tables")
        val generationParameters = tableOrEmpty(tables, "generationParameters") ?: return Expansion.Rejected("tables.generationParameters")
        val tableByName = mutableMapOf<String, JsonObject>()
        for ((_, tableName, _) in REF_FIELDS) {
            tableByName[tableName] = tableOrEmpty(tables, tableName) ?: return Expansion.Rejected("tables.$tableName")
        }
        val models = data["models"] as? JsonObject ?: return Expansion.Rejected("models")

        val expanded = LinkedHashMap<String, JsonElement>(models.size)
        val locallyDropped = linkedSetOf<String>()
        val droppedRefs = mutableListOf<Expansion.DroppedRef>()
        modelLoop@ for ((modelId, rawModel) in models) {
            val model = rawModel as? JsonObject ?: return Expansion.Rejected("models.entry")
            val out = LinkedHashMap<String, JsonElement>(model.size)
            for ((key, value) in model) {
                if (REF_FIELDS.none { it.first == key }) out[key] = value
            }
            for ((refField, tableName, targetField) in REF_FIELDS) {
                if (!model.containsKey(refField)) continue
                val ref = (model[refField] as? JsonPrimitive)?.takeIf { it.isString }?.content
                val resolved = ref?.let { tableByName.getValue(tableName)[it] }
                val failure = when {
                    resolved == null -> refField
                    targetField == "profiles" && !generationParametersResolve(resolved, generationParameters) -> "parametersRef"
                    else -> null
                }
                if (failure != null) {
                    if (!schemaV2) return Expansion.Rejected(failure)
                    locallyDropped += modelId
                    droppedRefs += Expansion.DroppedRef(modelId, failure)
                    continue@modelLoop
                }
                out[targetField] = checkNotNull(resolved)
            }
            expanded[modelId] = JsonObject(out)
        }
        return Expansion.Accepted(
            ExpandedCatalog(
                provider = expectedProvider,
                catalogRevision = revision,
                resolveMap = if (locallyDropped.isEmpty()) data["resolveMap"]
                else withoutModels(data, locallyDropped)["resolveMap"],
                models = JsonObject(expanded),
                generationParameters = generationParameters,
                retiredModels = data["retiredModels"]?.takeUnless { it is JsonNull },
            ),
            droppedRefs = droppedRefs,
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
        // Tombstone source follows the index schema (section 9.8): a schema 3 index carries no tombstones, so use the snapshot in the catalog cache; otherwise use the index's.
        val compactIndex = (index["metadataSchema"] as? JsonPrimitive)?.intOrNull == 3
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
                if (compactIndex) {
                    fields.remove("retiredModels")
                    catalog.retiredModels?.let { fields["retiredModels"] = it }
                }
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

    /** First unresolved field name among the three *Ref fields on a schema 3 model (and profiles.generation.parametersRef); null when all resolve. */
    private fun unresolvedSchema2Ref(model: Map<String, JsonElement>, tables: JsonObject?): String? {
        val empty = JsonObject(emptyMap())
        val generationParameters = tables?.let { tableOrEmpty(it, "generationParameters") } ?: empty
        for ((refField, tableName, targetField) in REF_FIELDS) {
            if (!model.containsKey(refField)) continue
            val table = tables?.let { tableOrEmpty(it, tableName) } ?: empty
            val ref = (model[refField] as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it.isNotEmpty() }
            val resolved = ref?.let { table[it] } ?: return refField
            if (targetField != "profiles") continue
            val generation = (resolved as? JsonObject)?.get("generation") as? JsonObject ?: continue
            if (!generation.containsKey("parametersRef")) continue
            val parametersRef = (generation["parametersRef"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                ?.takeIf { it.isNotEmpty() }
            if (parametersRef == null || !generationParameters.containsKey(parametersRef)) return "parametersRef"
        }
        return null
    }

    /** uiHints group field -> model field it takes its default from when missing. */
    private val UI_HINT_GROUP_SOURCES = listOf("groupKey" to "vendorKey", "groupName" to "vendorName")

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
