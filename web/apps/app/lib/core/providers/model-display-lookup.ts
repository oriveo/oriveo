import type { AIModel, Provider } from '@oriveo/shared';
import { getProviderRetiredModels, resolveCatalogModel } from '../metadata/metadata-client';
import { resolveRelayStoredModel } from './relay-model-identity';

const SNAPSHOT_DATE_RE = /(?:-\d{8}|-\d{4}-\d{2}-\d{2})$/;

export interface ResolvedModelDisplay {
  modelId: string;
  canonicalModelId: string | undefined;
  displayName: string | undefined;
}

export interface ModelDisplayLookup {
  resolve: (modelId: string | null | undefined) => ResolvedModelDisplay | null;
}

type LookupProvider = Pick<Provider, 'kind' | 'models'>;

export function createModelDisplayLookup(
  provider: LookupProvider | undefined,
): ModelDisplayLookup {
  return {
    resolve(modelId: string | null | undefined): ResolvedModelDisplay | null {
      const trimmed = modelId?.trim();
      if (!trimmed) return null;

      // Resolving the stored value for the relay session row display name uses read compatibility, not date-stripping / canonical folding.
      const localModel = provider?.kind === 'relay'
        ? resolveRelayStoredModel(provider.models, trimmed)
        : findModelByIdentifier(provider?.models ?? [], trimmed);
      if (provider && provider.kind !== 'relay') {
        const resolved = resolveCatalogModel(trimmed, provider.kind);
        if (resolved) {
          return {
            modelId: localModel?.id ?? resolved.canonicalModelId,
            canonicalModelId: localModel?.canonicalModelId ?? resolved.canonicalModelId,
            displayName: resolved.displayName ?? localModel?.name,
          };
        }
      }

      if (localModel) {
        return {
          modelId: localModel.id,
          canonicalModelId: localModel.canonicalModelId,
          displayName: localModel.name,
        };
      }

      // Neither the catalog nor local models have it: fall back to the tombstone name from the official catalog (retired models); relay connections do not use tombstones.
      const tombstoneName = provider && provider.kind !== 'relay'
        ? getProviderRetiredModels(provider.kind).find((entry) => entry.id === trimmed)?.displayName?.trim()
        : undefined;

      return {
        modelId: trimmed,
        canonicalModelId: undefined,
        displayName: tombstoneName || undefined,
      };
    },
  };
}

/**
 * Find a model in a model list by identifier (same rule as iOS ModelResolver.matchingModel):
 * candidates = [original id, date-stripped id], de-duplicated case-insensitively. Tier 1, exact: take the first
 * model whose id equals a candidate, in candidate order. Tier 2, alias: the first model in list order whose
 * canonical / id / date-stripped id / date-stripped canonical equals any candidate.
 * Web has no manual-prefix convention, so there is no prefix-stripping tier. When `accept` is given, matching only
 * considers the models it accepts (it is called only for models whose key hits, which keeps it lazy).
 */
export function findModelByIdentifier<T extends Pick<AIModel, 'id' | 'canonicalModelId'>>(
  models: readonly T[],
  modelId: string | null | undefined,
  accept: (model: T) => boolean = () => true,
): T | undefined {
  const candidates = normalizedModelCandidates(modelId);
  if (candidates.length === 0) return undefined;

  for (const candidate of candidates) {
    const exact = models.find((model) => model.id.trim().toLowerCase() === candidate && accept(model));
    if (exact) return exact;
  }

  return models.find((model) =>
    modelLookupKeys(model).some((key) => candidates.includes(key)) && accept(model),
  );
}

function normalizedModelCandidates(modelId: string | null | undefined): string[] {
  const trimmed = modelId?.trim();
  if (!trimmed) return [];

  const normalized = trimmed.replace(SNAPSHOT_DATE_RE, '');
  const candidates = normalized === trimmed ? [trimmed] : [trimmed, normalized];

  return candidates
    .map((value) => value.toLowerCase())
    .filter((value, index, array) => array.indexOf(value) === index);
}

function modelLookupKeys(model: Pick<AIModel, 'id' | 'canonicalModelId'>): string[] {
  const candidates = [
    model.id,
    model.id.replace(SNAPSHOT_DATE_RE, ''),
    model.canonicalModelId,
    model.canonicalModelId?.replace(SNAPSHOT_DATE_RE, ''),
  ];

  return candidates
    .map((value) => value?.trim().toLowerCase())
    .filter((value): value is string => Boolean(value))
    .filter((value, index, array) => array.indexOf(value) === index);
}
