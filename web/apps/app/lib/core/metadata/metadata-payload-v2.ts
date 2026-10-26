/**
 * Per-entry validation of metadata schema 2 responses (see the model catalog and capability truth contract).
 *
 * Order: envelope (models / providers emptied) -> each provider (models removed) -> each model.
 * An invalid envelope rejects the whole payload (callers keep last-good); a bad provider / model is dropped on its own and recorded in `dropped`,
 * the record only carries provider, modelId, the first instancePath + keyword, and never any value.
 * Responses without metadataSchema, or with a value other than 2 / 3, do not come here (callers check isMetadataSchema2 first).
 * Schema 3 is only a compact catalog encoding (same shape as schema 2 once expanded); index / full validation is identical to schema 2.
 */
import {
  fullOrIndex as validateFullOrIndexEnvelope,
  model as validateModel,
  provider as validateProvider,
  type MetadataPayloadValidator,
} from "./metadata-payload-validators.generated.js";

export const MODEL_ENTRY_INVALID = "model_entry_invalid" as const;

/** One dropped entry: a missing modelId means the whole provider was dropped. */
export interface DroppedMetadataEntry {
  provider: string;
  modelId?: string;
  instancePath: string;
  keyword: string;
}

export type MetadataV2DecodeResult<T> =
  | { envelope: "accept"; data: T; dropped: DroppedMetadataEntry[] }
  | { envelope: "reject"; data: null; dropped: DroppedMetadataEntry[]; instancePath: string; keyword: string };

type JsonRecord = Record<string, unknown>;

function isRecord(value: unknown): value is JsonRecord {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

/** Whether the body belongs to the schema 2 family (2 or 3): both share the same payload validation and revision rules. */
export function isMetadataSchema2(data: unknown): data is JsonRecord {
  return isRecord(data) && (data.metadataSchema === 2 || data.metadataSchema === 3);
}

/** Whether the body is the schema 3 compact encoding (a catalog must be expanded per the contract before schema 2 rules apply). */
export function isMetadataSchema3(data: unknown): data is JsonRecord {
  return isRecord(data) && data.metadataSchema === 3;
}

/** The body metadataSchema; a missing value counts as 1. */
export function metadataSchemaOf(data: unknown): number {
  return isRecord(data) && typeof data.metadataSchema === "number" ? data.metadataSchema : 1;
}

/**
 * Revisions are only comparable within one schema: schema 3 and schema 2 share the same metadataRevision,
 * so when the cached body schema differs from the new body schema, treat it as having no comparable revision (accept and replace),
 * otherwise after an upgrade an old-schema index would be kept as "unchanged" and the new-schema catalogRevision would never match.
 */
export function comparableHeldRevision(
  held: number | null | undefined,
  heldSchema: number,
  incoming: unknown,
): number | null | undefined {
  return heldSchema === metadataSchemaOf(incoming) ? held : null;
}

export type MetadataRevisionVerdict = "accept" | "unchanged" | "reject";

/** Only honours `metadataRevision` when body `metadataSchema` is 2 / 3; schema 1 has no revision and returns null. */
export function metadataRevisionOf(data: unknown): number | null {
  return isMetadataSchema2(data) && typeof data.metadataRevision === "number"
    ? data.metadataRevision
    : null;
}

/**
 * Revisions only move forward: no revision in the response, or no cached value (schema 1 / bundled 0) -> accept; newer > older accepts;
 * equal counts as 304; newer < older is rejected and the cache stays. The client and the Next server runtime share this one rule.
 */
export function compareMetadataRevision(
  held: number | null | undefined,
  incoming: number | null,
): MetadataRevisionVerdict {
  if (incoming === null || held == null || held === 0) return "accept";
  if (incoming > held) return "accept";
  return incoming === held ? "unchanged" : "reject";
}

function firstError(validator: MetadataPayloadValidator): { instancePath: string; keyword: string } {
  const error = validator.errors?.[0];
  return { instancePath: error?.instancePath ?? "", keyword: error?.keyword ?? "unknown" };
}

function reject<T>(validator: MetadataPayloadValidator): MetadataV2DecodeResult<T> {
  return { envelope: "reject", data: null, dropped: [], ...firstError(validator) };
}

function isUnderPricingV2(instancePath: string): boolean {
  return instancePath === "/pricingV2" || instancePath.startsWith("/pricingV2/");
}

const REGION_PRICING_ENTRY_PATH = /^\/regionPricing\/(\d+)(?:\/|$)/;

/** Error locations that can be removed on their own without losing the model: the whole pricingV2, the whole regionPricing, or one regionPricing item. */
function droppablePath(instancePath: string): boolean {
  return isUnderPricingV2(instancePath)
    || instancePath === "/regionPricing"
    || REGION_PRICING_ENTRY_PATH.test(instancePath);
}

/** Remove the bad key / bad region-price item by error location; an emptied regionPricing is removed with its key (the schema requires minItems 1). */
function withoutDroppedParts(model: JsonRecord, instancePaths: string[]): JsonRecord {
  const next: JsonRecord = { ...model };
  const badEntries = new Set<number>();
  for (const path of instancePaths) {
    if (isUnderPricingV2(path)) {
      delete next.pricingV2;
    } else if (path === "/regionPricing") {
      delete next.regionPricing;
    } else {
      const match = REGION_PRICING_ENTRY_PATH.exec(path);
      if (match) badEntries.add(Number(match[1]));
    }
  }
  if (badEntries.size > 0 && Array.isArray(next.regionPricing)) {
    const kept = (next.regionPricing as unknown[]).filter((_, index) => !badEntries.has(index));
    if (kept.length > 0) next.regionPricing = kept;
    else delete next.regionPricing;
  }
  return next;
}

/**
 * Validate a single model against the schema (a malformed pricingV2 only drops that key; a bad region-price item only drops that item).
 *
 * - Pass: keep as is.
 * - Fail with every error under `/pricingV2` or `/regionPricing`: remove the bad key / item and re-validate,
 *   until it passes (the model is kept, `droppedKey` carries the first original error for recording) or an error elsewhere shows up.
 * - Any other failure: drop the whole model with the first error (when re-validation after removal still fails, use the first error of the re-validation).
 */
export function validateMetadataModel(
  model: unknown,
):
  | { ok: true; model: unknown; droppedKey?: { instancePath: string; keyword: string } }
  | { ok: false; instancePath: string; keyword: string } {
  if (validateModel(model)) return { ok: true, model };
  const original = firstError(validateModel);
  if (!isRecord(model)) return { ok: false, ...original };
  let current: JsonRecord = model;
  // Each round removes at least one item; the cap guards against an endless loop when schema error paths do not match the removal.
  const regionCount = Array.isArray(model.regionPricing) ? model.regionPricing.length : 0;
  for (let round = 0; round <= regionCount + 2; round += 1) {
    const errors = validateModel.errors ?? [];
    if (errors.length === 0 || !errors.every((e) => droppablePath(e.instancePath ?? ""))) {
      return { ok: false, ...firstError(validateModel) };
    }
    current = withoutDroppedParts(current, errors.map((e) => e.instancePath ?? ""));
    if (validateModel(current)) return { ok: true, model: current, droppedKey: original };
  }
  return { ok: false, ...firstError(validateModel) };
}

/** Validate the models map one by one and return the kept models; bad ones (or a removed bad pricingV2) are appended to dropped. */
function keepValidModels(
  provider: string,
  models: JsonRecord,
  dropped: DroppedMetadataEntry[],
): JsonRecord {
  const kept: JsonRecord = {};
  for (const [modelId, model] of Object.entries(models)) {
    const verdict = validateMetadataModel(model);
    if (verdict.ok) {
      kept[modelId] = verdict.model;
      if (verdict.droppedKey) dropped.push({ provider, modelId, ...verdict.droppedKey });
    } else {
      dropped.push({ provider, modelId, instancePath: verdict.instancePath, keyword: verdict.keyword });
    }
  }
  return kept;
}

/** Also remove aliases in resolveMap that point at dropped models, so lookups never resolve to missing entries. */
function pruneResolveMap(resolveMap: unknown, kept: JsonRecord): unknown {
  if (!isRecord(resolveMap)) return resolveMap;
  const pruned: JsonRecord = {};
  for (const [alias, target] of Object.entries(resolveMap)) {
    if (typeof target !== "string" || Object.prototype.hasOwnProperty.call(kept, target)) {
      pruned[alias] = target;
    }
  }
  return pruned;
}

/** Full payload (no view) or index view: validate each provider, and validate the models under a provider one by one when present. */
export function decodeMetadataFullOrIndexV2(data: unknown): MetadataV2DecodeResult<JsonRecord> {
  const envelope = isRecord(data) && isRecord(data.providers) ? { ...data, providers: {} } : data;
  if (!validateFullOrIndexEnvelope(envelope)) return reject(validateFullOrIndexEnvelope);
  const raw = data as JsonRecord;
  const dropped: DroppedMetadataEntry[] = [];
  const providers: JsonRecord = {};
  let changed = false;
  for (const [providerKind, rawProvider] of Object.entries(raw.providers as JsonRecord)) {
    const { models: rawModels, ...providerFields } = isRecord(rawProvider) ? rawProvider : { models: undefined };
    const providerShape = isRecord(rawProvider) ? providerFields : rawProvider;
    if (!validateProvider(providerShape)) {
      dropped.push({ provider: providerKind, ...firstError(validateProvider) });
      changed = true;
      continue;
    }
    if (rawModels === undefined) {
      providers[providerKind] = rawProvider;
      continue;
    }
    if (!isRecord(rawModels)) {
      dropped.push({ provider: providerKind, instancePath: "/models", keyword: "type" });
      changed = true;
      continue;
    }
    const before = dropped.length;
    const models = keepValidModels(providerKind, rawModels, dropped);
    if (dropped.length === before) {
      providers[providerKind] = rawProvider;
      continue;
    }
    changed = true;
    providers[providerKind] = {
      ...(rawProvider as JsonRecord),
      models,
      ...((rawProvider as JsonRecord).resolveMap !== undefined
        ? { resolveMap: pruneResolveMap((rawProvider as JsonRecord).resolveMap, models) }
        : {}),
    };
  }
  return { envelope: "accept", data: changed ? { ...raw, providers } : raw, dropped };
}
