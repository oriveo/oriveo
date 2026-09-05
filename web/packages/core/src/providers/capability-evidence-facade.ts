import type { GenerationParameterProfile } from './request-builders/types';

export type CapabilitySupport = 'supported' | 'unsupported' | 'unknown';
export type CapabilityEvidenceSource =
  | 'server_typed'
  | 'server_profile'
  | 'relay_verification'
  | 'relay_declaration'
  | 'runtime_observation'
  | 'operator_override'
  | 'legacy_metadata'
  | 'none';
export type CapabilityEvidenceGrade =
  | 'machine_verified'
  | 'effect_verified'
  | 'observed'
  | 'declared'
  | 'operator'
  | 'accepted_unverified'
  | 'legacy_unverified'
  | 'none';
export type CapabilityEvidenceScope =
  | 'provider_model_transport'
  | 'connection_model_transport'
  | 'exact_request';
export type CapabilityRequestPolicy =
  | 'allow'
  | 'omit_unsupported'
  | 'omit_unknown'
  | 'allow_explicit_unverified'
  | 'omit_runtime_rejected';
export type CapabilityEvidenceReason =
  | 'missing_evidence'
  | 'expired'
  | 'conflict'
  | 'transport_mismatch'
  | 'stale_generation'
  | 'runtime_rejected'
  | 'user_accepted_unverified'
  | 'legacy_payload'
  | 'unsupported'
  | 'supported';

export interface CapabilityEvidenceQuery {
  partitionId: string;
  connectionInstanceId: string;
  connectionGeneration: string;
  credentialEpoch: string;
  endpointFingerprint?: string;
  providerKind: string;
  modelId: string;
  canonicalModelId?: string;
  effectiveTransport: string;
  metadataRevision?: string;
  generationRevision?: string;
  now: number;
  hasExplicitValue: boolean;
}

export interface CapabilityEvidenceCandidate {
  key: string;
  support: CapabilitySupport;
  source: Exclude<CapabilityEvidenceSource, 'none'>;
  grade: Exclude<CapabilityEvidenceGrade, 'none'>;
  scope: CapabilityEvidenceScope;
  policy?: 'runtime_rejected';
  partitionId?: string;
  connectionInstanceId?: string;
  connectionGeneration?: string;
  credentialEpoch?: string;
  endpointFingerprint?: string;
  providerKind: string;
  modelId: string;
  transport: string;
  metadataRevision?: string;
  generationRevision?: string;
  /** Opaque public evidence revision; it is never substituted for metadata ETag. */
  evidenceRevision?: string;
  observedAt?: number;
  expiresAt?: number;
}

export interface CapabilityEvidenceResolution {
  key: string;
  support: CapabilitySupport;
  source: CapabilityEvidenceSource;
  grade: CapabilityEvidenceGrade;
  requestPolicy: CapabilityRequestPolicy;
  reasonCode: CapabilityEvidenceReason;
  policyEvidence: Pick<CapabilityEvidenceCandidate, 'source' | 'grade'> | null;
}

export interface GenerationParameterEvidenceContext {
  partitionId: string;
  providerKind: string;
  modelId: string;
  canonicalModelId?: string;
  effectiveTransport: string;
  metadataRevision?: string;
  generationRevision?: string;
  connectionInstanceId?: string;
  connectionGeneration?: string;
  credentialEpoch?: string;
  endpointFingerprint?: string;
}

const SOURCE_PRIORITY: Record<Exclude<CapabilityEvidenceSource, 'runtime_observation' | 'none'>, number> = {
  operator_override: 0,
  server_typed: 1,
  server_profile: 2,
  relay_verification: 3,
  relay_declaration: 4,
  legacy_metadata: 5,
};

/**
 * Pure capability-evidence facade. Candidates are already safe, normalized
 * facts; it neither imports clients nor handles credentials/endpoints.
 */
export function resolveCapabilityEvidence(
  key: string,
  query: CapabilityEvidenceQuery,
  candidates: readonly CapabilityEvidenceCandidate[],
): CapabilityEvidenceResolution {
  const keyed = candidates.filter((candidate) => candidate.key === key);
  const identityMatches = keyed.filter((candidate) => matchesIdentity(candidate, query));
  const transportMatches = isUsableTransport(query.effectiveTransport)
    ? identityMatches.filter(
      (candidate) => isUsableTransport(candidate.transport) && candidate.transport === query.effectiveTransport,
    )
    : [];
  const scoped = transportMatches.filter((candidate) => matchesScope(candidate, query));
  const fresh = scoped.filter((candidate) => !isExpired(candidate, query));
  const current = fresh.filter((candidate) => matchesRevision(candidate, query));
  const verdictCandidates = current.filter(
    (candidate) => candidate.policy !== 'runtime_rejected' && candidate.source !== 'runtime_observation',
  );
  const runtimeRejection = current.find(
    (candidate) => candidate.source === 'runtime_observation' && candidate.policy === 'runtime_rejected',
  );

  let resolution = resolveVerdict(
    key,
    query,
    verdictCandidates,
    keyed,
    identityMatches,
    transportMatches,
    scoped,
    fresh,
  );
  // Unverified is not the same as unsupported. Once the user has stated the intent explicitly,
  // "there is no evidence" must not be executed as "you may not use it". This check looks only at
  // hasExplicitValue, not at providerKind, and not at whether the evidence came from a relay
  // declaration or a legacy profile.
  // There are exactly two hard boundaries, both elsewhere: an explicit unsupported backed by
  // official evidence (support === 'unsupported'), and the upstream runtime rejection below.
  // Those are real conclusions.
  if (query.hasExplicitValue
    && resolution.requestPolicy === 'omit_unknown'
    && resolution.reasonCode !== 'conflict') {
    resolution = {
      ...resolution,
      requestPolicy: 'allow_explicit_unverified',
      reasonCode: 'user_accepted_unverified',
    };
  }
  if (runtimeRejection) {
    resolution = {
      ...resolution,
      requestPolicy: 'omit_runtime_rejected',
      reasonCode: 'runtime_rejected',
      policyEvidence: {
        source: runtimeRejection.source,
        grade: runtimeRejection.grade,
      },
    };
  }
  return resolution;
}

/**
 * Converts the production-normalized generation profile into safe facade
 * candidates. Raw metadata must first pass `resolveGenerationProfile`.
 */
export function generationParameterEvidenceCandidates(
  profile: GenerationParameterProfile,
  context: GenerationParameterEvidenceContext,
): CapabilityEvidenceCandidate[] {
  const relay = context.providerKind === 'relay';
  const scope: CapabilityEvidenceScope = relay
    ? 'connection_model_transport'
    : 'provider_model_transport';

  return profile.parameters.map((parameter) => {
    // A public catalog describes an official model, never the user-owned
    // Relay endpoint that happens to expose the same ID. Relay therefore
    // retains only its explicit-value declaration, irrespective of whether
    // the normalized profile originated as provider metadata.
    const source = relay ? 'relay_declaration' as const : generationSource(parameter.source, false);
    return {
      key: `generation_parameter/${parameter.id}`,
      // Provider kind never changes support semantics. Relay candidates remain
      // connection-exact via scope/identity below; only accepted/unknown states
      // may become an explicit unverified attempt.
      support: relay && !isNegativeGenerationSupport(parameter.support)
        ? 'unknown'
        : generationSupport(parameter.support),
      source,
      grade: relay
        ? isNegativeGenerationSupport(parameter.support) ? 'declared' : 'accepted_unverified'
        : generationGrade(parameter.support, parameter.source, source, false),
      scope,
      providerKind: context.providerKind,
      modelId: context.canonicalModelId ?? context.modelId,
      transport: context.effectiveTransport,
      metadataRevision: context.metadataRevision,
      generationRevision: context.generationRevision,
      ...(relay
        ? {
            connectionInstanceId: context.connectionInstanceId,
            connectionGeneration: context.connectionGeneration,
            credentialEpoch: context.credentialEpoch,
            endpointFingerprint: context.endpointFingerprint,
            partitionId: context.partitionId,
          }
        : {}),
    };
  });
}

/** UI editability is independent from requestPolicy/runtime self-heal. */
export function isCapabilityEvidenceEditable(evidence: Pick<CapabilityEvidenceResolution, 'support' | 'source' | 'grade'>): boolean {
  return evidence.support === 'supported'
    || (
      evidence.source === 'relay_declaration'
      && evidence.support === 'unknown'
      && (evidence.grade === 'accepted_unverified' || evidence.grade === 'declared')
    );
}

function resolveVerdict(
  key: string,
  query: CapabilityEvidenceQuery,
  candidates: readonly CapabilityEvidenceCandidate[],
  keyed: readonly CapabilityEvidenceCandidate[],
  identityMatches: readonly CapabilityEvidenceCandidate[],
  transportMatches: readonly CapabilityEvidenceCandidate[],
  scoped: readonly CapabilityEvidenceCandidate[],
  fresh: readonly CapabilityEvidenceCandidate[],
): CapabilityEvidenceResolution {
  if (candidates.length === 0) {
    return unknownResolution(
      key,
      noCandidateReason(keyed, identityMatches, transportMatches, scoped, fresh),
    );
  }

  const bestPriority = Math.min(...candidates.map(sourcePriority));
  const winners = candidates.filter((candidate) => sourcePriority(candidate) === bestPriority);
  if (new Set(winners.map((candidate) => candidate.support)).size > 1) {
    return unknownResolution(key, 'conflict');
  }

  // A relay accepted_unverified gets no branch of its own: it is the same "we do not know" as on
  // an official provider, handled by the single explicit-intent check at the end of
  // resolveCapabilityEvidence.
  return knownResolution(key, winners[0]);
}

function knownResolution(
  key: string,
  candidate: CapabilityEvidenceCandidate,
): CapabilityEvidenceResolution {
  return {
    key,
    support: candidate.support,
    source: candidate.source,
    grade: candidate.grade,
    requestPolicy: candidate.support === 'supported' ? 'allow' : candidate.support === 'unsupported'
      ? 'omit_unsupported'
      : 'omit_unknown',
    reasonCode: candidate.support === 'supported' ? 'supported' : candidate.support === 'unsupported'
      ? 'unsupported'
      : 'missing_evidence',
    policyEvidence: null,
  };
}

function unknownResolution(key: string, reasonCode: CapabilityEvidenceReason): CapabilityEvidenceResolution {
  return {
    key,
    support: 'unknown',
    source: 'none',
    grade: 'none',
    requestPolicy: 'omit_unknown',
    reasonCode,
    policyEvidence: null,
  };
}

function noCandidateReason(
  keyed: readonly CapabilityEvidenceCandidate[],
  identityMatches: readonly CapabilityEvidenceCandidate[],
  transportMatches: readonly CapabilityEvidenceCandidate[],
  scoped: readonly CapabilityEvidenceCandidate[],
  fresh: readonly CapabilityEvidenceCandidate[],
): CapabilityEvidenceReason {
  if (keyed.length > 0 && identityMatches.length > 0 && transportMatches.length === 0) {
    return 'transport_mismatch';
  }
  if (scoped.length > 0 && fresh.length === 0) return 'expired';
  if (fresh.some((candidate) => candidate.source === 'server_profile')) return 'stale_generation';
  return 'missing_evidence';
}

function matchesIdentity(candidate: CapabilityEvidenceCandidate, query: CapabilityEvidenceQuery): boolean {
  if (candidate.providerKind !== query.providerKind) return false;
  return candidate.modelId === query.modelId || candidate.modelId === query.canonicalModelId;
}

function isUsableTransport(value: string | undefined): value is string {
  return typeof value === 'string' && value.trim().length > 0 && value.trim() !== 'unknown';
}

function matchesScope(candidate: CapabilityEvidenceCandidate, query: CapabilityEvidenceQuery): boolean {
  if (candidate.scope === 'provider_model_transport') return true;
  // Connection/exact facts are never wildcards. A missing local identity or
  // final endpoint must fail closed rather than letting two undefined fields
  // compare equal across a recreated connection or changed relay URL.
  if (
    !candidate.partitionId || !candidate.connectionInstanceId || !candidate.connectionGeneration
    || !candidate.credentialEpoch || !candidate.endpointFingerprint
    || !query.partitionId || !query.connectionInstanceId || !query.connectionGeneration
    || !query.credentialEpoch || !query.endpointFingerprint
  ) return false;
  return candidate.partitionId === query.partitionId
    && candidate.connectionInstanceId === query.connectionInstanceId
    && candidate.connectionGeneration === query.connectionGeneration
    && candidate.credentialEpoch === query.credentialEpoch
    && candidate.endpointFingerprint === query.endpointFingerprint;
}

function matchesRevision(candidate: CapabilityEvidenceCandidate, query: CapabilityEvidenceQuery): boolean {
  if (candidate.metadataRevision != null && candidate.metadataRevision !== query.metadataRevision) return false;
  return candidate.generationRevision == null || candidate.generationRevision === query.generationRevision;
}

function isExpired(candidate: CapabilityEvidenceCandidate, query: CapabilityEvidenceQuery): boolean {
  return candidate.expiresAt != null && candidate.expiresAt <= query.now;
}

function sourcePriority(candidate: CapabilityEvidenceCandidate): number {
  return candidate.source === 'runtime_observation' ? Number.POSITIVE_INFINITY : SOURCE_PRIORITY[candidate.source];
}

function generationSupport(support: string): CapabilitySupport {
  if (support === 'supported') return 'supported';
  if (isNegativeGenerationSupport(support)) return 'unsupported';
  return 'unknown';
}

function isNegativeGenerationSupport(support: string): boolean {
  return support === 'unsupported' || support === 'fixed'
    || support === 'mode_dependent' || support === 'future_supported';
}

function generationSource(
  source: string,
  relay: boolean,
): Exclude<CapabilityEvidenceSource, 'none' | 'runtime_observation'> {
  if (source === 'authoritative_metadata' || source === 'provider_metadata') return 'server_profile';
  if (source === 'relay_declared') return 'relay_declaration';
  // Relay's locally saved engine/template declaration is connection-scoped;
  // it is not an official metadata fallback merely because old profiles used
  // the generic `user_declared` spelling.
  if (relay && source === 'user_declared') return 'relay_declaration';
  return 'legacy_metadata';
}

function generationGrade(
  support: string,
  rawSource: string,
  source: Exclude<CapabilityEvidenceSource, 'none' | 'runtime_observation'>,
  relay: boolean,
): Exclude<CapabilityEvidenceGrade, 'none' | 'observed' | 'machine_verified' | 'operator'> {
  if (
    relay
    && (support === 'accepted' || support === 'accepted_unverified')
    && source === 'relay_declaration'
  ) return 'accepted_unverified';
  if (source === 'server_profile' && rawSource === 'authoritative_metadata') return 'effect_verified';
  if (source === 'server_profile') return 'declared';
  if (source === 'relay_declaration') return 'declared';
  return 'legacy_unverified';
}
