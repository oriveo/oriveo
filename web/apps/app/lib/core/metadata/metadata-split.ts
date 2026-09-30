/**
 * Pure functions for the metadata index plus per-provider catalogs.
 *
 * Shared by the browser metadata-client and the Next server route (app/api/chat/stream/runtime.ts):
 * both reassemble the index and some catalogs in memory into an object shaped like the lean
 * snapshot, so everything downstream keeps using the existing lean decoding (parametersRef
 * dereferencing, tree-position identity, evidence normalization) and consumers never see the split.
 *
 * Only structural validation and ref expansion happen here; no networking or persistence.
 */

/** The three model structures a catalog interns into table references; one-to-one with the server's catalogInternedFields. */
const CATALOG_INTERNED_FIELDS = [
  { ref: "capabilityControlsRef", table: "capabilityControls", field: "capabilityControls" },
  { ref: "profilesRef", table: "profiles", field: "profiles" },
  { ref: "capabilityEvidenceRef", table: "capabilityEvidence", field: "capabilityEvidenceView" },
] as const;

/** Fields that exist only on an index provider and must be dropped when reassembling lean. */
const INDEX_ONLY_PROVIDER_FIELDS = new Set(["modelCount", "catalogRevision"]);

export type GenerationParameterTable = Record<string, unknown[]>;

/** One expanded, validated catalog: the provider's resolveMap/models plus this catalog's parameter tables. */
export interface ExpandedMetadataCatalog {
  provider: string;
  revision: string;
  resolveMap?: Record<string, string>;
  models: Record<string, Record<string, unknown>>;
  generationParameters: GenerationParameterTable;
}

export type CatalogRejectionReason =
  | "malformed"
  | "provider_mismatch"
  | "revision_mismatch"
  | "unresolved_ref";

export type CatalogExpansionResult =
  | { ok: true; catalog: ExpandedMetadataCatalog }
  | { ok: false; reason: CatalogRejectionReason };

export interface MetadataIndexProvider extends Record<string, unknown> {
  catalogRevision?: string;
  modelCount?: number;
}

export interface MetadataIndexPayload extends Record<string, unknown> {
  view: "index";
  providers: Record<string, MetadataIndexProvider>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

/** Whether the response data is the index view (a server that ignores the view parameter returns the full snapshot, which is not an index). */
export function isMetadataIndexPayload(data: unknown): data is MetadataIndexPayload {
  return isRecord(data) && data.view === "index" && isRecord(data.providers);
}

/** The catalogRevision the index lists for a provider; missing or non-string counts as not listed. */
export function indexCatalogRevision(
  index: MetadataIndexPayload,
  providerKind: string,
): string | undefined {
  const revision = index.providers[providerKind]?.catalogRevision;
  return typeof revision === "string" && revision.length > 0 ? revision : undefined;
}

/** Index provider fields minus modelCount / catalogRevision: the lean provider without models/resolveMap. */
export function indexProviderFields(provider: MetadataIndexProvider): Record<string, unknown> {
  const fields: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(provider)) {
    if (!INDEX_ONLY_PROVIDER_FIELDS.has(key)) fields[key] = value;
  }
  return fields;
}

/**
 * Validates and expands one catalog.
 *
 * Any unresolved ref rejects the whole catalog (models are never dropped one by one and there is no
 * fallback to inline fields). A revision that differs from the one the index lists is rejected too;
 * the caller decides whether to refetch the index or keep the last-good copy.
 * Omitting `expected.revision` means the caller has no index to compare against (only structure and
 * refs are checked).
 */
export function expandMetadataCatalog(
  raw: unknown,
  expected: { provider: string; revision?: string },
): CatalogExpansionResult {
  if (
    !isRecord(raw)
    || raw.view !== "catalog"
    || typeof raw.catalogRevision !== "string"
    || raw.catalogRevision.length === 0
    || !isRecord(raw.tables)
    || !isRecord(raw.models)
    || (raw.resolveMap !== undefined && !isRecord(raw.resolveMap))
  ) {
    return { ok: false, reason: "malformed" };
  }
  if (raw.provider !== expected.provider) {
    return { ok: false, reason: "provider_mismatch" };
  }
  if (expected.revision !== undefined && raw.catalogRevision !== expected.revision) {
    return { ok: false, reason: "revision_mismatch" };
  }

  const tables = raw.tables;
  const generationParameters = tables.generationParameters ?? {};
  if (!isRecord(generationParameters)) return { ok: false, reason: "malformed" };
  for (const interned of CATALOG_INTERNED_FIELDS) {
    const table = tables[interned.table];
    if (table !== undefined && !isRecord(table)) return { ok: false, reason: "malformed" };
  }

  const models: Record<string, Record<string, unknown>> = {};
  for (const [modelId, rawModel] of Object.entries(raw.models)) {
    if (!isRecord(rawModel)) return { ok: false, reason: "malformed" };
    const model: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(rawModel)) {
      if (!CATALOG_INTERNED_FIELDS.some((interned) => interned.ref === key)) {
        model[key] = value;
      }
    }
    for (const interned of CATALOG_INTERNED_FIELDS) {
      if (!(interned.ref in rawModel)) continue;
      const ref = rawModel[interned.ref];
      const table = tables[interned.table] as Record<string, unknown> | undefined;
      if (typeof ref !== "string" || !table || !Object.prototype.hasOwnProperty.call(table, ref)) {
        return { ok: false, reason: "unresolved_ref" };
      }
      model[interned.field] = table[ref];
    }
    // The expanded generation.parametersRef must also resolve in this catalog's parameter tables,
    // the same rule the lean view applies.
    const profiles = model.profiles;
    if (isRecord(profiles) && isRecord(profiles.generation) && "parametersRef" in profiles.generation) {
      const parametersRef = profiles.generation.parametersRef;
      if (
        typeof parametersRef !== "string"
        || !Array.isArray((generationParameters as GenerationParameterTable)[parametersRef])
      ) {
        return { ok: false, reason: "unresolved_ref" };
      }
    }
    models[modelId] = model;
  }

  return {
    ok: true,
    catalog: {
      provider: expected.provider,
      revision: raw.catalogRevision,
      ...(raw.resolveMap ? { resolveMap: raw.resolveMap as Record<string, string> } : {}),
      models,
      generationParameters: generationParameters as GenerationParameterTable,
    },
  };
}

/**
 * Reassembles the index and the loaded catalogs into a lean-shaped object.
 *
 * - Only providers with a loaded catalog appear in `providers` (with resolveMap + models). With
 *   `includeIndexOnlyProviders`, providers without a catalog also appear, with their index fields
 *   and empty models (used by the server route, which only cares about the provider of the current
 *   request but still needs fields such as validation for the others).
 * - Each catalog's parameter tables merge into the top-level generationParameterTables (keys are
 *   content hashes, so the same key always means the same content).
 * - The result is marked `view: "lean"` and handed to the existing lean decoding.
 */
export function assembleLeanFromSplit(
  index: MetadataIndexPayload,
  catalogs: ReadonlyMap<string, {
    resolveMap?: Record<string, string>;
    models: Record<string, object>;
    generationParameters: Record<string, unknown>;
  }>,
  options: { includeIndexOnlyProviders?: boolean } = {},
): Record<string, unknown> & {
  view: "lean";
  providers: Record<string, Record<string, unknown>>;
  generationParameterTables: GenerationParameterTable;
} {
  const providers: Record<string, Record<string, unknown>> = {};
  const generationParameterTables: GenerationParameterTable = {};
  for (const [providerKind, indexProvider] of Object.entries(index.providers)) {
    if (!isRecord(indexProvider)) continue;
    const catalog = catalogs.get(providerKind);
    if (!catalog) {
      if (options.includeIndexOnlyProviders) {
        providers[providerKind] = { ...indexProviderFields(indexProvider), models: {} };
      }
      continue;
    }
    providers[providerKind] = {
      ...indexProviderFields(indexProvider),
      ...(catalog.resolveMap ? { resolveMap: catalog.resolveMap } : {}),
      models: catalog.models,
    };
    Object.assign(generationParameterTables, catalog.generationParameters);
  }
  return {
    ...index,
    view: "lean",
    providers,
    generationParameterTables,
  };
}
