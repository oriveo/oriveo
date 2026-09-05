import type { Provider } from '@oriveo/shared';
import type { AppStore } from './app-store';
import {
  isVisibleConversation,
  sortConversationsByActivity,
} from '../../utils/conversation-list';
import {
  resolveProviderCatalog,
  type CatalogMetadataInput,
  type ResolvedProviderCatalog,
} from '../providers/catalog-resolver';
import { getMetadataSnapshot } from '../metadata/metadata-client';

/* ── Derived selectors ───────────────────────────────── */

export const selectActiveConversation = (s: AppStore) =>
  s.conversations.find((c) => c.id === s.activeConversationId) ?? null;

export const selectActiveProvider = (s: AppStore) => {
  const conversation = selectActiveConversation(s);
  if (!conversation) return null;
  return s.providers.find((p) => p.id === conversation.providerID) ?? null;
};

export const selectConnectedProviders = (s: AppStore) =>
  s.providers.filter((p) => p.status.kind === 'connected');

// Cache key = (conversations reference, epoch of local midnight). Memoizing on the
// conversations reference alone would freeze the time buckets (Today/Yesterday/...) at the
// first call and produce wrong groups after midnight. Including midnight lets the same
// conversations reference reuse the result within a day (stable reference, no consumer
// re-render) while a new day or a conversation change recomputes.
type ConversationGroupResult = { label: string; items: AppStore['conversations'] }[];
let _groupConvRef: AppStore['conversations'] | null = null;
let _groupTodayEpoch = -1;
let _groupResult: ConversationGroupResult | null = null;

export const selectConversationsByGroup = (s: AppStore): ConversationGroupResult => {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const todayEpoch = today.getTime();

  if (s.conversations === _groupConvRef && todayEpoch === _groupTodayEpoch && _groupResult) {
    return _groupResult;
  }

  const yesterday = new Date(todayEpoch - 86_400_000);
  const weekAgo = new Date(todayEpoch - 7 * 86_400_000);

  const groups: ConversationGroupResult = [
    { label: 'Today', items: [] },
    { label: 'Yesterday', items: [] },
    { label: 'This Week', items: [] },
    { label: 'Earlier', items: [] },
  ];

  const sorted = sortConversationsByActivity(
    s.conversations.filter(isVisibleConversation),
  );

  for (const c of sorted) {
    const d = new Date(c.updatedAt);
    if (d >= today) groups[0].items.push(c);
    else if (d >= yesterday) groups[1].items.push(c);
    else if (d >= weekAgo) groups[2].items.push(c);
    else groups[3].items.push(c);
  }

  const result = groups.filter((g) => g.items.length > 0);
  _groupConvRef = s.conversations;
  _groupTodayEpoch = todayEpoch;
  _groupResult = result;
  return result;
};

/* -- Streaming (multi-conversation) ----------------------------- */

/**
 * Current streaming partial text for a conversation. Returns '' when convId is missing or not streaming.
 * Returns a closure so it can be used as useAppStore(selectStreamingTextFor(id)).
 */
export const selectStreamingTextFor =
  (convId: string | undefined) =>
  (s: AppStore): string =>
    convId ? s.streamingTexts[convId] ?? '' : '';

/**
 * Current streaming reasoning partial for a conversation. Returns '' when convId is missing or not streaming.
 * Returns a primitive string with a stable identity, which is friendly to React.memo's shallow compare.
 * Tolerates a missing streamingReasoningTexts, as in a mocked store.
 */
export const makeSelectStreamingReasoningText =
  (convId: string | undefined) =>
  (s: AppStore): string =>
    convId ? s.streamingReasoningTexts?.[convId] ?? '' : '';

/**
 * Whether this conversation has received any reasoning event, an explicit "thinking started" signal.
 * Unlike [makeSelectStreamingReasoningText]: during long thinking the upstream only sends empty-string
 * heartbeats, so the text stays '' while thinking is genuinely in progress. The UI must light up
 * "Thinking..." from this boolean rather than from a non-empty text.
 * Returns a boolean primitive with a stable identity, friendly to React.memo.
 */
export const makeSelectStreamingReasoningActive =
  (convId: string | undefined) =>
  (s: AppStore): boolean =>
    convId ? s.streamingReasoningActive?.[convId] === true : false;

/** Resolve a conversation id from a streaming message.id (streamingMessageIds maps convId to msgId).
 *  Returns a string primitive with a stable identity, friendly to React.memo. */
export const makeSelectStreamingConvIdForMessage =
  (messageId: string, isStreaming: boolean) =>
  (s: AppStore): string | undefined => {
    if (!isStreaming) return undefined;
    const map = s.streamingMessageIds;
    if (!map) return undefined;
    for (const [convId, msgId] of Object.entries(map)) {
      if (msgId === messageId) return convId;
    }
    return undefined;
  };

/** Whether the conversation is streaming, i.e. a key is registered in streamingTexts. */
export const selectIsStreamingFor =
  (convId: string | undefined) =>
  (s: AppStore): boolean =>
    convId ? Object.prototype.hasOwnProperty.call(s.streamingTexts, convId) : false;

/** Whether any conversation is streaming, used by FreeStatusCard and other global checks. */
export const selectIsAnyStreaming = (s: AppStore): boolean =>
  s.streamingConversationIds.length > 0;

// Turn streamingConversationIds into a Set, memoized on the underlying array reference (which
// only changes on add/remove, not on token append; see streaming-slice). This takes
// ConversationGroup's per-conversation membership check from N x O(S) with .includes down to
// N x O(1) with .has, and keeps the Set reference stable so streaming never degrades identity.
let _streamingIdsArrayForSet: AppStore['streamingConversationIds'] | null = null;
let _streamingIdsSet: Set<string> | null = null;

/** Set of streaming conversation ids, for O(1) has() lookups; the reference tracks the underlying array. */
export const selectStreamingConversationIdSet = (s: AppStore): Set<string> => {
  if (s.streamingConversationIds !== _streamingIdsArrayForSet || !_streamingIdsSet) {
    _streamingIdsArrayForSet = s.streamingConversationIds;
    _streamingIdsSet = new Set(s.streamingConversationIds);
  }
  return _streamingIdsSet;
};

/** Ids of all currently streaming conversations; the array reference only changes on add/remove. */
export const selectStreamingConversationIds = (s: AppStore): string[] =>
  s.streamingConversationIds;

/* ── Provider stats (Phase 3.3) ────────────────────────── */

export function selectProviderStats(
  s: Pick<AppStore, 'conversations'>,
  providerId: string,
): { totalConversations: number; totalMessages: number; totalCost: number } {
  let totalConversations = 0;
  let totalMessages = 0;
  let totalCost = 0;

  for (const c of s.conversations) {
    if (c.providerID === providerId) {
      totalConversations++;
      totalMessages += c.messages.length > 0
        ? c.messages.filter((m) => m.state === 'delivered').length
        : (c.remoteMessageCount ?? 0);
      totalCost += c.estimatedCost;
    }
  }

  return { totalConversations, totalMessages, totalCost };
}

/* ── Resolved catalog ─────────────────────────────────── */

// LRU cache keyed by provider reference, reusing one metadata snapshot.
// A single-entry cache is repeatedly blown out by "one render walks many providers" screens such
// as ProviderList, where every selectResolvedCatalog(p) evicts the previous one and each provider
// is recomputed in full. An LRU keeps the providers visible on one screen resident, and the whole
// cache is invalidated when the metadata snapshot changes.
// 15 official providers plus Managed and Free can all appear on one screen. A size of 5 is too
// small: ProviderList first reduces over every provider to compute totalAvailableModels, which
// leaves only the last 5 in the cache, and then every card misses again, so the whole page
// recomputes (the openRouter catalog alone takes roughly 1-2ms).
const RESOLVED_CATALOG_LRU_MAX = 16;
let _resolvedCatalogSnapshot: CatalogMetadataInput | null = null;
// Map iteration order is insertion order: on a hit, delete+set moves the entry to the end (most recently used) and the first entry is dropped when over capacity.
const _resolvedCatalogLru = new Map<Provider, ResolvedProviderCatalog>();

/** Resolve a provider's full model catalog against the current metadata cache. */
export function selectResolvedCatalog(provider: Provider): ResolvedProviderCatalog {
  const snapshot = getMetadataSnapshot() as CatalogMetadataInput | null;
  if (snapshot !== _resolvedCatalogSnapshot) {
    _resolvedCatalogSnapshot = snapshot;
    _resolvedCatalogLru.clear();
  }

  const cached = _resolvedCatalogLru.get(provider);
  if (cached) {
    // Hit: refresh it as most recently used.
    _resolvedCatalogLru.delete(provider);
    _resolvedCatalogLru.set(provider, cached);
    return cached;
  }

  const result = resolveProviderCatalog(provider, snapshot);
  _resolvedCatalogLru.set(provider, result);
  if (_resolvedCatalogLru.size > RESOLVED_CATALOG_LRU_MAX) {
    const oldest = _resolvedCatalogLru.keys().next().value;
    if (oldest !== undefined) _resolvedCatalogLru.delete(oldest);
  }
  return result;
}
