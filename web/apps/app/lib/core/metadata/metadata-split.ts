/**
 * Pure functions for the metadata index plus per-provider catalogs.
 *
 * Shared by the browser metadata-client and the Next server route (app/api/chat/stream/runtime.ts):
 * both reassemble the index and some catalogs in memory into an object shaped like the lean
 * snapshot, so everything downstream keeps using the existing lean decoding (parametersRef dereferencing,
 * tree-position identity, evidence normalization) and consumers never see the split.
 *
 * Only structural validation and ref expansion happen here; no networking or persistence.
 */

import { isMetadataSchema2, isMetadataSchema3, metadataSchemaOf, validateMetadataModel, type DroppedMetadataEntry } from "./metadata-payload-v2";
import {
  catalog as validateCatalogEnvelope,
} from "./metadata-payload-validators.generated.js";

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
  /**
   * Tombstone snapshot: a schema 3 catalog takes its own retiredModels (default []); schema 1 / 2 catalogs do not carry it,
   * so the caller fills it from that provider's tombstones in the index at adoption time. When assembling, it is only used if the index is schema 3.
   */
  retiredModels?: unknown[];
  /** metadataSchema of the catalog body (1 / 2 / 3); a revision is only compared with a cache of the same schema. */
  metadataSchema: number;
  /** Models dropped by the per-entry schema 2 validation (callers report model_entry_invalid from it); always empty for schema 1. */
  dropped: DroppedMetadataEntry[];
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

/**
 * The tombstone snapshot to record when a provider catalog is adopted: a schema 3 catalog uses its own,
 * otherwise the provider's retiredModels in the index at adoption time (default []).
 */
export function retiredSnapshotForCatalog(
  catalog: { metadataSchema: number; retiredModels?: unknown[] },
  index: MetadataIndexPayload | null | undefined,
  providerKind: string,
): unknown[] {
  if (catalog.metadataSchema === 3) return catalog.retiredModels ?? [];
  return indexRetiredModels(index, providerKind) ?? [];
}

/** The provider's retiredModels in the index; undefined when the index is missing or the provider carries none. */
export function indexRetiredModels(
  index: MetadataIndexPayload | null | undefined,
  providerKind: string,
): unknown[] | undefined {
  const retired = index?.providers[providerKind]?.retiredModels;
  return Array.isArray(retired) ? retired : undefined;
}

/** Index provider fields minus modelCount / catalogRevision: the lean provider without models/resolveMap. */
export function indexProviderFields(provider: MetadataIndexProvider): Record<string, unknown> {
  const fields: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(provider)) {
    if (!INDEX_ONLY_PROVIDER_FIELDS.has(key)) fields[key] = value;
  }
  return fields;
}

/** Also remove aliases in resolveMap that point at dropped models, so lookups never resolve to missing entries. */
function pruneResolveMap(
  resolveMap: Record<string, unknown>,
  kept: Record<string, unknown>,
): Record<string, unknown> {
  const pruned: Record<string, unknown> = {};
  for (const [alias, target] of Object.entries(resolveMap)) {
    if (typeof target !== "string" || Object.prototype.hasOwnProperty.call(kept, target)) {
      pruned[alias] = target;
    }
  }
  return pruned;
}

/** A valid ref is a non-empty string (null / empty string are invalid refs). */
function isValidRef(ref: unknown): ref is string {
  return typeof ref === "string" && ref.length > 0;
}

/** Keys in uiHints defaulted from vendor fields: missing takes the vendor value, explicit null deletes, anything else is kept. */
const UI_HINT_VENDOR_DEFAULTS = [
  { hint: "groupKey", vendor: "vendorKey" },
  { hint: "groupName", vendor: "vendorName" },
] as const;

/**
 * Expands a schema 3 compact model back to the schema 2 shape (the contract order is fixed):
 * 1. modelDefaults fills keys the model lacks; 2. billingSku defaults to the tree id, explicit null deletes;
 * 3. uiHints.groupKey / groupName default to vendorKey / vendorName, explicit null deletes;
 * 4. parameterSupportRef -> tables.parameterSupport[ref] goes back into parameterSupport.
 * The canonicalModelId rule is the same as schema 2 (default = tree id) and is not filled in here.
 * A ref that is missing, null or an empty string (invalid ref) returns null and the caller rejects the whole payload.
 */
export function expandCompactCatalogModel(
  key: string,
  compact: Record<string, unknown>,
  modelDefaults: Record<string, unknown> | undefined,
  tables: Record<string, unknown>,
): Record<string, unknown> | null {
  const model: Record<string, unknown> = { ...compact };
  for (const [field, value] of Object.entries(modelDefaults ?? {})) {
    if (!Object.prototype.hasOwnProperty.call(model, field)) model[field] = value;
  }
  if (!Object.prototype.hasOwnProperty.call(model, "billingSku")) model.billingSku = key;
  else if (model.billingSku === null) delete model.billingSku;
  if (isRecord(model.uiHints)) {
    const uiHints: Record<string, unknown> = { ...model.uiHints };
    for (const { hint, vendor } of UI_HINT_VENDOR_DEFAULTS) {
      if (!Object.prototype.hasOwnProperty.call(uiHints, hint)) {
        // A null vendor counts as no vendor; no group is filled in.
        if (model[vendor] != null) uiHints[hint] = model[vendor];
      } else if (uiHints[hint] === null) {
        delete uiHints[hint];
      }
    }
    model.uiHints = uiHints;
  }
  if (Object.prototype.hasOwnProperty.call(model, "parameterSupportRef")) {
    const ref = model.parameterSupportRef;
    const table = tables.parameterSupport;
    if (!isValidRef(ref) || !isRecord(table) || !Object.prototype.hasOwnProperty.call(table, ref)) return null;
    delete model.parameterSupportRef;
    model.parameterSupport = table[ref];
  }
  return model;
}

type ModelExpansion =
  | { ok: true; model: Record<string, unknown> }
  | { ok: false; instancePath: string };

/** Expands the table references of one model into inline fields; on a missed reference returns the failing field path. */
function expandCatalogModel(
  rawModel: Record<string, unknown>,
  tables: Record<string, unknown>,
  generationParameters: GenerationParameterTable,
): ModelExpansion {
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
    if (!isValidRef(ref) || !table || !Object.prototype.hasOwnProperty.call(table, ref)) {
      return { ok: false, instancePath: `/${interned.ref}` };
    }
    model[interned.field] = table[ref];
  }
  // The expanded generation.parametersRef must also hit this catalog's parameter tables (the same rule carried over to catalogs).
  const profiles = model.profiles;
  if (isRecord(profiles) && isRecord(profiles.generation) && "parametersRef" in profiles.generation) {
    const parametersRef = profiles.generation.parametersRef;
    if (!isValidRef(parametersRef) || !Array.isArray(generationParameters[parametersRef])) {
      return { ok: false, instancePath: "/profiles/generation/parametersRef" };
    }
  }
  return { ok: true, model };
}

/**
 * Validates and expands one catalog.
 *
 * schema 1: any missed ref rejects the whole catalog (no per-model dropping, no fallback to inline fields).
 * schema 2: a bad envelope rejects the whole payload; refs are expanded first, then each model is validated; a model whose refs cannot be resolved or that is invalid after expansion is only dropped and recorded
 * (callers report model_entry_invalid from it).
 * schema 3: first expand the compact models back to the schema 2 shape per the contract, then run the schema 2 expansion and per-model validation;
 * but any missed ref (including parameterSupportRef) rejects the whole catalog, and the tombstone retiredModels is carried out with the catalog.
 * A revision that differs from the index registration is not adopted either; callers decide to refetch the index or keep last-good.
 * A missing `expectedRevision` means the caller has no index to compare against (only structure and ref validation).
 */
export function expandMetadataCatalog(
  input: unknown,
  expected: { provider: string; revision?: string },
): CatalogExpansionResult {
  const schema2 = isMetadataSchema2(input);
  const schema3 = isMetadataSchema3(input);
  if (schema2) {
    // Models are emptied for the envelope validation: they are validated one by one after expansion.
    const envelope = isRecord(input.models) ? { ...input, models: {} } : input;
    if (!validateCatalogEnvelope(envelope)) return { ok: false, reason: "malformed" };
  }
  const raw = input;
  if (
    !isRecord(raw)
    || raw.view !== "catalog"
    || typeof raw.catalogRevision !== "string"
    || raw.catalogRevision.length === 0
    // schema 2 may omit tables (the contract schema does not require them); schema 1 must carry them.
    || !(isRecord(raw.tables) || (schema2 && raw.tables === undefined))
    || !isRecord(raw.models)
    || (raw.resolveMap !== undefined && !isRecord(raw.resolveMap))
    || (schema3 && raw.modelDefaults !== undefined && !isRecord(raw.modelDefaults))
    || (schema3 && raw.retiredModels !== undefined && !Array.isArray(raw.retiredModels))
  ) {
    return { ok: false, reason: "malformed" };
  }
  if (raw.provider !== expected.provider) {
    return { ok: false, reason: "provider_mismatch" };
  }
  if (expected.revision !== undefined && raw.catalogRevision !== expected.revision) {
    return { ok: false, reason: "revision_mismatch" };
  }

  const tables = (raw.tables ?? {}) as Record<string, unknown>;
  const generationParameters = tables.generationParameters ?? {};
  if (!isRecord(generationParameters)) return { ok: false, reason: "malformed" };
  for (const interned of CATALOG_INTERNED_FIELDS) {
    const table = tables[interned.table];
    if (table !== undefined && !isRecord(table)) return { ok: false, reason: "malformed" };
  }

  const dropped: DroppedMetadataEntry[] = [];
  const models: Record<string, Record<string, unknown>> = {};
  for (const [modelId, rawModel] of Object.entries(raw.models)) {
    if (!isRecord(rawModel)) {
      if (!schema2) return { ok: false, reason: "malformed" };
      dropped.push({ provider: expected.provider, modelId, instancePath: "", keyword: "type" });
      continue;
    }
    let sourceModel = rawModel;
    if (schema3) {
      const expandedCompact = expandCompactCatalogModel(
        modelId,
        rawModel,
        raw.modelDefaults as Record<string, unknown> | undefined,
        tables,
      );
      if (!expandedCompact) return { ok: false, reason: "unresolved_ref" };
      sourceModel = expandedCompact;
    }
    const expansion = expandCatalogModel(sourceModel, tables, generationParameters as GenerationParameterTable);
    if (!expansion.ok) {
      if (!schema2 || schema3) return { ok: false, reason: "unresolved_ref" };
      dropped.push({
        provider: expected.provider,
        modelId,
        instancePath: expansion.instancePath,
        keyword: "unresolved_ref",
      });
      continue;
    }
    if (schema2) {
      const verdict = validateMetadataModel(expansion.model);
      if (!verdict.ok) {
        dropped.push({ provider: expected.provider, modelId, instancePath: verdict.instancePath, keyword: verdict.keyword });
        continue;
      }
      if (verdict.droppedKey) dropped.push({ provider: expected.provider, modelId, ...verdict.droppedKey });
      models[modelId] = verdict.model as Record<string, unknown>;
      continue;
    }
    models[modelId] = expansion.model;
  }

  const resolveMap = raw.resolveMap as Record<string, string> | undefined;
  return {
    ok: true,
    catalog: {
      provider: expected.provider,
      revision: raw.catalogRevision,
      ...(resolveMap
        ? { resolveMap: (dropped.length > 0 ? pruneResolveMap(resolveMap, models) : resolveMap) as Record<string, string> }
        : {}),
      models,
      generationParameters: generationParameters as GenerationParameterTable,
      ...(schema3 ? { retiredModels: Array.isArray(raw.retiredModels) ? raw.retiredModels : [] } : {}),
      metadataSchema: metadataSchemaOf(raw),
      dropped,
    },
  };
}

/**
 * Reassembles the index and the loaded catalogs into a lean-shaped object.
 *
 * - Only providers with a loaded catalog enter `providers` (with resolveMap + models);
 *   when `includeIndexOnlyProviders` is true, unloaded providers also appear with index fields + empty models
 *   (used by the server route: it only cares about the provider of the current request, but other providers' validation and similar fields must stay readable).
 * - Tombstones: index is schema 3 -> use the tombstone snapshot in that provider's catalog cache (the index no longer carries it);
 *   index is schema 1 / 2 -> only use that provider's retiredModels in the index and ignore the catalog snapshot.
 * - Parameter tables of every catalog are merged into the top-level generationParameterTables (the key is a content hash; same key, same content).
 * - The result is marked `view: "lean"` and handed to the existing lean decoding.
 */
export function assembleLeanFromSplit(
  index: MetadataIndexPayload,
  catalogs: ReadonlyMap<string, {
    resolveMap?: Record<string, string>;
    models: Record<string, object>;
    generationParameters: Record<string, unknown>;
    retiredModels?: unknown[];
  }>,
  options: { includeIndexOnlyProviders?: boolean } = {},
): Record<string, unknown> & {
  view: "lean";
  providers: Record<string, Record<string, unknown>>;
  generationParameterTables: GenerationParameterTable;
} {
  const providers: Record<string, Record<string, unknown>> = {};
  const generationParameterTables: GenerationParameterTable = {};
  const indexIsSchema3 = isMetadataSchema3(index);
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
      ...(indexIsSchema3 && catalog.retiredModels ? { retiredModels: catalog.retiredModels } : {}),
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
