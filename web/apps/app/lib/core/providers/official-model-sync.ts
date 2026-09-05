/**
 * Builds the enabled model set for official providers (shared by Setup / Resync / Backup Restore).
 *
 * Catalog truth for official providers comes from the bundled catalog: enabled models are derived
 * from the canonical model catalog, and adapter catalogs are never a truth source.
 *
 * Rules:
 *   1. contractVersion outside the compatibility window -> safe degrade, return an empty catalog
 *   2. No entry for the provider in the catalog -> also return an empty catalog (callers may keep
 *      the models they already enabled)
 *   3. Enabled models only represent the set the user turned on:
 *      - with `prevEnabledIds`, keep only the canonical subset that still matches
 *      - without a previous set, enable a single initial default model
 *   4. Default model resolution: prevDefaultModelId (alias -> canonical) ->
 *      preferredDefaultId (alias -> canonical) -> providers[kind].defaultModelId ->
 *      first canonical entry in the catalog
 *   5. Manual-Retained: when the flag is on, local ids missing from the catalog are pruned once;
 *      the missing ids are reported to the caller in `prunedModelIds`
 *   6. alias -> canonical remaps are recorded in `aliasRemappings` so callers (bootstrap /
 *      backup import) know which old ids were merged
 *   7. catalogModels is always `[]`; official providers do not keep a local catalog
 */

import type { AIModel, ProviderKind } from '@oriveo/shared';
import {
  resolveProviderCatalog,
  type CatalogMetadataInput,
} from './catalog-resolver';
import { MANUAL_RETAINED_PRUNING_ENABLED } from '../metadata/metadata-runtime';

const LEGACY_CLOUD_FULL_CATALOG_MIGRATION_CUTOFF_MS = Date.parse('2026-04-19T00:00:00Z');

export interface OfficialUserPrefs {
  /** Current default model candidate id (alias or canonical; used for alias->canonical mapping) */
  preferredDefaultId?: string | null;
  /** Model ids the user had enabled last time (alias / canonical / dated are all accepted) */
  prevEnabledIds?: string[];
  /** Full models the user had enabled last time, used to keep manual-retained entries */
  prevEnabledModels?: AIModel[];
  /** Local catalog persisted by older versions, used to spot enabled=whole-catalog dirty data */
  prevCatalogModels?: AIModel[];
  /** Default model id the user picked last time (alias or canonical) */
  prevDefaultModelId?: string | null;
  /** Local provider update time, used to spot stale cloud state */
  updatedAt?: string | null;
  /** Update time acknowledged by the sync backend, used to spot stale remote state */
  firestoreUpdatedAt?: string | null;
}

/**
 * Runtime switches, letting tests override module-level constants without leaking across tests.
 * Production callers omit this and fall back to the module constants and the real catalog state.
 */
export interface OfficialBuildOverrides {
  /** Overrides `MANUAL_RETAINED_PRUNING_ENABLED`; reads the module constant when undefined */
  manualRetainedPruningEnabled?: boolean;
  /** Overrides whether contractVersion forces a safe degrade; treated as false when undefined */
  contractVersionDegraded?: boolean;
  /** Repairs old dirty data where the whole catalog had been marked enabled */
  repairLegacyAutoEnabledAll?: boolean;
}

export interface OfficialProviderModelsBuild {
  /** Models the user can see and enable (all canonical ids); exactly one carries isDefault=true */
  models: AIModel[];
  /** Resolved canonical id of the default model; empty string when the catalog is empty */
  defaultModelId: string;
  /** Official providers keep no local catalog, so this is always an empty array */
  catalogModels: [];
  /**
   * Local model ids pruned during this rebuild (Manual-Retained).
   * Only populated when `overrides.manualRetainedPruningEnabled === true`.
   * Callers can use it to report telemetry such as Sentry `metadata.resolver.miss`.
   */
  prunedModelIds: string[];
  /**
   * alias -> canonical remaps performed during this rebuild.
   * Callers can use it to update persisted ids asynchronously (store / IndexedDB `model.id`),
   * or to translate old ids to canonical ones while importing a backup.
   */
  aliasRemappings: Record<string, string>;
}

/**
 * Builds the enabled model set of an official provider.
 *
 * @param providerKind Built-in provider kind (relay is not accepted)
 * @param metadata bundled provider catalog snapshot
 * @param userPrefs User preferences (alias / dated ids are allowed and resolved to canonical)
 * @param overrides Runtime switches, mainly for tests and degraded paths
 */
export function buildOfficialEnabledModels(
  providerKind: ProviderKind,
  metadata: CatalogMetadataInput | null,
  userPrefs: OfficialUserPrefs,
  overrides: OfficialBuildOverrides = {},
): OfficialProviderModelsBuild {
  const empty: OfficialProviderModelsBuild = {
    models: [],
    defaultModelId: '',
    catalogModels: [],
    prunedModelIds: [],
    aliasRemappings: {},
  };

  // contractVersion safe degrade: the catalog must not be extended
  if (overrides.contractVersionDegraded) {
    return empty;
  }

  // Compute the canonical catalog with resolveProviderCatalog, keeping manual-retained entries via prevEnabledModels.
  const resolved = resolveProviderCatalog(
    { kind: providerKind, models: userPrefs.prevEnabledModels ?? [], catalogModels: [] },
    metadata,
  );

  // The catalog has no entry for this provider -> safe degrade
  const canonicalCatalog = resolved.catalog.filter((model) => !model.isManual);
  if (canonicalCatalog.length === 0) {
    return empty;
  }

  // alias -> canonical lookup table, built straight from the catalog for id mapping
  const canonicalById = buildCanonicalIndex(metadata, providerKind);

  // Resolve the default model: prevDefault -> preferredDefault -> providers[kind].defaultModelId -> first canonical
  const canonicalIds = canonicalCatalog.map((m) => m.id);
  const canonicalSet = new Set(canonicalIds);

  const prevDefaultCanonical = mapToCanonical(userPrefs.prevDefaultModelId, canonicalById, canonicalSet);
  const preferredCanonical = mapToCanonical(userPrefs.preferredDefaultId, canonicalById, canonicalSet);
  const metadataDefault = resolved.defaultModel?.id ?? null;
  const initialDefaultId = resolveInitialDefaultId(canonicalCatalog);
  const resolvedDefaultId =
    prevDefaultCanonical
    ?? preferredCanonical
    ?? (metadataDefault && canonicalSet.has(metadataDefault) ? metadataDefault : null)
    ?? canonicalIds[0]
    ?? '';

  // Work out how the user's prevEnabledIds mapped, and report that to the caller
  const { prunedModelIds, aliasRemappings } = analysePrevEnabled(
    userPrefs.prevEnabledIds ?? [],
    canonicalById,
    canonicalSet,
    overrides.manualRetainedPruningEnabled ?? MANUAL_RETAINED_PRUNING_ENABLED,
  );

  const selectedCanonicalIds = resolveSelectedCanonicalIds({
    canonicalIds,
    canonicalById,
    prevEnabledIds: userPrefs.prevEnabledIds ?? [],
    prevCatalogModelIds: (userPrefs.prevCatalogModels ?? []).map((model) => model.id),
    preferredDefaultId: userPrefs.preferredDefaultId,
    prevDefaultCanonical,
    preferredCanonical,
    metadataDefault,
    initialDefaultId,
    remoteUpdatedAtMs: resolveRemoteUpdatedAtMs(userPrefs.updatedAt, userPrefs.firestoreUpdatedAt),
    repairLegacyAutoEnabledAll: overrides.repairLegacyAutoEnabledAll ?? false,
  });
  const selectedCanonicalSet = new Set(selectedCanonicalIds);
  const pruningEnabled = overrides.manualRetainedPruningEnabled ?? MANUAL_RETAINED_PRUNING_ENABLED;
  const manualRetainedModels = pruningEnabled
    ? []
    : resolved.enabledModels
      .filter((model) => model.isManual)
      .map((model) => ({
        // manual-retained path: drop the resolver-computed isEnabled but keep isManual=true on the model itself
        // (isManual is persisted truth, not a resolver-computed field)
        ...stripResolverFieldsKeepingManual(model),
        isDefault: false,
      }));

  const canonicalModels: AIModel[] = canonicalCatalog
    .filter((model) => selectedCanonicalSet.has(model.id))
    .map((model) => ({
      ...model,
      // Drop the resolver-only fields (isEnabled / isManual) to match the AIModel contract
      isEnabled: undefined,
      isManual: undefined,
      isDefault: false,
    }))
    .map(stripResolverFields);
  const manualDefaultId = pruningEnabled
    ? null
    : resolved.enabledModels.find((model) => model.isManual && model.isDefault)?.id;
  const canonicalDefaultId = selectedCanonicalSet.has(resolvedDefaultId)
    ? resolvedDefaultId
    : selectedCanonicalIds[0] ?? null;
  const outputDefaultId = manualDefaultId
    ?? canonicalDefaultId
    ?? manualRetainedModels[0]?.id
    ?? '';
  const models = markDefaultModel([...canonicalModels, ...manualRetainedModels], outputDefaultId);

  return {
    models,
    defaultModelId: outputDefaultId,
    catalogModels: [],
    prunedModelIds,
    aliasRemappings,
  };
}

/* ── Internal helpers ──────────────────────────────────────── */

/**
 * Builds the canonical id / alias / dated id -> canonical id lookup table.
 *
 * Note the `canonicalModelId !== modelId` check: canonical is only added to the map when the
 * catalog model key differs from canonicalModelId. Otherwise canonical would map to itself and
 * overwrite the self-mapping that the loop below already establishes via
 * `map.set(modelId, modelId)`.
 */
function buildCanonicalIndex(
  metadata: CatalogMetadataInput | null,
  providerKind: ProviderKind,
): Map<string, string> {
  const map = new Map<string, string>();
  const providerMeta = metadata?.providers[providerKind];
  if (!providerMeta) return map;

  for (const [modelId, meta] of Object.entries(providerMeta.models)) {
    map.set(modelId, modelId);
    if (meta.canonicalModelId && meta.canonicalModelId !== modelId) {
      map.set(meta.canonicalModelId, modelId);
    }
    for (const alias of meta.aliases ?? []) {
      map.set(alias, modelId);
    }
  }
  return map;
}

function mapToCanonical(
  value: string | null | undefined,
  canonicalById: Map<string, string>,
  canonicalSet: Set<string>,
): string | null {
  if (!value) return null;
  const direct = canonicalById.get(value);
  if (direct && canonicalSet.has(direct)) return direct;
  return null;
}

/**
 * From the user's prevEnabledIds, works out:
 *   - which ids are aliases needing an asynchronous remap (`aliasRemappings`)
 *   - which ids the catalog does not know at all (potential misses)
 *
 * The Manual-Retained pruning switch decides what happens to a miss:
 *   - on: treat it as pruned and list it in `prunedModelIds`
 *   - off: leave it out (callers keep the local entry and render it in its own group)
 */
function analysePrevEnabled(
  prevEnabledIds: string[],
  canonicalById: Map<string, string>,
  canonicalSet: Set<string>,
  pruningEnabled: boolean,
): { prunedModelIds: string[]; aliasRemappings: Record<string, string> } {
  const prunedModelIds: string[] = [];
  const aliasRemappings: Record<string, string> = {};

  for (const prev of prevEnabledIds) {
    if (!prev) continue;
    const mapped = canonicalById.get(prev);
    if (mapped && canonicalSet.has(mapped)) {
      // alias -> canonical remap (only recorded when the id actually changes)
      if (mapped !== prev) {
        aliasRemappings[prev] = mapped;
      }
      continue;
    }

    // Catalog miss: pruned when the flag is on, kept locally when it is off
    if (pruningEnabled) {
      prunedModelIds.push(prev);
    }
  }

  return { prunedModelIds, aliasRemappings };
}

function resolveSelectedCanonicalIds({
  canonicalIds,
  canonicalById,
  prevEnabledIds,
  prevCatalogModelIds,
  preferredDefaultId,
  prevDefaultCanonical,
  preferredCanonical,
  metadataDefault,
  initialDefaultId,
  remoteUpdatedAtMs,
  repairLegacyAutoEnabledAll,
}: {
  canonicalIds: string[];
  canonicalById: Map<string, string>;
  prevEnabledIds: string[];
  prevCatalogModelIds: string[];
  preferredDefaultId?: string | null;
  prevDefaultCanonical: string | null;
  preferredCanonical: string | null;
  metadataDefault: string | null;
  initialDefaultId: string | null;
  remoteUpdatedAtMs: number;
  repairLegacyAutoEnabledAll: boolean;
}): string[] {
  const canonicalSet = new Set(canonicalIds);
  const resolvedPrevEnabled = prevEnabledIds
    .map((value) => canonicalById.get(value))
    .filter((value): value is string => Boolean(value && canonicalSet.has(value)));
  const dedupedPrevEnabled = [...new Set(resolvedPrevEnabled)];

  if (dedupedPrevEnabled.length > 0) {
    if (repairLegacyAutoEnabledAll && looksLikeLegacyAutoEnabledAll({
      canonicalIds,
      canonicalById,
      prevEnabledIds,
      prevCatalogModelIds,
      dedupedPrevEnabled,
      remoteUpdatedAtMs,
    })) {
      const repairedDefaultId = initialDefaultId ?? '';
      return repairedDefaultId ? [repairedDefaultId] : [];
    }
    return dedupedPrevEnabled;
  }

  const selectedDefaultId =
    prevDefaultCanonical
    ?? preferredCanonical
    ?? mapToCanonical(preferredDefaultId, canonicalById, canonicalSet)
    ?? (metadataDefault && canonicalSet.has(metadataDefault) ? metadataDefault : null)
    ?? canonicalIds[0]
    ?? "";

  return selectedDefaultId ? [selectedDefaultId] : [];
}

function looksLikeLegacyAutoEnabledAll({
  canonicalIds,
  canonicalById,
  prevEnabledIds,
  prevCatalogModelIds,
  dedupedPrevEnabled,
  remoteUpdatedAtMs,
}: {
  canonicalIds: string[];
  canonicalById: Map<string, string>;
  prevEnabledIds: string[];
  prevCatalogModelIds: string[];
  dedupedPrevEnabled: string[];
  remoteUpdatedAtMs: number;
}): boolean {
  if (dedupedPrevEnabled.length === 0 || dedupedPrevEnabled.length !== prevEnabledIds.length) {
    return false;
  }

  const canonicalSet = new Set(canonicalIds);
  if (prevCatalogModelIds.length > 0) {
    const resolvedLegacyCatalog = [...new Set(
      prevCatalogModelIds
        .map((value) => canonicalById.get(value))
        .filter((value): value is string => Boolean(value && canonicalSet.has(value))),
    )];
    if (
      resolvedLegacyCatalog.length > 0 &&
      resolvedLegacyCatalog.length === prevCatalogModelIds.length &&
      sameIdSet(dedupedPrevEnabled, resolvedLegacyCatalog)
    ) {
      return true;
    }
  }

  if (
    remoteUpdatedAtMs > 0 &&
    remoteUpdatedAtMs < LEGACY_CLOUD_FULL_CATALOG_MIGRATION_CUTOFF_MS &&
    dedupedPrevEnabled.length === canonicalIds.length &&
    sameIdSet(dedupedPrevEnabled, canonicalIds)
  ) {
    return true;
  }

  return false;
}

function sameIdSet(lhs: string[], rhs: string[]): boolean {
  if (lhs.length !== rhs.length) return false;
  const rhsSet = new Set(rhs);
  return lhs.every((value) => rhsSet.has(value));
}

function resolveInitialDefaultId(canonicalCatalog: AIModel[]): string | null {
  if (canonicalCatalog.length === 0) return null;

  const availableModels = canonicalCatalog.filter((model) => model.isAvailable);
  const candidatePool = availableModels.length > 0 ? availableModels : canonicalCatalog;
  return candidatePool.find((model) => model.isDefault)?.id
    ?? canonicalCatalog.find((model) => model.isDefault)?.id
    ?? candidatePool[0]?.id
    ?? canonicalCatalog[0]?.id
    ?? null;
}

function resolveRemoteUpdatedAtMs(
  updatedAt: string | null | undefined,
  firestoreUpdatedAt: string | null | undefined,
): number {
  const updatedAtMs = parseTimestampMs(updatedAt);
  const firestoreUpdatedAtMs = parseTimestampMs(firestoreUpdatedAt);
  return Math.max(updatedAtMs, firestoreUpdatedAtMs);
}

function parseTimestampMs(value: string | null | undefined): number {
  if (!value) return 0;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

type ResolverExtras = { isEnabled?: unknown; isManual?: unknown };

/**
 * Strips resolver-computed fields (isEnabled plus the resolver-computed isManual) off catalog hits.
 * Used for catalog-driven models: they must not carry isManual=true, since they were not hand-entered.
 */
function stripResolverFields(model: AIModel & ResolverExtras): AIModel {
  const { isEnabled: _isEnabled, isManual: _isManual, ...rest } = model;
  return rest;
}

/**
 * Strips the resolver-computed isEnabled but keeps the model's own isManual field (isManual is persisted truth).
 * Used for manual-retained models: isManual=true has to survive, or the next sync loses the hand-entered flag.
 */
function stripResolverFieldsKeepingManual(model: AIModel & ResolverExtras): AIModel {
  const { isEnabled: _isEnabled, ...rest } = model;
  return rest as AIModel;
}

function markDefaultModel(models: AIModel[], preferredModelId: string): AIModel[] {
  if (models.length === 0) return [];
  const resolvedDefaultId = models.some((model) => model.id === preferredModelId)
    ? preferredModelId
    : models[0].id;
  return models.map((model) => ({
    ...model,
    isDefault: model.id === resolvedDefaultId,
  }));
}
