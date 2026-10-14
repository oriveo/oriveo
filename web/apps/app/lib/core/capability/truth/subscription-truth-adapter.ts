import type { AIModel, Provider, ReasoningMode } from '@oriveo/shared';
import type { CapabilityEvidenceCandidate } from '@oriveo/core/providers/capability-evidence-facade';
import { codexReasoningEffort } from '@oriveo/core/providers/openai-subscription';
import {
  getModelFacts,
  getModelFactsRevision,
  subscriptionDeclaredReasoningLevels,
} from '../../metadata/metadata-client';
import type { CapabilityTruthAdapter, CapabilityTruthQuery } from './capability-truth-adapter';

type SubscriptionTruthKey = 'web_search' | 'vision_input' | 'tool_call' | `reasoning_level/${string}`;

const REASONING_MODES: readonly ReasoningMode[] = ['fast', 'balanced', 'deep', 'max'];

/** Keys governed by the snapshot: vision, web, reasoning tiers. `tool_call` is not governed by the snapshot (upstream declaration > model-facts dictionary). */
function snapshotGoverns(key: string): boolean {
  return key === 'vision_input' || key === 'web_search' || key.startsWith('reasoning_level/');
}

/**
  * Subscription snapshot: the per-model declarations of upstream `/models`, attached to AIModel through the production mapping.
  * Web's subscription sync (`provider-sync.ts` / `ProviderSetup`) writes it into `provider.models` and clears
  * `catalogModels`, so when `catalogModels` is empty the snapshot is in `models`; only when both are empty is it "not fetched".
 */
function subscriptionSnapshot(provider: Provider): AIModel[] {
  if (provider.catalogModels?.length) return provider.catalogModels;
  return provider.models ?? [];
}

/**
  * Capability truth of subscription (Codex / Grok logged-in account) models: reads only the locally fetched upstream `/models` snapshot and the
  * `model-facts` dictionary, with no network access and no credential reads.
 *
  * - Empty snapshot -> no candidates; the projection fails closed.
  * - Snapshot present but model absent -> vision_input / web_search / reasoning_level/* each yield `catalog_absent`.
  * - Model present: vision / web copy the upstream capability bits; reasoning tiers use the same `codexReasoningEffort` filter as outbound
  *   (every tier shown in the UI maps to a value upstream really accepts).
  * - `tool_call` is not governed by the snapshot: first-hand upstream boolean declaration > `model-facts` dictionary > no candidate, independent of snapshot state
  *   (subscription column: upstream_declaration > model_facts).
 */
export function subscriptionTruthCandidates(
  query: Pick<CapabilityTruthQuery, 'provider' | 'model' | 'effectiveTransport'>,
  keys?: readonly SubscriptionTruthKey[],
): CapabilityEvidenceCandidate[] {
  const { provider, model, effectiveTransport } = query;
  // Facts bound to a transport cannot match an unknown transport.
  if (effectiveTransport === 'unknown') return [];
  const snapshot = subscriptionSnapshot(provider);
  const catalogModel = snapshot.find((item) => item.id === model.id);
  const identity = {
    scope: 'provider_model_transport' as const,
    providerKind: provider.kind,
    modelId: model.id,
    transport: effectiveTransport,
  };
  const declaredBase = {
    ...identity,
    source: 'upstream_declaration' as const,
    grade: 'declared' as const,
  };
  const wanted = (key: string) => !keys || keys.includes(key as SubscriptionTruthKey);
  const candidates: CapabilityEvidenceCandidate[] = [];

  // tool_call is independent of snapshot state: a first-hand boolean declaration in the snapshot beats the persisted models.dev snapshot,
  // and only when neither exists is no candidate produced (open-world, explicit intent may allow it).
  if (wanted('tool_call')) {
    const declaredToolCall = catalogModel?.toolCall;
    if (typeof declaredToolCall === 'boolean') {
      candidates.push({
        ...declaredBase,
        key: 'tool_call',
        support: declaredToolCall ? 'supported' : 'unsupported',
        evidenceRevision: 'subscription',
      });
    } else {
      const facts = getModelFacts(provider.kind, model.id)
        ?? (model.canonicalModelId ? getModelFacts(provider.kind, model.canonicalModelId) : undefined);
      if (typeof facts?.toolCall === 'boolean') {
        candidates.push({
          ...identity,
          key: 'tool_call',
          support: facts.toolCall ? 'supported' : 'unsupported',
          source: 'model_facts',
          grade: 'declared',
          evidenceRevision: getModelFactsRevision(),
        });
      }
    }
  }
  // State 1: the snapshot is not fetched, so keys governed by the catalog yield no candidate (the projection pins fail-closed via failsClosed).
  if (snapshot.length === 0) return candidates;
  // catalog_absent is not a graded fact: the grade of both the candidate and the ruling is none (same shape on all three clients).
  const absent = (key: string): CapabilityEvidenceCandidate => ({
    ...identity, key, support: 'unknown', source: 'catalog_absent', grade: 'none',
  });
  const declared = (key: string, capability: 'image' | 'web'): CapabilityEvidenceCandidate => (
    !catalogModel ? absent(key)
      : { ...declaredBase, key, support: catalogModel.capabilities.includes(capability) ? 'supported' : 'unsupported' }
  );

  if (wanted('vision_input')) candidates.push(declared('vision_input', 'image'));
  if (wanted('web_search')) candidates.push(declared('web_search', 'web'));

  const levels = catalogModel ? subscriptionDeclaredReasoningLevels(provider.kind, catalogModel) : [];
  // With a non-empty first-hand declaration the source is the upstream declaration; when falling to the model-facts dictionary (including when neither exists) the source is the dictionary.
  const reasoningSource = catalogModel?.upstreamReasoningLevels?.length ? 'upstream_declaration' : 'model_facts';
  for (const mode of REASONING_MODES) {
    const key = `reasoning_level/${mode}`;
    if (!wanted(key)) continue;
    if (!catalogModel) {
      candidates.push(absent(key));
      continue;
    }
    candidates.push({
      ...identity,
      key,
      support: codexReasoningEffort(mode, levels) !== undefined ? 'supported' : 'unsupported',
      source: reasoningSource,
      grade: 'declared',
    });
  }
  return candidates;
}

/**
  * Subscription is open-world: a key the upstream does not declare does not mean it is not offered; with no candidate the user's explicit intent may still allow it
  * (rulings D0/D1), consistent with the semantics of going through the official adapter before the split. The only exception is state 1: when the snapshot has not been fetched,
  * the identity of keys governed by the catalog is incomplete, and explicit intent does not allow them either.
 */
export const subscriptionTruthAdapter: CapabilityTruthAdapter = {
  acceptsUnverifiedExplicitIntent: true,
  failsClosed: ({ provider, key }) => key !== undefined && snapshotGoverns(key)
    && subscriptionSnapshot(provider).length === 0,
  candidates: (query) => subscriptionTruthCandidates(query, query.key ? [query.key] : undefined),
};
