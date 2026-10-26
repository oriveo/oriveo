import type { Provider } from '@oriveo/shared';
import { getRelayRuntimeConfig, type RetiredModel } from '../metadata/metadata-client';
import { getProviderInstanceDisplayName } from '../providers/provider-display';
import { enrichRelayModelsByTransport } from '../providers/provider-selection-snapshot';
import { resolveRelayStoredModel } from '../providers/relay-model-identity';

/** The model stored in a relay conversation is no longer among that connection's enabled models. */
export interface ConversationModelRemoval {
  /** The model id stored in the conversation, kept as is and never rewritten. */
  modelID: string;
  /** Display name of the connection named in the notice bar. */
  connectionName: string;
}

/**
 * Whether the conversation model has been removed: only relay (including local engine) is checked; an empty conversation model does not count as removed (the fallback applies).
 * On removal nothing is silently substituted; the caller uses this to show the notice bar and block send / retry / continue / regenerate.
 */
export function resolveConversationModelRemoval(
  provider: Provider | undefined,
  conversationModelID: string | null | undefined,
): ConversationModelRemoval | null {
  if (!provider || provider.kind !== 'relay') return null;
  const modelID = conversationModelID?.trim();
  if (!modelID) return null;
  // Resolve with the same rule as the selection snapshot: a literal key hit, otherwise accept it when exactly one enabled model has a canonical equal to the stored value
  // (a canonical value stored before literal matching existed); several with the same canonical, or a dated stored value with only the base left, all count as removed.
  const enabledModels = enrichRelayModelsByTransport(provider, provider.models, getRelayRuntimeConfig());
  if (resolveRelayStoredModel(enabledModels, modelID)) return null;
  return { modelID, connectionName: getProviderInstanceDisplayName(provider) };
}

/** Catalog slice used by the retirement check (the catalog shape of fixture model-retired.v1). */
export interface RetirementCatalogModel {
  id: string;
  displayName?: string;
  lifecycle?: { state: string; shutdownAt?: string; routedTo?: string | null };
}

export interface RetirementCatalog {
  models: RetirementCatalogModel[];
  retiredModels?: RetiredModel[];
  resolveMap?: Record<string, string>;
  defaultModelId?: string;
}

export type ModelRetirementStatus = 'available' | 'retired' | 'missing';

export interface ModelRetirement {
  status: ModelRetirementStatus;
  /** Successor model for one-tap switching; given only when it is itself available at now. */
  successorId: string | null;
  displayName: string;
  /** Both retired and missing block sending. */
  sendBlocked: boolean;
  /** The conversation model is returned as is; the check never rewrites it. */
  modelId: string;
}

export interface ModelRetirementInput {
  /** null = catalog not loaded. */
  catalog: RetirementCatalog | null;
  /** Model ids enabled on this connection (including hand-entered ones). */
  userModels: readonly string[];
  conversation: { modelId: string; storedName?: string | null };
  now: string | Date;
}

function epochOf(now: string | Date): number {
  return now instanceof Date ? now.getTime() : Date.parse(now);
}

/** Contract section 8 rule (3): lifecycle=deprecated with shutdownAt <= now counts as retired. The selector's hiding uses the same check. */
export function isPastShutdown(model: RetirementCatalogModel, nowMs: number): boolean {
  const lifecycle = model.lifecycle;
  if (lifecycle?.state !== 'deprecated' || !lifecycle.shutdownAt) return false;
  const shutdownMs = Date.parse(lifecycle.shutdownAt);
  return Number.isFinite(shutdownMs) && shutdownMs <= nowMs;
}

/** A catalog model still available at now: in models[], not tombstoned, not past shutdownAt. */
function isLiveCatalogModel(catalog: RetirementCatalog, modelId: string, nowMs: number): boolean {
  if ((catalog.retiredModels ?? []).some((entry) => entry.id === modelId)) return false;
  const model = catalog.models.find((entry) => entry.id === modelId);
  return model !== undefined && !isPastShutdown(model, nowMs);
}

function successorOf(
  catalog: RetirementCatalog,
  routedTo: string | null | undefined,
  nowMs: number,
): string | null {
  return routedTo && isLiveCatalogModel(catalog, routedTo, nowMs) ? routedTo : null;
}

function statusOf(
  catalog: RetirementCatalog | null,
  userModels: readonly string[],
  modelId: string,
  nowMs: number,
): { status: ModelRetirementStatus; successorId: string | null } {
  // The order of checks follows the fixture $comment; the first hit wins.
  if (!catalog) return { status: 'available', successorId: null };
  const tombstone = (catalog.retiredModels ?? []).find((entry) => entry.id === modelId);
  if (tombstone) {
    return { status: 'retired', successorId: successorOf(catalog, tombstone.routedTo, nowMs) };
  }
  const model = catalog.models.find((entry) => entry.id === modelId);
  if (model && isPastShutdown(model, nowMs)) {
    return { status: 'retired', successorId: successorOf(catalog, model.lifecycle?.routedTo, nowMs) };
  }
  if (model) return { status: 'available', successorId: null };
  if (userModels.includes(modelId)) return { status: 'available', successorId: null };
  const canonical = catalog.resolveMap?.[modelId];
  if (canonical && catalog.models.some((entry) => entry.id === canonical)) {
    return { status: 'available', successorId: null };
  }
  return { status: 'missing', successorId: null };
}

/**
 * Retirement check for the conversation model of an official BYOK connection (contract section 8): returns the verdict only, writes no storage and does not modify the input.
 * Display name fallback: storedName -> catalog displayName -> tombstone displayName -> bare id.
 */
export function resolveModelRetirement(input: ModelRetirementInput): ModelRetirement {
  const { catalog, userModels, conversation } = input;
  const modelId = conversation.modelId;
  const { status, successorId } = statusOf(catalog, userModels, modelId, epochOf(input.now));
  const displayName = conversation.storedName?.trim()
    || catalog?.models.find((entry) => entry.id === modelId)?.displayName?.trim()
    || catalog?.retiredModels?.find((entry) => entry.id === modelId)?.displayName?.trim()
    || modelId;
  return { status, successorId, displayName, sendBlocked: status !== 'available', modelId };
}

