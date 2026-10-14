import type { CapabilityEvidenceCandidate } from '@oriveo/core/providers/capability-evidence-facade';
import type {
  CapabilityTruthAdapter,
  CapabilityTruthQuery,
  RelayCapabilityEvidenceIdentity,
} from './capability-truth-adapter';
import { metadataTruthCandidates, type MetadataCandidateScope } from './official-truth-adapter';
import { relayFirstSendTransport } from '../../providers/relay-first-send-transport';
import { isRelayNegativeCached } from '../../chat/relay-negative-cache';
import { relayWebModelOptionFacts, resolveRelayWebPresentation } from '../../chat/relay-web-probe-records';

/**
  * Relay facts are bound to "this one connection": the same model name on another machine, with another key, or at another endpoint
  * may be a different matter. So candidates are always narrowed to the connection scope and carry the local identity; when the identity is absent no
  * matchable candidate is produced (fail closed), rather than falling back to a vendor-level wildcard fact.
 */
function relayCandidateScope(identity: RelayCapabilityEvidenceIdentity | undefined): MetadataCandidateScope {
  return {
    serverCandidates: (model, candidates) => {
      if (candidates === undefined) return candidates;
      if (!identity) return [];
      return candidates.map((candidate) => ({
        ...candidate,
        providerKind: 'relay',
        modelId: model.canonicalModelId ?? model.id,
        scope: 'connection_model_transport' as const,
        ...identity,
      }));
    },
    legacyFields: identity ? { scope: 'connection_model_transport', ...identity } : undefined,
    toolCallFields: { scope: 'connection_model_transport', ...identity },
    // Relay tool truth does not consult model-facts.
    toolCallModelFacts: false,
  };
}

/** The two keys an engine declaration can answer; thinking goes through the reasoning-tier path (engine declaration), not here. */
const ENGINE_DECLARATION_KEYS = [
  ['vision_input', 'image'],
  ['tool_call', 'toolCall'],
] as const;

/**
  * The declaration of a local engine (connection with an engineProfile) about this model: true -> supported, false -> unsupported,
  * a missing key is left to the existing rules. The declaration is a fact on this connection, so it also needs the local identity, and is not produced when absent (fail closed).
 */
function engineDeclarationCandidates(query: CapabilityTruthQuery): CapabilityEvidenceCandidate[] {
  const { provider, model, effectiveTransport, relayIdentity, key } = query;
  const declaration = model.engineDeclaration;
  if (!provider.relayRequested?.engineProfile || !declaration || !relayIdentity) return [];
  if (effectiveTransport === 'unknown') return [];
  return ENGINE_DECLARATION_KEYS.flatMap(([evidenceKey, field]) => {
    const value = declaration[field];
    if (typeof value !== 'boolean' || (key !== undefined && key !== evidenceKey)) return [];
    return [{
      key: evidenceKey,
      support: value ? 'supported' as const : 'unsupported' as const,
      source: 'relay_declaration' as const,
      grade: 'declared' as const,
      providerKind: 'relay',
      modelId: model.canonicalModelId ?? model.id,
      transport: effectiveTransport,
      scope: 'connection_model_transport' as const,
      ...relayIdentity,
    }];
  });
}

const OVERRIDE_KEYS = [
  ['vision_input', 'image'],
  ['tool_call', 'toolCall'],
] as const;

/**
  * Model-level overrides (user pick / "Test capabilities" measurement) and the tool negative cache: the highest sources for vision / tools,
  * overriding engine declarations and the remaining candidates. Overrides take priority over the negative cache; they also need the local identity and are not produced when absent (fail closed).
 */
function relayLocalFactCandidates(query: CapabilityTruthQuery): CapabilityEvidenceCandidate[] {
  const { provider, model, effectiveTransport, relayIdentity, key } = query;
  if (!relayIdentity || effectiveTransport === 'unknown') return [];
  const overrides = model.relayCapabilityOverrides;
  const base = {
    providerKind: 'relay',
    modelId: model.canonicalModelId ?? model.id,
    transport: effectiveTransport,
    scope: 'connection_model_transport' as const,
    ...relayIdentity,
  };
  return OVERRIDE_KEYS.flatMap(([evidenceKey, field]): CapabilityEvidenceCandidate[] => {
    if (key !== undefined && key !== evidenceKey) return [];
    const override = overrides?.[field];
    if (override && typeof override.value === 'boolean') {
      const tested = override.source === 'tested';
      return [{
        ...base,
        key: evidenceKey,
        support: override.value ? 'supported' : 'unsupported',
        source: tested ? 'relay_verification' : 'relay_declaration',
        grade: tested ? 'machine_verified' : 'declared',
      }];
    }
    // The vision negative cache only gates the entry point (attachment-policy) and does not change the evidence: before the rejection it was unknown anyway.
    if (field !== 'toolCall') return [];
    const cacheKey = {
      connectionId: provider.id,
      modelId: model.id,
      // Same protocol as the send side uses for writing keys (the first-send protocol).
      transport: relayFirstSendTransport(provider, model),
      kind: 'toolCall' as const,
    };
    if (!isRelayNegativeCached(cacheKey)) return [];
    return [{
      ...base,
      key: evidenceKey,
      support: 'unsupported',
      source: 'relay_verification',
      grade: 'observed',
    }];
  });
}

/**
 * Relay web truth (capability spec: RELAY x web; fixture web-probe.v1.json presentationCases truth):
 * user override web (user source) > a record valid for the effective fragment (stored, or the template when none is stored) on the first-send protocol (searched -> supported, rejected -> unsupported) > unknown.
 * The tested override is only a mirror of the record and does not count on its own; official web candidates from catalog matching do not count. Local engine connections have no web search and fall back to the existing rules.
 */
function relayWebCandidates(
  query: CapabilityTruthQuery,
  candidates: CapabilityEvidenceCandidate[],
): CapabilityEvidenceCandidate[] {
  const { provider, model, effectiveTransport, relayIdentity, key } = query;
  if (provider.relayRequested?.engineProfile) return candidates;
  if (key !== undefined && key !== 'web_search') return candidates;
  const rest = candidates.filter((candidate) => candidate.key !== 'web_search');
  if (!relayIdentity || effectiveTransport === 'unknown') return rest;
  const facts = relayWebModelOptionFacts(provider, model);
  const { truth } = resolveRelayWebPresentation(facts, null);
  if (truth === 'unknown') return rest;
  const byUser = facts.userOverride !== undefined;
  return [...rest, {
    key: 'web_search',
    support: truth,
    source: byUser ? 'relay_declaration' : 'relay_verification',
    grade: byUser ? 'declared' : 'observed',
    providerKind: 'relay',
    modelId: model.canonicalModelId ?? model.id,
    transport: effectiveTransport,
    scope: 'connection_model_transport',
    ...relayIdentity,
  }];
}

function withExclusive(
  candidates: CapabilityEvidenceCandidate[],
  exclusive: CapabilityEvidenceCandidate[],
): CapabilityEvidenceCandidate[] {
  if (exclusive.length === 0) return candidates;
  const keys = new Set(exclusive.map((candidate) => candidate.key));
  return [...candidates.filter((candidate) => !keys.has(candidate.key)), ...exclusive];
}

/**
  * After a Relay model matches the official catalog it reuses the same metadata criteria, only with a different scope.
  * Keys declared by the local engine belong exclusively to the declaration: the engine is the machine running this model, and its answer is more direct than catalog inference.
  * Model-level overrides and the tool negative cache then override the engine declaration.
 */
export const relayTruthAdapter: CapabilityTruthAdapter = {
  acceptsUnverifiedExplicitIntent: true,
  candidates: (query) => {
    const metadata = metadataTruthCandidates(query, relayCandidateScope(query.relayIdentity));
    const declared = withExclusive(metadata, engineDeclarationCandidates(query));
    return relayWebCandidates(query, withExclusive(declared, relayLocalFactCandidates(query)));
  },
};
