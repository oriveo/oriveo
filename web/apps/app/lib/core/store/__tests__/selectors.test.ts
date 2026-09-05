import { describe, expect, it } from 'vitest';
import type { Conversation, ChatMessage, Provider } from '@oriveo/shared';
import type { AppStore } from '../app-store';
import { defaultState } from '../app-store';
import {
  selectProviderStats,
  selectResolvedCatalog,
  selectConversationsByGroup,
  selectStreamingConversationIdSet,
} from '../selectors';

function makeMessage(overrides: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id: crypto.randomUUID(),
    role: 'assistant',
    text: 'Hello',
    providerKind: 'openRouter',
    providerName: 'OpenRouter',
    modelName: 'gpt-4o',
    estimatedCost: 0,
    state: 'delivered',
    createdAt: new Date().toISOString(),
    ...overrides,
  };
}

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: crypto.randomUUID(),
    title: 'Test Chat',
    hasCustomTitle: false,
    providerID: 'provider-1',
    modelID: 'gpt-4o',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

function makeState(conversations: Conversation[]): Pick<AppStore, 'conversations'> {
  return {
    ...defaultState,
    conversations,
  } as AppStore;
}

describe('selectProviderStats', () => {
  it('counts only conversations belonging to the target provider', () => {
    const state = makeState([
      makeConversation({ providerID: 'provider-1', estimatedCost: 1.25 }),
      makeConversation({ providerID: 'provider-2', estimatedCost: 9.99 }),
    ]);

    expect(selectProviderStats(state, 'provider-1')).toEqual({
      totalConversations: 1,
      totalMessages: 0,
      totalCost: 1.25,
    });
  });

  it('counts only delivered messages', () => {
    const state = makeState([
      makeConversation({
        providerID: 'provider-1',
        estimatedCost: 0.5,
        messages: [
          makeMessage({ state: 'delivered' }),
          makeMessage({ state: 'generating' }),
          makeMessage({ state: 'failed' }),
          makeMessage({ state: 'interrupted' }),
        ],
      }),
    ]);

    expect(selectProviderStats(state, 'provider-1')).toEqual({
      totalConversations: 1,
      totalMessages: 1,
      totalCost: 0.5,
    });
  });

  it('falls back to remoteMessageCount for the message count in summary state', () => {
    const state = makeState([
      makeConversation({
        providerID: 'provider-1',
        estimatedCost: 0.25,
        messages: [],
        remoteMessageCount: 7,
      }),
    ]);

    expect(selectProviderStats(state, 'provider-1')).toEqual({
      totalConversations: 1,
      totalMessages: 7,
      totalCost: 0.25,
    });
  });
});

/* ── Cache behavior lock ───────────────────────── */

function makeProvider(id: string): Provider {
  return {
    id,
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: '••',
  };
}

// A capacity of 16 covers 15 official providers plus Managed and Free, so all of them can
// be on screen at once, and ProviderList first reduces over every provider and then reads once per card.
describe('selectResolvedCatalog LRU(16)', () => {
  const LRU_MAX = 16;

  it('returns the same result reference from cache for the same provider reference', () => {
    const p = makeProvider('p-cache-1');
    const a = selectResolvedCatalog(p);
    const b = selectResolvedCatalog(p);
    expect(a).toBe(b);
  });

  it(`evicts the least recently used entry past ${LRU_MAX} distinct providers, recomputing into a new reference`, () => {
    const p1 = makeProvider('p-lru-1');
    const first = selectResolvedCatalog(p1);
    // Visit LRU_MAX more providers (LRU_MAX+1 including p1, so the oldest, p1, is evicted)
    for (let i = 2; i <= LRU_MAX + 1; i++) selectResolvedCatalog(makeProvider(`p-lru-${i}`));
    const afterEviction = selectResolvedCatalog(p1);
    expect(afterEviction).not.toBe(first);
  });

  it('keeps hitting the cache on repeated access within capacity, with no eviction', () => {
    const p = makeProvider('p-keep');
    const a = selectResolvedCatalog(p);
    // Visit LRU_MAX-1 more (LRU_MAX in total, within capacity)
    for (let i = 1; i <= LRU_MAX - 1; i++) selectResolvedCatalog(makeProvider(`p-keep-other-${i}`));
    expect(selectResolvedCatalog(p)).toBe(a);
  });

  // Regression: a full screen of providers (within 15 official plus Managed and Free) must
  // hit the cache throughout, which is what raising the capacity from 5 to 16 buys.
  it('keeps a full screen of 16 providers cached', () => {
    const providers = Array.from({ length: LRU_MAX }, (_, i) => makeProvider(`p-screen-${i}`));
    const firstPass = providers.map((p) => selectResolvedCatalog(p));
    providers.forEach((p, i) => expect(selectResolvedCatalog(p)).toBe(firstPass[i]));
  });
});

describe('selectConversationsByGroup memo', () => {
  it('returns the same result reference for the same conversations reference on the same day', () => {
    const state = makeState([makeConversation({ updatedAt: new Date().toISOString() })]);
    const r1 = selectConversationsByGroup(state as AppStore);
    const r2 = selectConversationsByGroup(state as AppStore);
    expect(r1).toBe(r2);
  });

  it('recomputes into a new reference when the conversations reference changes', () => {
    const today = new Date().toISOString();
    const r1 = selectConversationsByGroup(
      makeState([makeConversation({ updatedAt: today })]) as AppStore,
    );
    const r2 = selectConversationsByGroup(
      makeState([makeConversation({ updatedAt: today })]) as AppStore,
    );
    expect(r2).not.toBe(r1);
  });

  it('groups a conversation updated today under Today', () => {
    const groups = selectConversationsByGroup(
      makeState([makeConversation({ updatedAt: new Date().toISOString() })]) as AppStore,
    );
    expect(groups[0]?.label).toBe('Today');
    expect(groups[0]?.items).toHaveLength(1);
  });
});

describe('selectStreamingConversationIdSet', () => {
  it('converts to a Set with correct hits and misses', () => {
    const state = { ...defaultState, streamingConversationIds: ['a', 'b'] } as AppStore;
    const set = selectStreamingConversationIdSet(state);
    expect(set.has('a')).toBe(true);
    expect(set.has('c')).toBe(false);
  });

  it('keeps the Set reference stable while the underlying array reference is unchanged, so a token append does not trigger a re-render', () => {
    const ids = ['a', 'b'];
    const state = { ...defaultState, streamingConversationIds: ids } as AppStore;
    expect(selectStreamingConversationIdSet(state)).toBe(selectStreamingConversationIdSet(state));
  });

  it('produces a new Set when the underlying array reference changes, reflecting add and remove', () => {
    const s1 = selectStreamingConversationIdSet(
      { ...defaultState, streamingConversationIds: ['a'] } as AppStore,
    );
    const s2 = selectStreamingConversationIdSet(
      { ...defaultState, streamingConversationIds: ['a', 'b'] } as AppStore,
    );
    expect(s2).not.toBe(s1);
    expect(s2.has('b')).toBe(true);
  });
});
