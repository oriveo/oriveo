import type { AIModel, Provider } from '@oriveo/shared';
import type { GenerationParameterProfile } from '@oriveo/core/providers/request-builders/types';
import type { StreamOptions } from '../providers/types';
import {
  generationParameterEvidenceCandidates,
  resolveCapabilityEvidence,
  type CapabilityEvidenceCandidate,
  type CapabilityEvidenceQuery,
  type CapabilityEvidenceResolution,
} from '@oriveo/core/providers/capability-evidence-facade';
import {
  getDeclaredReasoningLevels,
  getModelFacts,
  getModelFactsRevision,
  getMetadataRevision,
  getRelayRuntimeConfig,
  resolveCatalogModel,
} from '../metadata/metadata-client';
import type { CapabilityLearningIdentity } from '@oriveo/core/providers/unsupported-param';
import { relayGenerationEndpointFingerprint } from '@oriveo/core/providers/relay-orchestrator';
import { capabilityEvidenceIdentityForQuery } from '../providers/capability-evidence-identity';
import { resolveModelTransport } from '../providers/transport/model-transport-resolver';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { canonicalFinalTransport, subscriptionFinalTransport } from './capability-preference-settings';

export type ModelCapabilityKey =
  | 'web_search'
  | 'vision_input'
  | 'tool_call'
  | `reasoning_level/${string}`;

type CapabilityEvidenceModel = AIModel & {
  capabilityEvidenceCandidates?: CapabilityEvidenceCandidate[];
  /** Allowlisted raw evidence keys, including malformed candidates intentionally dropped by decoding. */
  capabilityEvidenceOwnedKeys?: string[];
  /** The evidence view was present but failed schema decoding; keys it owns fail closed. */
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

function resolvedEvidenceCatalog(
  provider: Provider,
  model: AIModel,
): { model: CatalogEvidenceModel | null; providerKind?: string } {
  const providerKind = provider.kind === 'relay'
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
  // whereas AIModel stores the consumed fields flat. Project them explicitly
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

/**
 * Resolves the transport that the production dispatcher will actually use.
 * Subscription transports are connection facts, while Relay `auto` remains
 * unknown until probe/runtime resolution supplies an exact transport.
 */
export function effectiveCapabilityTransport(
  provider: Provider,
  model: AIModel,
  explicitTransport?: string,
  streamOptions?: StreamOptions,
): string {
  const explicit = canonicalFinalTransport(explicitTransport);
  if (explicit) return explicit;
  if (provider.authMode === 'subscription') {
    return subscriptionFinalTransport(provider, model) ?? 'unknown';
  }
  if (provider.kind === 'relay') {
    const relay = streamOptions?.relayTransport
      ?? provider.relayResolvedTransport
      ?? (provider.relayRequested?.transport !== 'auto' ? provider.relayRequested?.transport : undefined);
    return canonicalFinalTransport(relay) ?? 'unknown';
  }
  const evidenceModel = currentCapabilityEvidenceModel(provider, model);
  return canonicalFinalTransport(
    evidenceModel.transport ?? model.transport ?? resolveModelTransport(provider.kind, model.id),
  ) ?? 'unknown';
}

export type RelayCapabilityEvidenceIdentity = Pick<CapabilityEvidenceQuery,
  'partitionId' | 'connectionInstanceId' | 'connectionGeneration' | 'credentialEpoch' | 'endpointFingerprint'>;

/**
 * The sole Web consumer adapter for the full Relay capability key. It uses
 * existing local identity state and the real request builder's final endpoint
 * fingerprint; it never creates identity, reads a key, or probes the Relay.
 */
export function relayCapabilityEvidenceIdentity(
  provider: Provider,
  model: AIModel,
  streamOptions?: StreamOptions,
): RelayCapabilityEvidenceIdentity | undefined {
  if (provider.kind !== 'relay') return undefined;
  // A Relay declaration is scoped to the endpoint selected by the actual
  // dispatch options. Never reconstruct that endpoint from model metadata:
  // image/Gemini routing can select a different final path.
  if (!streamOptions?.relayTransport) return undefined;
  const identity = capabilityEvidenceIdentityForQuery(getActiveUIDSync(), provider.id);
  if (!identity) return undefined;
  try {
    const endpointFingerprint = relayGenerationEndpointFingerprint(
      provider.baseURLText,
      model.id,
      streamOptions,
      getRelayRuntimeConfig(),
    );
    return endpointFingerprint ? { ...identity, endpointFingerprint } : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Connection-level identity for the unsupported-parameter negative cache. It carries two more
 * revisions than {@link RelayCapabilityEvidenceIdentity} and no endpointFingerprint, because the
 * fingerprint is computed in core from the real request and must not be guessed from model
 * metadata here.
 *
 * Official providers and relay share one source: the local identity store plus the current
 * metadata ETag. If either is missing (no identity entry, or no ETag) the result is undefined so
 * the write side fails closed instead of reusing observations across connections on half an
 * identity.
 */
export function capabilityLearningIdentity(
  provider: Provider,
  generationRevision?: string,
): CapabilityLearningIdentity | undefined {
  const identity = capabilityEvidenceIdentityForQuery(getActiveUIDSync(), provider.id);
  const metadataRevision = getMetadataRevision();
  const resolvedGenerationRevision = generationRevision ?? metadataRevision;
  if (!identity || !metadataRevision || !resolvedGenerationRevision) return undefined;
  return { ...identity, metadataRevision, generationRevision: resolvedGenerationRevision };
}

/**
 * The only Web adapter allowed to interpret legacy model fields. It turns
 * metadata's old capability bits into low-priority facts before consumers ask
 * the shared facade. New `capabilityEvidenceCandidates` always wins.
 */
export function modelCapabilityEvidenceCandidates(
  provider: Provider,
  model: AIModel,
  effectiveTransport = effectiveCapabilityTransport(provider, model),
  relayIdentity?: RelayCapabilityEvidenceIdentity,
  key?: ModelCapabilityKey,
): CapabilityEvidenceCandidate[] {
  const evidenceModel = currentCapabilityEvidenceModel(provider, model);
  const catalog = resolvedEvidenceCatalog(provider, model);
  // A transport-specific fact cannot safely match an unknown transport. Relay
  // declarations are additionally connection scoped, so they need the local
  // opaque identity supplied by the producer before they can be consumed.
  if (effectiveTransport === 'unknown') return [];
  // Namespace presence is itself a three-state protocol: `undefined` means
  // the evidence view is absent and legacy fallback remains allowed; an explicit empty list
  // means the view answered but has no fact for this key, so stale local bits must
  // not revive it.
  const serverCandidates = relayScopedCandidates(
    provider,
    evidenceModel,
    key === 'tool_call' && !catalog.model
      ? undefined
      : evidenceModel.capabilityEvidenceCandidates,
    relayIdentity,
  );
  const evidenceOwnedDimension = key === 'tool_call';
  if (evidenceModel.capabilityEvidenceViewMalformed && evidenceOwnedDimension) return [];
  if (serverCandidates !== undefined) {
    // The evidence view currently owns tool_call only. Generation is derived exclusively
    // from profiles.generation + the referenced parameter table. Its namespace
    // is authoritative for that key—even an empty list
    // means tool unknown—but cannot withdraw the legacy public facts for web,
    // vision, or reasoning before Server begins publishing them.
    if (key === 'tool_call' || evidenceModel.capabilityEvidenceOwnedKeys?.includes(key ?? '')) return serverCandidates;
    return [...serverCandidates, ...legacyCapabilityCandidates(provider, evidenceModel, effectiveTransport, relayIdentity)];
  }
  const legacy = legacyCapabilityCandidates(provider, evidenceModel, effectiveTransport, relayIdentity);
  if (key !== 'tool_call') return legacy;

  // Subscription catalogs are first-party declarations fetched with the
  // signed-in account. They outrank the persisted models.dev snapshot.
  if (provider.authMode === 'subscription' && typeof model.toolCall === 'boolean') {
    return [toolCallCandidate({
      provider,
      model: evidenceModel,
      transport: effectiveTransport,
      support: model.toolCall ? 'supported' : 'unsupported',
      relayIdentity,
      evidenceRevision: 'subscription',
    })];
  }

  // modelFacts is a catalog-external fallback only. A catalog hit (including
  // an authoritative null/empty evidence view) must never be overwritten by a
  // lower-tier models.dev snapshot.
  const facts = !catalog.model && catalog.providerKind
    ? getModelFacts(catalog.providerKind, model.id)
      ?? (model.canonicalModelId ? getModelFacts(catalog.providerKind, model.canonicalModelId) : undefined)
    : undefined;
  if (typeof facts?.toolCall === 'boolean') {
    return [
      toolCallCandidate({
        provider,
        model: evidenceModel,
        transport: effectiveTransport,
        support: facts.toolCall ? 'supported' : 'unsupported',
        relayIdentity,
        evidenceRevision: getModelFactsRevision(),
      }),
      ...legacy,
    ];
  }
  return legacy;
}

/**
 * Builds the shared query from the current production model/provider objects.
 * Relay's connection identity is deliberately injected by its local producer;
 * without it, connection-scoped candidates fail closed in the facade.
 */
export function modelCapabilityEvidenceQuery(input: {
  provider: Provider;
  model: AIModel;
  effectiveTransport?: string;
  hasExplicitValue?: boolean;
  relayIdentity?: RelayCapabilityEvidenceIdentity;
  generationRevision?: string;
  /** The exact options which the caller will dispatch, when this is Relay. */
  streamOptions?: StreamOptions;
}): CapabilityEvidenceQuery {
  const { provider, model } = input;
  const evidenceModel = currentCapabilityEvidenceModel(provider, model);
  const relayIdentity = input.relayIdentity;
  return {
    partitionId: relayIdentity?.partitionId ?? '',
    connectionInstanceId: relayIdentity?.connectionInstanceId ?? '',
    connectionGeneration: relayIdentity?.connectionGeneration ?? '',
    credentialEpoch: relayIdentity?.credentialEpoch ?? '',
    endpointFingerprint: relayIdentity?.endpointFingerprint,
    providerKind: provider.kind,
    modelId: model.id,
    // Catalog re-enrichment is authoritative for aliases too. Keeping the
    // persisted model's old canonical id here lets a stale candidate match
    // after the catalog has withdrawn or retargeted it.
    canonicalModelId: evidenceModel.canonicalModelId,
    effectiveTransport: effectiveCapabilityTransport(
      provider,
      model,
      input.effectiveTransport,
      input.streamOptions,
    ),
    metadataRevision: evidenceModel.metadataRevision,
    generationRevision: input.generationRevision,
    now: Date.now(),
    hasExplicitValue: input.hasExplicitValue === true,
  };
}

function relayScopedCandidates(
  provider: Provider,
  model: CapabilityEvidenceModel,
  candidates: CapabilityEvidenceCandidate[] | undefined,
  relayIdentity?: RelayCapabilityEvidenceIdentity,
): CapabilityEvidenceCandidate[] | undefined {
  if (provider.kind !== 'relay' || candidates === undefined) return candidates;
  if (!relayIdentity) return [];
  return candidates.map((candidate) => ({
    ...candidate,
    providerKind: 'relay',
    modelId: model.canonicalModelId ?? model.id,
    scope: 'connection_model_transport' as const,
    ...relayIdentity,
  }));
}

function toolCallCandidate(input: {
  provider: Provider;
  model: CapabilityEvidenceModel;
  transport: string;
  support: 'supported' | 'unsupported';
  relayIdentity?: RelayCapabilityEvidenceIdentity;
  evidenceRevision?: string;
}): CapabilityEvidenceCandidate {
  const relay = input.provider.kind === 'relay';
  return {
    key: 'tool_call',
    support: input.support,
    source: 'server_typed',
    grade: 'declared',
    scope: relay ? 'connection_model_transport' : 'provider_model_transport',
    providerKind: input.provider.kind,
    modelId: input.model.canonicalModelId ?? input.model.id,
    transport: input.transport,
    evidenceRevision: input.evidenceRevision,
    ...(relay ? input.relayIdentity : {}),
  };
}

export function resolveModelCapabilityEvidence(input: {
  key: ModelCapabilityKey;
  provider: Provider;
  model: AIModel;
  effectiveTransport?: string;
  relayIdentity?: RelayCapabilityEvidenceIdentity;
  streamOptions?: StreamOptions;
  generationRevision?: string;
  /**
   * Whether the user expressed this intent explicitly, by turning web search on or picking a
   * reasoning level. The generation parameter path already passes the real value through
   * `resolveGenerationParameterEvidence`, while the model capability path defaults to false,
   * which leaves "explicit means allowed" unwired. The presentation side still queries with
   * false, because it asks whether evidence exists, not whether to send.
   */
  hasExplicitValue?: boolean;
}): CapabilityEvidenceResolution {
  const relayIdentity = input.relayIdentity ?? relayCapabilityEvidenceIdentity(
    input.provider,
    input.model,
    input.streamOptions,
  );
  const query = modelCapabilityEvidenceQuery({ ...input, relayIdentity });
  return resolveCapabilityEvidence(
    input.key,
    query,
    modelCapabilityEvidenceCandidates(
      input.provider,
      currentCapabilityEvidenceModel(input.provider, input.model),
      query.effectiveTransport,
      relayIdentity,
      input.key,
    ),
  );
}

/** Earliest future TTL among evidence visible to this model context. */
export function nextCapabilityEvidenceExpiry(input: {
  provider: Provider;
  model: AIModel;
  effectiveTransport?: string;
  relayIdentity?: RelayCapabilityEvidenceIdentity;
  streamOptions?: StreamOptions;
}): number | undefined {
  const relayIdentity = input.relayIdentity ?? relayCapabilityEvidenceIdentity(
    input.provider, input.model, input.streamOptions,
  );
  const query = modelCapabilityEvidenceQuery({ ...input, relayIdentity });
  const now = Date.now();
  return modelCapabilityEvidenceCandidates(
    input.provider,
    currentCapabilityEvidenceModel(input.provider, input.model),
    query.effectiveTransport,
    relayIdentity,
  ).map((candidate) => candidate.expiresAt)
    .filter((expiresAt): expiresAt is number => typeof expiresAt === 'number' && expiresAt > now)
    .sort((left, right) => left - right)[0];
}

/**
 * Projects the normalized generation profile into the shared facade. `profiles.generation` is the
 * sole parameter support matrix; capability evidence stays authoritative only for observed
 * capabilities such as tool_call.
 */
export function resolveGenerationParameterEvidence(input: {
  provider: Provider;
  model: AIModel;
  profile: GenerationParameterProfile;
  parameterId: string;
  hasExplicitValue: boolean;
  effectiveTransport?: string;
  relayIdentity?: RelayCapabilityEvidenceIdentity;
  streamOptions?: StreamOptions;
  generationRevision?: string;
}): CapabilityEvidenceResolution {
  const relayIdentity = input.relayIdentity ?? relayCapabilityEvidenceIdentity(
    input.provider,
    input.model,
    input.streamOptions,
  );
  const currentGenerationRevision = input.profile.revision ?? currentCapabilityEvidenceModel(
    input.provider,
    input.model,
  ).metadataRevision;
  const currentModel = currentCapabilityEvidenceModel(input.provider, input.model);
  const query = modelCapabilityEvidenceQuery({
    ...input,
    // Template names wire syntax (e.g. openai_chat_completions), not the
    // metadata TransportKind (e.g. openai_chat). Relay is the sole case
    // whose actual dispatch transport comes from stream options.
    effectiveTransport: input.effectiveTransport
      ?? (input.provider.kind === 'relay'
        ? input.streamOptions?.relayTransport ?? 'unknown'
        : currentModel.transport ?? 'unknown'),
    relayIdentity,
    generationRevision: currentGenerationRevision,
  });
  const evidenceKey = `generation_parameter/${input.parameterId}`;
  const candidates = generationParameterEvidenceCandidates(input.profile, {
    partitionId: query.partitionId,
    providerKind: query.providerKind,
    modelId: query.modelId,
    canonicalModelId: query.canonicalModelId,
    effectiveTransport: query.effectiveTransport,
    metadataRevision: query.metadataRevision,
    generationRevision: currentGenerationRevision,
    connectionInstanceId: query.connectionInstanceId || undefined,
    connectionGeneration: query.connectionGeneration || undefined,
    credentialEpoch: query.credentialEpoch || undefined,
    endpointFingerprint: query.endpointFingerprint,
  });
  return resolveCapabilityEvidence(
    evidenceKey,
    query,
    candidates,
  );
}

function legacyCapabilityCandidates(
  provider: Provider,
  model: AIModel,
  transport: string,
  relayIdentity?: RelayCapabilityEvidenceIdentity,
): CapabilityEvidenceCandidate[] {
  if (provider.kind === 'relay' && !relayIdentity) return [];
  const supports = (capability: string, profile?: unknown): 'supported' | 'unknown' => (
    model.capabilities.includes(capability) && (profile === undefined || Boolean(profile))
      ? 'supported'
      : 'unknown'
  );
  const base = {
    source: 'legacy_metadata' as const,
    grade: 'legacy_unverified' as const,
    scope: 'provider_model_transport' as const,
    providerKind: provider.kind,
    modelId: model.canonicalModelId ?? model.id,
    transport,
    ...(provider.kind === 'relay'
      ? { scope: 'connection_model_transport' as const, ...relayIdentity! }
      : {}),
  };
  return [
    // Web has a separate request profile. Missing/withdrawn profile is an
    // unknown verdict even when an old persisted capabilities array says web.
    { ...base, key: 'web_search', support: model.capabilities.includes('web') && Boolean(model.webSearchProfile) ? 'supported' : 'unknown' },
    { ...base, key: 'vision_input', support: supports('image') },
    {
      ...base,
      key: 'tool_call',
      support: model.toolCall === true ? 'supported' : model.toolCall === false ? 'unsupported' : 'unknown',
    },
    ...(model.reasoningProfile
      ? getDeclaredReasoningLevels(model.reasoningProfile).map((level) => ({
          ...base,
          key: `reasoning_level/${level}`,
          support: model.reasoningModeAvailable ? 'supported' as const : 'unknown' as const,
        }))
      : []),
  ];
}
