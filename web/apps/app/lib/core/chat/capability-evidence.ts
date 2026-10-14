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
import { getMetadataRevision, getRelayRuntimeConfig } from '../metadata/metadata-client';
import type { CapabilityLearningIdentity } from '@oriveo/core/providers/unsupported-param';
import { relayGenerationEndpointFingerprint } from '@oriveo/core/providers/relay-orchestrator';
import { decidedTransport } from '@oriveo/core/providers/relay-effective';
import { capabilityEvidenceIdentityForQuery } from '../providers/capability-evidence-identity';
import { resolveModelTransport } from '../providers/transport/model-transport-resolver';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { canonicalFinalTransport, subscriptionFinalTransport } from './capability-preference-settings';
import type {
  ModelCapabilityKey,
  RelayCapabilityEvidenceIdentity,
} from '../capability/truth/capability-truth-adapter';
import { capabilityTruthRegistry } from '../capability/truth/capability-truth-registry';
import { currentCapabilityEvidenceModel } from '../capability/truth/evidence-model';
import { providerFormOf } from '../capability/truth/provider-form';

// Callers of these names are spread across chat and the model picker; the definitions moved into
// capability/truth together with the adapters, and this entry point stays the same.
export type { ModelCapabilityKey, RelayCapabilityEvidenceIdentity };
export { currentCapabilityEvidenceModel };

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
  const form = providerFormOf(provider);
  const explicit = canonicalFinalTransport(explicitTransport);
  if (explicit) return explicit;
  if (form === 'subscription') {
    return subscriptionFinalTransport(provider, model) ?? 'unknown';
  }
  if (form === 'relay') {
    const relay = streamOptions?.relayTransport ?? decidedTransport(provider, model);
    return canonicalFinalTransport(relay) ?? 'unknown';
  }
  const evidenceModel = currentCapabilityEvidenceModel(provider, model);
  return canonicalFinalTransport(
    evidenceModel.transport ?? model.transport ?? resolveModelTransport(provider.kind, model.id),
  ) ?? 'unknown';
}

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
  if (providerFormOf(provider) !== 'relay') return undefined;
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
 * The capability candidates visible for this connection x model. Candidates are produced by the truth adapter
 * for the form (official metadata / Relay connection / subscription / Free catalog); this only hands the form
 * to the registry and no longer branches on provider itself.
 */
export function modelCapabilityEvidenceCandidates(
  provider: Provider,
  model: AIModel,
  effectiveTransport = effectiveCapabilityTransport(provider, model),
  relayIdentity?: RelayCapabilityEvidenceIdentity,
  key?: ModelCapabilityKey,
): CapabilityEvidenceCandidate[] {
  return capabilityTruthRegistry.adapterFor(providerFormOf(provider)).candidates({
    provider, model, effectiveTransport, relayIdentity, key,
  });
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
    // An absent authMode on the connection object means apiKey (the Free builder does not write this field);
    // the identity carries the raw value, so "absent" is not left for each consumer to interpret.
    authMode: provider.authMode ?? 'apiKey',
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
  const candidates = modelCapabilityEvidenceCandidates(
    input.provider,
    currentCapabilityEvidenceModel(input.provider, input.model),
    query.effectiveTransport,
    relayIdentity,
    input.key,
  );
  // "Explicit means allowed" presumes "no evidence = nobody has verified it". A closed-world adapter (a catalog)
  // producing no candidate for a key means the catalog did not declare it, i.e. does not offer it, so an explicit
  // intent does not count here; a model outside the catalog gets a catalog_absent candidate from the adapter,
  // handled by the facade's dedicated verdict, with no need to rewrite the intent here.
  const adapter = capabilityTruthRegistry.adapterFor(providerFormOf(input.provider));
  // State 1 (snapshot not fetched) is reported by the adapter itself: for keys the catalog owns the identity is
  // incomplete, and even the open world does not let them through.
  const failsClosed = adapter.failsClosed?.({
    provider: input.provider, model: input.model, effectiveTransport: query.effectiveTransport,
    relayIdentity, key: input.key,
  }) === true;
  const explicitIntentApplies = !failsClosed && (adapter.acceptsUnverifiedExplicitIntent
    || candidates.some((candidate) => candidate.key === input.key));
  return resolveCapabilityEvidence(
    input.key,
    explicitIntentApplies ? query : { ...query, hasExplicitValue: false },
    candidates,
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
      ?? (providerFormOf(input.provider) === 'relay'
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
