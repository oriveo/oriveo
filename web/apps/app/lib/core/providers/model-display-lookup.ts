import type { AIModel, Provider } from '@oriveo/shared';
import { resolveCatalogModel } from '../metadata/metadata-client';

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

      const localModel = findModelByIdentifier(provider?.models ?? [], trimmed);
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

      return {
        modelId: trimmed,
        canonicalModelId: undefined,
        displayName: undefined,
      };
    },
  };
}

export function findModelByIdentifier(
  models: AIModel[],
  modelId: string | null | undefined,
): AIModel | undefined {
  const candidates = normalizedModelCandidates(modelId);
  if (candidates.length === 0) return undefined;

  const exact = models.find((model) =>
    candidates.includes(model.id.trim().toLowerCase()),
  );
  if (exact) return exact;

  return models.find((model) =>
    modelLookupKeys(model).some((candidate) => candidates.includes(candidate)),
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
  ];

  return candidates
    .map((value) => value?.trim().toLowerCase())
    .filter((value): value is string => Boolean(value))
    .filter((value, index, array) => array.indexOf(value) === index);
}
