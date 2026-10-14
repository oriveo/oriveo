import type { AIModel, Provider } from '@oriveo/shared';
import type { CapabilityEvidenceCandidate } from '@oriveo/core/providers/capability-evidence-facade';
import { resolveCatalogModel } from '../../metadata/metadata-client';
import { providerFormOf } from './provider-form';

export type CapabilityEvidenceModel = AIModel & {
  capabilityEvidenceCandidates?: CapabilityEvidenceCandidate[];
  /** Allowlisted raw H4 keys, including malformed candidates intentionally dropped by decoding. */
  capabilityEvidenceOwnedKeys?: string[];
  /** H4 namespace was present but failed schema decoding; owned H4 dimensions fail closed. */
  capabilityEvidenceViewMalformed?: boolean;
  metadataRevision?: string;
};
type CatalogEvidenceModel = CapabilityEvidenceModel & {
  profiles?: {
    reasoning?: string;
    webSearch?: string;
    generation?: AIModel['generationProfile'];
  };
};

type RelayMatchedModel = CapabilityEvidenceModel & {
  relayMatchedProviderKind?: string;
};

export function resolvedEvidenceCatalog(
  provider: Provider,
  model: AIModel,
): { model: CatalogEvidenceModel | null; providerKind?: string } {
  const providerKind = providerFormOf(provider) === 'relay'
    ? (model as RelayMatchedModel).relayMatchedProviderKind
    : provider.kind;
  if (!providerKind) return { model: null };
  const catalog = resolveCatalogModel(model.id, providerKind) as CatalogEvidenceModel | null;
  if (catalog || !model.canonicalModelId || model.canonicalModelId === model.id) {
    return { model: catalog, providerKind };
  }
  return {
    model: resolveCatalogModel(model.canonicalModelId, providerKind) as CatalogEvidenceModel | null,
    providerKind,
  };
}

/** Current metadata wins over a persisted connection model for evidence only. */
export function currentCapabilityEvidenceModel(provider: Provider, model: AIModel): CapabilityEvidenceModel {
  const catalog = resolvedEvidenceCatalog(provider, model).model;
  if (!catalog) return model as CapabilityEvidenceModel;
  const fields = [
    'canonicalModelId', 'capabilityEvidenceCandidates', 'capabilityEvidenceOwnedKeys', 'capabilityEvidenceViewMalformed', 'metadataRevision',
    'toolCall', 'transport', 'capabilities', 'reasoningProfile',
    'reasoningModeAvailable', 'webSearchProfile', 'generationProfile',
  ] as const;
  const current = { ...model } as CapabilityEvidenceModel;
  // Presence—not truthiness—is the catalog withdrawal protocol. In
  // particular an ETag disappearing or a present empty candidate namespace
  // must erase the stale persisted value rather than quietly resurrect it.
  for (const field of fields) {
    if (Object.prototype.hasOwnProperty.call(catalog, field)) {
      Object.assign(current, { [field]: catalog[field] });
    }
  }
  // resolveCatalogModel exposes profiles as a nested authoritative shape,
  // whereas AIModel stores the consumed fields flat.  Project them explicitly
  // (including undefined withdrawals) so persisted models cannot retain a
  // stale web/reasoning/generation profile after metadata refresh.
  if (Object.prototype.hasOwnProperty.call(catalog, 'profiles')) {
    current.reasoningProfile = catalog.profiles?.reasoning;
    current.webSearchProfile = catalog.profiles?.webSearch;
    current.generationProfile = catalog.profiles?.generation;
    current.reasoningModeAvailable = Boolean(catalog.profiles?.reasoning);
  }
  return current;
}
