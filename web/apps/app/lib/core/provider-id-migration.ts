/**
 * Migration of legacy providers onto deterministic Provider IDs (conservative, local first, never
 * resurrects a tombstone).
 *
 * Folds the default instance of an official provider that still carries a random legacy id onto a
 * deterministic id derived from kind+region, so every client writes the same remote docId and the
 * duplicates merge on their own.
 *
 * Rules:
 *  - Runs once and is idempotent per account (the localStorage marker is partitioned by UID).
 *  - Purely local: it rewrites the local store and idb and never pushes. The LWW in startCloudSync
 *    afterwards respects remote tombstones (deletedAt), so a deterministic id that was deleted
 *    remotely does not come back.
 *  - Multiple instances: those sharing the same local apiKey fold into one deterministic id (models
 *    and customName are unioned); an instance with a different apiKey is kept separately with its
 *    random id untouched.
 *  - relay does not take part.
 */
import type { StoreApi } from 'zustand';
import type { AIModel, Provider, ProviderKind } from '@oriveo/shared';
import type { AppStore } from './store/app-store';
import { getActiveUID } from '../infra/storage/partition';
import { putProvider, deleteProvider } from '../infra/storage/idb';
import {
  hasPublicProviderConfigSource,
  listPublicProviderConfigs,
} from './metadata/metadata-client';
import {
  resolveProviderSetupCatalog,
  type ProviderSetupCatalog,
} from '../../app/providers/new/provider-config-catalog';
import {
  canonicalProviderKindForId,
  createDeterministicProviderId,
  normalizeUUID,
} from '../utils/id-utils';

type Store = StoreApi<AppStore>;

const MIGRATION_FLAG_PREFIX = 'oriveo.providerIdMigration.v1.';

/** Kinds that do not take part in deterministic ids (synthetic or custom endpoint). */
function isMigratableOfficialKind(kind: ProviderKind): boolean {
  return kind !== 'relay';
}

function migrationFlagKey(uid: string): string {
  return `${MIGRATION_FLAG_PREFIX}${uid}`;
}

function hasRunMigration(uid: string): boolean {
  if (typeof localStorage === 'undefined') return false;
  return localStorage.getItem(migrationFlagKey(uid)) === 'done';
}

function markMigrationDone(uid: string): void {
  if (typeof localStorage === 'undefined') return;
  try {
    localStorage.setItem(migrationFlagKey(uid), 'done');
  } catch {
    /* Private mode or quota full: the migration stays re-runnable because it is idempotent, so ignore */
  }
}

/**
 * Look up the region option id from a provider's baseURLText.
 * A provider without a region returns an empty string, and so does a failed match (treated as the default instance).
 */
function resolveRegionId(provider: Provider, catalog: ProviderSetupCatalog): string {
  const config = catalog.configsByKind[provider.kind as keyof typeof catalog.configsByKind];
  const regionOptions = config?.regionOptions ?? [];
  if (regionOptions.length === 0) return '';

  const base = (provider.baseURLText ?? '').trim().replace(/\/+$/, '');
  if (!base) return regionOptions[0]?.id ?? '';

  const matched = regionOptions.find(
    (option) => option.baseURL.trim().replace(/\/+$/, '') === base,
  );
  return matched?.id ?? regionOptions[0]?.id ?? '';
}

/** Union models by id, keeping the first occurrence so nothing is duplicated. */
function unionModels(primary: AIModel[], secondary: AIModel[]): AIModel[] {
  const seen = new Set(primary.map((m) => m.id));
  const merged = [...primary];
  for (const m of secondary) {
    if (!seen.has(m.id)) {
      seen.add(m.id);
      merged.push(m);
    }
  }
  return merged;
}

interface MigrationPlan {
  nextProviders: Provider[];
  toPut: Provider[];
  toDelete: string[];
  changed: boolean;
}

/**
 * Pure function: given the current providers, produce the folded list plus the idb write and delete
 * instructions. Extracted so it can be unit tested without touching store, idb or localStorage.
 */
export async function planProviderIdMigration(
  providers: Provider[],
  catalog: ProviderSetupCatalog,
): Promise<MigrationPlan> {
  // 1. Group by key = "{canonicalKind}|{regionId}"
  const groups = new Map<string, Provider[]>();
  const passthrough: Provider[] = [];

  for (const provider of providers) {
    if (!isMigratableOfficialKind(provider.kind)) {
      passthrough.push(provider);
      continue;
    }
    const regionId = resolveRegionId(provider, catalog);
    const groupKey = `${canonicalProviderKindForId(provider.kind)}|${regionId}`;
    const list = groups.get(groupKey);
    if (list) {
      list.push(provider);
    } else {
      groups.set(groupKey, [provider]);
    }
  }

  const nextProviders: Provider[] = [...passthrough];
  const toPut: Provider[] = [];
  const toDelete: string[] = [];
  let changed = false;

  for (const group of groups.values()) {
    const regionId = resolveRegionId(group[0], catalog);
    const deterministicId = await createDeterministicProviderId(group[0].kind, regionId);

    // The provider in this group that already has a deterministic id (at most one, and unique in theory once clients have merged)
    const anchors = group.filter((p) => normalizeUUID(p.id) === deterministicId);
    const randoms = group.filter((p) => normalizeUUID(p.id) !== deterministicId);

    // Fold candidates: instances sharing an apiKey (including the anchor's) merge into the
    // deterministic id, while random instances with a different apiKey stay separate and keep their id.
    const anchorApiKey = anchors[0]?.apiKey;

    // Decide which random instances fold into the deterministic id:
    //  - With an anchor: those whose apiKey matches the anchor fold, the rest are kept.
    //  - Without an anchor: the first random becomes the fold target, everything sharing its apiKey
    //    folds with it, and instances with a different apiKey keep their random id.
    const foldTargetApiKey = anchorApiKey ?? randoms[0]?.apiKey;

    const toFold: Provider[] = [];
    const keepAsAdditional: Provider[] = [];
    for (const r of randoms) {
      if (foldTargetApiKey !== undefined && r.apiKey === foldTargetApiKey) {
        toFold.push(r);
      } else {
        keepAsAdditional.push(r);
      }
    }

    if (toFold.length === 0 && anchors.length > 0) {
      // Already a deterministic id and nothing to fold: keep the anchor as is
      nextProviders.push(...anchors);
      // keepAsAdditional is kept as is
      nextProviders.push(...keepAsAdditional);
      continue;
    }

    if (toFold.length === 0) {
      // Nothing to fold, which should not happen: with a non-empty randoms, foldTargetApiKey always matches the first one
      nextProviders.push(...group);
      continue;
    }

    // Merge the anchor and everything in toFold into a single deterministic id provider.
    // base is the anchor when there is one, preserving its firestoreUpdatedAt / status, otherwise the first toFold.
    const base = anchors[0] ?? toFold[0];
    let merged: Provider = { ...base, id: deterministicId };

    const others = anchors[0]
      ? toFold // the anchor is already base
      : toFold.slice(1); // the first toFold is already base

    for (const other of others) {
      merged = {
        ...merged,
        models: unionModels(merged.models, other.models),
        catalogModels: unionModels(merged.catalogModels, other.catalogModels),
        customName: merged.customName ?? other.customName,
      };
    }

    nextProviders.push(merged);
    nextProviders.push(...keepAsAdditional);

    // idb instructions: write the deterministic id and delete every folded random id, leaving keepAsAdditional alone
    const mergedChanged =
      !anchors[0] || normalizeUUID(anchors[0].id) !== deterministicId ||
      others.length > 0;
    if (mergedChanged) {
      changed = true;
      toPut.push(merged);
    }
    for (const folded of toFold) {
      if (normalizeUUID(folded.id) !== deterministicId) {
        changed = true;
        toDelete.push(folded.id);
      }
    }
  }

  return { nextProviders, toPut, toDelete, changed };
}

/**
 * Migration entry point, called from bootstrap.hydrateMetadataAndReconcileProviders.
 * Idempotent per account, and purely local.
 */
export async function collapseProvidersToDeterministicIds(store: Store): Promise<void> {
  let uid = 'guest';
  try {
    uid = (await getActiveUID()) || 'guest';
  } catch {
    /* Failed to read the UID: treat it as guest, which is still idempotent */
  }
  if (hasRunMigration(uid)) return;

  const providers = store.getState().providers;
  if (providers.length === 0) {
    markMigrationDone(uid);
    return;
  }

  // Fetch the provider config catalog the region lookup needs (falls back to constants when metadata is not ready)
  const catalog = resolveProviderSetupCatalog(
    hasPublicProviderConfigSource() ? listPublicProviderConfigs() : null,
  );

  const plan = await planProviderIdMigration(providers, catalog);

  if (plan.changed) {
    store.setState({ providers: plan.nextProviders });
    // Persist: delete the old random ids first, then write the deterministic id (the order is not constrained since the ids differ and cannot overwrite each other)
    await Promise.all([
      ...plan.toDelete.map((id) => deleteProvider(id).catch(() => {})),
      ...plan.toPut.map((p) => putProvider(p).catch(() => {})),
    ]);
  }

  markMigrationDone(uid);
}
