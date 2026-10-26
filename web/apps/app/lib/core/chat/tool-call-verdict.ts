import type { AIModel, Provider } from '@oriveo/shared';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { ensurePersistedModelFacts, normalizeModelFactsID } from '../metadata/metadata-client';
import { resolvedEvidenceCatalog } from '../capability/truth/evidence-model';
import { providerFormOf } from '../capability/truth/provider-form';
import type { StreamOptions } from '../providers/types';
import { effectiveCapabilityTransport, resolveModelCapabilityEvidence } from './capability-evidence';
import { toolCallSupportIsRememberedFalse, type ToolCallRecoveryIdentity } from './capability-recovery-runtime';

/** Model id used in tool memory: relays use the literal ID, everything else the normalized canonical id. */
export function toolCallMemoryModelId(provider: Provider, model: AIModel): string {
  return normalizeModelFactsID(provider.kind === 'relay' ? model.id : model.canonicalModelId ?? model.id);
}

/**
 * tool_call verdict for non-Relay connections (tool-call-order.v1): first-party / catalog evidence >
 * remembered rejection (false only, revision must match) > modelFacts (only when the catalog misses) >
 * hand-entered local declaration > unknown = null (fail open). Sending, routing gates, the MCP switch and
 * capability badges all read this single verdict.
 */
export function officialToolCallVerdict(
  provider: Provider,
  model: AIModel,
  identity: ToolCallRecoveryIdentity,
): boolean | null {
  const support = resolveModelCapabilityEvidence({
    key: 'tool_call',
    provider,
    model,
    effectiveTransport: identity.finalTransport,
  }).support;
  // Catalog hit with definite evidence: catalog evidence outranks the remembered rejection.
  const catalogHit = resolvedEvidenceCatalog(provider, model).model !== null;
  if (catalogHit && support !== 'unknown') return support === 'supported';
  if (toolCallSupportIsRememberedFalse(identity)) return false;
  if (support === 'supported') return true;
  if (support === 'unsupported') return false;
  return null;
}

/** For read sites without a send context (routing gate / MCP switch / badge): uses the active account and effective transport group identity; non-Relay only. */
export function connectionToolCallVerdict(
  provider: Provider,
  model: AIModel,
  streamOptions?: StreamOptions,
): boolean | null {
  return officialToolCallVerdict(provider, model, {
    accountId: getActiveUIDSync(),
    connectionId: provider.id,
    authMode: provider.authMode ?? 'apiKey',
    canonicalModelId: toolCallMemoryModelId(provider, model),
    finalTransport: effectiveCapabilityTransport(provider, model, undefined, streamOptions),
  });
}

/**
 * Before sending: for models outside the catalog (hand-entered), first load the modelFacts revision from
 * local IDB, so a remembered rejection is not wrongly invalidated when the post-refresh background load
 * has not finished.
 */
export async function prepareToolCallVerdict(provider: Provider, model: AIModel): Promise<void> {
  if (providerFormOf(provider) === 'relay') return;
  if (resolvedEvidenceCatalog(provider, model).model !== null) return;
  await ensurePersistedModelFacts();
}
