import type { AIModel, Provider } from '@oriveo/shared';
import type { CapabilityEvidenceCandidate } from '@oriveo/core/providers/capability-evidence-facade';
import { controlStateCapabilitySupport } from '@oriveo/core/providers/request-preference/capability-runtime';
import {
  getDeclaredReasoningLevels,
  getModelFacts,
  getModelFactsRevision,
} from '../../metadata/metadata-client';
import { canonicalFinalTransport } from '../../chat/capability-preference-settings';
import {
  THINKING_CAPABILITY_KEY,
  type CapabilityTruthAdapter,
  type CapabilityTruthQuery,
  type RelayCapabilityEvidenceIdentity,
} from './capability-truth-adapter';
import {
  currentCapabilityEvidenceModel,
  resolvedEvidenceCatalog,
  type CapabilityEvidenceModel,
} from './evidence-model';

type CandidateScopeFields = Pick<CapabilityEvidenceCandidate, 'scope'> & Partial<RelayCapabilityEvidenceIdentity>;

/**
  * the scope in which a metadata candidate lands. The criteria (which keys, what support) are the same for official and Relay;
  * the two differ only in "whether the fact is bound to vendor x model or to one specific connection", so only that is factored out.
 */
export interface MetadataCandidateScope {
  /** `undefined` is passed through unchanged: it means the H4 namespace is absent, and the legacy fallback is still allowed. */
  serverCandidates(
    model: CapabilityEvidenceModel,
    candidates: CapabilityEvidenceCandidate[] | undefined,
  ): CapabilityEvidenceCandidate[] | undefined;
  /** `undefined` means no legacy candidate can be produced right now (Relay does not have a connection identity yet). */
  legacyFields: CandidateScopeFields | undefined;
  toolCallFields: CandidateScopeFields;
  /**
      * Whether tool truth for models outside the catalog should consult model-facts. Official / subscription do; relay does not (capability spec, RELAY x tools):
      * relay tool truth consists only of overrides, engine declarations and the local negative cache.
   */
  toolCallModelFacts?: false;
  /**
      * Who answers for web. `recipe_verdict`: trust only the Server's recipe verdict for this model
      * (`capabilityControls.web.state`); whether `capabilities` mentions web plays no part.
      * Default keeps the old capability bit + webSearchProfile (a Relay connection's web fact does not come from an official recipe).
   */
  webSearch?: 'recipe_verdict';
  /**
   * Who answers for showing thinking. `catalog`: the official catalog entry capabilities contain reasoning, and model-facts reasoning is read only when the catalog lacks the model;
   * `declared`: capabilities declared on the connection contain reasoning (Relay).
   * With no source, no candidate is produced (treated as not shown, no guessing).
   */
  thinking: 'catalog' | 'declared';
}

const OFFICIAL_SCOPE: MetadataCandidateScope = {
  // The Server candidate carries the raw transport value of the model entry, while the query uses the canonical name (`gemini_generate` ->
  // `gemini_generate_content`). The facade matches by strict equality; without the same normalization the whole entry would end up as transport_mismatch.
  serverCandidates: (_model, candidates) => candidates?.map((candidate) => ({
    ...candidate,
    transport: canonicalFinalTransport(candidate.transport) ?? candidate.transport,
  })),
  legacyFields: { scope: 'provider_model_transport' },
  toolCallFields: { scope: 'provider_model_transport' },
  webSearch: 'recipe_verdict',
  thinking: 'catalog',
};

/**
  * Capability truth of official metadata: H4 candidates first, then the old capability bits translated into low-priority facts.
  * This is the only place allowed to interpret legacy model fields; the new `capabilityEvidenceCandidates` always win.
  * Upstream declarations of subscription accounts are not judged here - that is the job of `subscriptionTruthAdapter`.
 */
export const officialTruthAdapter: CapabilityTruthAdapter = {
  acceptsUnverifiedExplicitIntent: true,
  candidates: (query) => metadataTruthCandidates(query, OFFICIAL_SCOPE),
};

export function metadataTruthCandidates(
  query: CapabilityTruthQuery,
  scope: MetadataCandidateScope,
): CapabilityEvidenceCandidate[] {
  const candidates = metadataFactCandidates(query, scope);
  const { key } = query;
  // Show-thinking is produced only for a named query: unnamed enumerations (expiry scheduling, etc.) do not need it (these candidates carry no expiry),
  // and reading model-facts as well would spin up a sidecar load for every model outside the catalog and add a timer.
  if (key !== THINKING_CAPABILITY_KEY) return candidates;
  return [...candidates, ...thinkingCandidates(query, scope)];
}

/**
 * Candidate of show-thinking (`reasoning/thinking`); judged separately from the reasoning_level/* tiers.
 * When H4 has declared it owns this key the Server candidate answers and nothing is added here.
 */
function thinkingCandidates(
  query: CapabilityTruthQuery,
  scope: MetadataCandidateScope,
): CapabilityEvidenceCandidate[] {
  const { provider, model, effectiveTransport } = query;
  if (effectiveTransport === 'unknown' || !scope.legacyFields) return [];
  const evidenceModel = currentCapabilityEvidenceModel(provider, model);
  if (evidenceModel.capabilityEvidenceOwnedKeys?.includes(THINKING_CAPABILITY_KEY)) return [];
  const identity = {
    key: THINKING_CAPABILITY_KEY,
    providerKind: provider.kind,
    modelId: evidenceModel.canonicalModelId ?? evidenceModel.id,
    transport: effectiveTransport,
    ...scope.legacyFields,
  };
  const supportOf = (value: boolean) => (value ? 'supported' as const : 'unsupported' as const);
  if (scope.thinking === 'declared') {
    return [{
      ...identity,
      support: supportOf(evidenceModel.capabilities.includes('reasoning')),
      source: 'relay_declaration',
      grade: 'declared',
    }];
  }
  const catalog = resolvedEvidenceCatalog(provider, model);
  if (catalog.model) {
    return [{
      ...identity,
      support: supportOf((catalog.model.capabilities ?? []).includes('reasoning')),
      source: 'legacy_metadata',
      grade: 'legacy_unverified',
    }];
  }
  // model-facts is only a fallback for models outside the catalog and is not read on a catalog hit.
  const facts = catalog.providerKind ? modelFactsCanonicalFirst(catalog.providerKind, model) : undefined;
  if (typeof facts?.reasoning !== 'boolean') return [];
  return [{
    ...identity,
    support: supportOf(facts.reasoning),
    source: 'model_facts',
    grade: 'declared',
    evidenceRevision: getModelFactsRevision(),
  }];
}

function metadataFactCandidates(
  query: CapabilityTruthQuery,
  scope: MetadataCandidateScope,
): CapabilityEvidenceCandidate[] {
  const { provider, model, effectiveTransport, key } = query;
  const evidenceModel = currentCapabilityEvidenceModel(provider, model);
  const catalog = resolvedEvidenceCatalog(provider, model);
  // A transport-specific fact cannot safely match an unknown transport. Relay
  // declarations are additionally connection scoped, so they need the local
  // opaque identity supplied by the producer before they can be consumed.
  if (effectiveTransport === 'unknown') return [];
  // Namespace presence is itself a three-state protocol: `undefined` means
  // H4 is absent and legacy fallback remains allowed; an explicit empty list
  // means H4 answered but has no fact for this key, so stale local bits must
  // not revive it.
  const serverCandidates = scope.serverCandidates(
    evidenceModel,
    key === 'tool_call' && !catalog.model
      ? undefined
      // A catalog hit trusts catalog evidence only: missing / expired = unknown, with no fallback to the entry top-level toolCall (tool-call-order.v1).
      : key === 'tool_call'
        ? evidenceModel.capabilityEvidenceCandidates ?? []
        : evidenceModel.capabilityEvidenceCandidates,
  );
  const h4OwnedDimension = key === 'tool_call';
  if (evidenceModel.capabilityEvidenceViewMalformed && h4OwnedDimension) return [];
  if (serverCandidates !== undefined) {
    // H4 currently owns tool_call only. Generation is derived exclusively
    // from profiles.generation + the referenced parameter table. Its namespace
    // is authoritative for that key—even an empty list
    // means tool unknown—but cannot withdraw the legacy public facts for web,
    // vision, or reasoning before Server begins publishing them.
    if (key === 'tool_call' || evidenceModel.capabilityEvidenceOwnedKeys?.includes(key ?? '')) return serverCandidates;
    return [...serverCandidates, ...legacyCapabilityCandidates(provider, evidenceModel, effectiveTransport, scope)];
  }
  const legacy = legacyCapabilityCandidates(provider, evidenceModel, effectiveTransport, scope);
  if (key !== 'tool_call') return legacy;

  // modelFacts is a catalog-external fallback only. A catalog hit (including
  // an authoritative null/empty H4 namespace) must never be overwritten by a
  // lower-tier models.dev snapshot.
  const facts = !catalog.model && catalog.providerKind && scope.toolCallModelFacts !== false
    ? modelFactsCanonicalFirst(catalog.providerKind, model)
    : undefined;
  if (typeof facts?.toolCall === 'boolean') {
    return [
      toolCallCandidate({
        provider,
        model: evidenceModel,
        transport: effectiveTransport,
        support: facts.toolCall ? 'supported' : 'unsupported',
        scope,
        evidenceRevision: getModelFactsRevision(),
      }),
      ...legacy,
    ];
  }
  return legacy;
}

function toolCallCandidate(input: {
  provider: Provider;
  model: CapabilityEvidenceModel;
  transport: string;
  support: 'supported' | 'unsupported';
  scope: MetadataCandidateScope;
  evidenceRevision?: string;
}): CapabilityEvidenceCandidate {
  return {
    key: 'tool_call',
    support: input.support,
    source: 'server_typed',
    grade: 'declared',
    providerKind: input.provider.kind,
    modelId: input.model.canonicalModelId ?? input.model.id,
    transport: input.transport,
    evidenceRevision: input.evidenceRevision,
    ...input.scope.toolCallFields,
  };
}

function legacyCapabilityCandidates(
  provider: Provider,
  model: AIModel,
  transport: string,
  scope: MetadataCandidateScope,
): CapabilityEvidenceCandidate[] {
  if (!scope.legacyFields) return [];
  const base = {
    source: 'legacy_metadata' as const,
    grade: 'legacy_unverified' as const,
    providerKind: provider.kind,
    modelId: model.canonicalModelId ?? model.id,
    transport,
    ...scope.legacyFields,
  };
  return [
    ...(scope.webSearch === 'recipe_verdict'
      ? recipeWebSearchCandidates(model, base)
      // Web has a separate request profile.  Missing/withdrawn profile is an
      // unknown verdict even when an old persisted capabilities array says web.
      : [{ ...base, key: 'web_search', support: model.capabilities.includes('web') && Boolean(model.webSearchProfile) ? 'supported' as const : 'unknown' as const, ...controlRecipeRef(model, 'web') }]),
    // Vision trusts only the Server ruling capabilityControls.vision_input; the image mention in legacy capabilities no longer counts.
    { ...base, key: 'vision_input', support: controlStateCapabilitySupport(model.capabilityControls?.vision_input?.state) ?? 'unknown', ...controlRecipeRef(model, 'vision_input') },
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

/**
  * Official web trusts only the recipe verdict; how the state is read into a fact is defined by the control authority `controlStateCapabilitySupport`,
  * and no state words appear here. When the verdict reaches no conclusion (or was not delivered), no candidate is produced.
 */
function recipeWebSearchCandidates(
  model: AIModel,
  identity: Pick<CapabilityEvidenceCandidate, 'providerKind' | 'modelId' | 'transport' | 'scope'>,
): CapabilityEvidenceCandidate[] {
  const support = controlStateCapabilitySupport(model.capabilityControls?.web?.state);
  if (!support) return [];
  return [{ ...identity, key: 'web_search', support, source: 'server_profile', grade: 'declared', ...controlRecipeRef(model, 'web') }];
}

/** Attach the Server control recipe reference to the candidate (web_search <-> control key web); nothing is written when absent. */
function controlRecipeRef(model: AIModel, controlKey: string): { recipeRef?: string } {
  const recipeRef = model.capabilityControls?.[controlKey]?.recipeRef;
  return recipeRef ? { recipeRef } : {};
}

/** model-facts lookup: the canonical in the match result wins (trimmed), then falls back to the model id. */
function modelFactsCanonicalFirst(providerKind: string, model: AIModel): ReturnType<typeof getModelFacts> {
  const canonical = model.canonicalModelId?.trim();
  return (canonical ? getModelFacts(providerKind, canonical) : undefined)
    ?? (canonical !== model.id ? getModelFacts(providerKind, model.id) : undefined);
}
