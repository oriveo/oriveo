import type { GenerationParameterProfile } from './request-builders/types';
import { endImplementsWireFamily } from './protocol-implementations';
import { CONTROL_AUTO_AVAILABLE, CONTROL_UNAVAILABLE } from './request-preference/types';

/**
 * Input-class capability keys (the keys with family=input in capability_keys.v1.json), aligned verbatim with the contract file and
 * locked by the reconciliation in ports/index.test.ts; change this together when the contract adds a key.
 */
export const INPUT_CAPABILITY_KEYS = ['vision_input', 'file_input', 'video_input'] as const;
export type InputCapabilityKey = (typeof INPUT_CAPABILITY_KEYS)[number];

export type CapabilitySupport = 'supported' | 'unsupported' | 'unknown';
export type CapabilityEvidenceSource =
  | 'server_typed'
  | 'server_profile'
  /** Per-model fields declared by the subscription proxy `/models`. */
  | 'upstream_declaration'
  /** Server `model-facts` dictionary: cold-start fallback for subscription reasoning tiers. */
  | 'model_facts'
  /** The catalog-style truth source does not list this model. A marker, not a capability fact, so it has no priority. */
  | 'catalog_absent'
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
  | 'catalog_absent'
  | 'unsupported'
  | 'supported';

export interface CapabilityEvidenceQuery {
  partitionId: string;
  connectionInstanceId: string;
  connectionGeneration: string;
  credentialEpoch: string;
  endpointFingerprint?: string;
  /** Raw connection auth mode; an absent value is read as apiKey. */
  authMode?: 'apiKey' | 'subscription';
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
  /** `none` belongs only to `catalog_absent` candidates: not a graded fact. */
  grade: CapabilityEvidenceGrade;
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
  /** The Server recipe reference behind this fact; only official recipe verdicts carry it. */
  recipeRef?: string;
}

export interface CapabilityEvidenceResolution {
  key: string;
  support: CapabilitySupport;
  source: CapabilityEvidenceSource;
  grade: CapabilityEvidenceGrade;
  requestPolicy: CapabilityRequestPolicy;
  reasonCode: CapabilityEvidenceReason;
  policyEvidence: Pick<CapabilityEvidenceCandidate, 'source' | 'grade'> | null;
  /** The recipe reference of the winning candidate; not written when there is none. */
  recipeRef?: string;
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

const SOURCE_PRIORITY: Record<Exclude<CapabilityEvidenceSource, 'runtime_observation' | 'catalog_absent' | 'none'>, number> = {
  operator_override: 0,
  server_typed: 1,
  server_profile: 2,
  upstream_declaration: 3,
  model_facts: 4,
  relay_verification: 5,
  relay_declaration: 6,
  legacy_metadata: 7,
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
    (candidate) => candidate.policy !== 'runtime_rejected'
      && candidate.source !== 'runtime_observation'
      && candidate.source !== 'catalog_absent',
  );
  const runtimeRejection = current.find(
    (candidate) => candidate.source === 'runtime_observation' && candidate.policy === 'runtime_rejected',
  );

  // A model absent from the catalog only counts when no prioritized valid fact exists.
  const catalogAbsent = verdictCandidates.length === 0
    && current.some((candidate) => candidate.source === 'catalog_absent');
  let resolution = catalogAbsent
    ? catalogAbsentResolution(key)
    : resolveVerdict(
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
    && resolution.reasonCode !== 'conflict'
    && resolution.reasonCode !== 'catalog_absent') {
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
    ...(candidate.recipeRef ? { recipeRef: candidate.recipeRef } : {}),
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

function catalogAbsentResolution(key: string): CapabilityEvidenceResolution {
  return {
    key,
    support: 'unknown',
    source: 'catalog_absent',
    grade: 'none',
    requestPolicy: 'omit_unknown',
    reasonCode: 'catalog_absent',
    policyEvidence: null,
  };
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
  return candidate.source === 'runtime_observation' || candidate.source === 'catalog_absent'
    ? Number.POSITIVE_INFINITY
    : SOURCE_PRIORITY[candidate.source];
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

// ---------------------------------------------------------------------------
// Input-capability projection (contract: model catalog and capability truth, section 3; fixture capability_evidence_contract.v1.json
// inputCapabilityCases). Priority: hard block (kill switch, not implemented) > Relay override
// (ignored for official) > negative cache > verdict.

export type InputCapabilityVerdictState = typeof CONTROL_AUTO_AVAILABLE | 'unknown' | 'unavailable';

export interface InputCapabilityVerdict {
  state: InputCapabilityVerdictState;
  reasonCode?: string;
  wireFamily?: string;
  sourceRefs?: readonly string[];
}

export interface InputCapabilityOverride {
  op: 'add' | 'remove';
}

export type InputCapabilityConnection = 'official' | 'relay';

export interface InputCapabilityProjectionInput {
  key: InputCapabilityKey;
  /** null = the payload lacks this key, projected as unknown. */
  verdict: InputCapabilityVerdict | null;
  /** Whether this client implements the outbound protocol for the capability; a verdict.wireFamily absent from this client's protocol table is also treated as not implemented. */
  endImplements: boolean;
  override: InputCapabilityOverride | null;
  negativeCacheHit: boolean;
  connection: InputCapabilityConnection;
}

export type InputCapabilityDisabledReason =
  | 'disabled.kill_switch'
  | 'disabled.wire_not_implemented'
  | 'disabled.user_removed'
  | 'disabled.rejected_recently'
  | 'disabled.model_absent';

declare const inputCapabilityProjectionBrand: unique symbol;

/** Can only be produced by projectInputCapability; the brand field keeps it from being constructed outside the facade. */
export interface InputCapabilityProjection {
  readonly visible: boolean;
  readonly editable: boolean;
  readonly outbound: 'native_part' | 'placeholder';
  readonly hint: 'first_attach_once' | null;
  readonly disabledReason: InputCapabilityDisabledReason | null;
  readonly [inputCapabilityProjectionBrand]: true;
}

export function projectInputCapability(input: InputCapabilityProjectionInput): InputCapabilityProjection {
  const { verdict } = input;
  const reasonCode = verdict?.state === 'unavailable' ? verdict.reasonCode : undefined;
  // Hard block: no override can turn it over.
  if (reasonCode === 'provider_kill_switch') return disabledProjection('disabled.kill_switch');
  if (
    !input.endImplements
    || (verdict?.wireFamily != null && !endImplementsWireFamily(verdict.wireFamily))
    || reasonCode === 'transport_not_supported'
    || reasonCode === 'transport_not_implemented'
  ) return disabledProjection('disabled.wire_not_implemented');
  // Relay override; official connections ignore overrides.
  if (input.connection === 'relay' && input.override) {
    return input.override.op === 'add'
      ? projection(true, true, 'native_part', null, null)
      : disabledProjection('disabled.user_removed');
  }
  if (input.negativeCacheHit) return disabledProjection('disabled.rejected_recently');
  const state = verdict?.state ?? 'unknown';
  if (state === CONTROL_AUTO_AVAILABLE) return projection(true, true, 'native_part', null, null);
  if (state === 'unknown') return projection(false, true, 'native_part', 'first_attach_once', null);
  // Any other unavailable (model_capability_absent, managed_zero_payload, etc.) is treated as the model lacking the capability.
  return disabledProjection('disabled.model_absent');
}

function disabledProjection(reason: InputCapabilityDisabledReason): InputCapabilityProjection {
  return projection(false, false, 'placeholder', null, reason);
}

function projection(
  visible: boolean,
  editable: boolean,
  outbound: InputCapabilityProjection['outbound'],
  hint: InputCapabilityProjection['hint'],
  disabledReason: InputCapabilityDisabledReason | null,
): InputCapabilityProjection {
  return { visible, editable, outbound, hint, disabledReason } as InputCapabilityProjection;
}

/**
 * How to read the three-valued `parameterSupport` surface of metadata schema 2 (temperature / top_p / structured_output).
 *
 * Only schema 2 parameterSupport is recognised; a missing table / missing key / wrong shape is always unknown (send as is).
 * The legacy field supportsTemperature is left to the legacy projection and not read here. A pure function, shared by the managed api and the chat outbound gate.
 */
export interface ParameterSupportVerdict {
  /** The three-valued state word passed through as is; only {@link CONTROL_UNAVAILABLE} turns outbound off. */
  state: string;
  reasonCode?: string;
}

/** Generation parameter id -> parameterSupport key; structured output is json_schema among the generation parameters. */
const PARAMETER_SUPPORT_KEY_BY_PARAMETER: Readonly<Record<string, string>> = {
  temperature: 'temperature',
  top_p: 'top_p',
  json_schema: 'structured_output',
};

/** Take the verdict of this parameter as is; a missing table, missing key or wrong shape returns null (= unknown). */
export function parameterSupportVerdict(
  parameterSupport: unknown,
  parameterId: string,
): ParameterSupportVerdict | null {
  const key = PARAMETER_SUPPORT_KEY_BY_PARAMETER[parameterId];
  if (!key || !parameterSupport || typeof parameterSupport !== 'object') return null;
  const entry = (parameterSupport as Record<string, unknown>)[key];
  if (!entry || typeof entry !== 'object') return null;
  const { state, reasonCode } = entry as { state?: unknown; reasonCode?: unknown };
  if (typeof state !== 'string' || state === '') return null;
  return { state, ...(typeof reasonCode === 'string' ? { reasonCode } : {}) };
}

/** Only an explicit unavailable is not sent; unknown and a missing key are sent. */
export function parameterSupportAllows(parameterSupport: unknown, parameterId: string): boolean {
  return parameterSupportVerdict(parameterSupport, parameterId)?.state !== CONTROL_UNAVAILABLE;
}

/**
 * The final closing step of the chat outbound gate on a generation-parameter verdict: parameterSupport unavailable -> not sent (omit_unsupported);
 * upstream rejected it by signature before (negative cache valid) -> not sent (omit_runtime_rejected); otherwise returned as is.
 */
export function gateGenerationParameterResolution(
  resolution: CapabilityEvidenceResolution,
  facts: { verdict: ParameterSupportVerdict | null; rejectedRecently: () => boolean },
): CapabilityEvidenceResolution {
  // After the verdict is changed to unsupported / runtime_rejected, the recipe of the originally winning candidate no longer applies.
  const { recipeRef: _recipeRef, ...base } = resolution;
  if (facts.verdict?.state === CONTROL_UNAVAILABLE) {
    return {
      ...base,
      support: 'unsupported',
      source: 'server_typed',
      grade: 'declared',
      requestPolicy: 'omit_unsupported',
      reasonCode: 'unsupported',
      policyEvidence: { source: 'server_typed', grade: 'declared' },
    };
  }
  if (facts.rejectedRecently()) {
    return {
      ...base,
      support: 'unsupported',
      source: 'runtime_observation',
      grade: 'observed',
      requestPolicy: 'omit_runtime_rejected',
      reasonCode: 'runtime_rejected',
      policyEvidence: { source: 'runtime_observation', grade: 'observed' },
    };
  }
  return resolution;
}
