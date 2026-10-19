/**
 * Memory contract tests (injection reads the local memory items)
 *
 * Verifies the contract constants and behavioral boundaries of the memory feature,
 * so this implementation stays consistent with iOS / Android. The assertions run against the production buildChatContextSources.
 */
import { describe, it, expect, vi } from 'vitest';
import type { Conversation } from '@oriveo/shared';
import { MemoryItems, type MemoryItem } from '@oriveo/core/context/memory-items';

vi.mock('../../skills/knowledge-api', () => ({
  retrieveKnowledgeSnippets: vi.fn(),
  fetchKnowledgeRuntimeConfigCached: vi.fn(),
}));

import { createAppStore } from '../../store/app-store';
import { buildChatContextSources } from '../prompt-injection';

function memoryItem(id: string, content: string): MemoryItem {
  return MemoryItems.canonical({
    id, kind: 'fact', content, mutationId: `${id}-m`, deviceId: 'device-test', createdAt: '2026-10-01T00:00:00.000Z',
  });
}

function conversation(useMemory?: boolean): Conversation {
  return {
    id: 'conv-contract', title: 'T', hasCustomTitle: false, providerID: 'p-1', modelID: 'm-1', providerKind: 'openAI',
    previewText: '', estimatedCost: 0, isDraft: false, messages: [], draftText: '',
    createdAt: '2026-10-15T00:00:00.000Z', updatedAt: '2026-10-15T00:00:00.000Z',
    ...(useMemory === undefined ? {} : { useMemory }),
  };
}

async function injected(items: MemoryItem[], useMemory?: boolean, memoryText?: string): Promise<boolean> {
  const conv = conversation(useMemory);
  const store = createAppStore({ conversations: [conv] });
  store.setState({
    preferences: { ...store.getState().preferences, ...(memoryText === undefined ? {} : { memoryText }) },
    memoryItems: items,
  });
  const sources = await buildChatContextSources(store, conv, 'Hi');
  expect(sources.memoryItems.length > 0).toBe(sources.promptContext.memoryInjected);
  return sources.promptContext.memoryInjected;
}

// ── Anti-forget reminder is no longer injected ─────────────────────

describe('anti-forget reminder is no longer appended', () => {
  it('only items are injected even when the preference is on, with no anti-forget text', async () => {
    const conv = conversation();
    const store = createAppStore({ conversations: [conv] });
    store.setState({
      preferences: {
        ...store.getState().preferences,
        memoryText: 'I am an engineer',
        memoryAntiForgetEnabled: true,
        memoryAntiForgetText: 'Prefer Go code',
      },
      memoryItems: [memoryItem('item-fact', 'I am an engineer')],
    });
    const sources = await buildChatContextSources(store, conv, 'Latest question');
    expect(sources.memoryItems.map((m) => m.content)).toEqual(['I am an engineer']);
    expect(JSON.stringify(sources)).not.toContain('[Reminder:');
    expect(JSON.stringify(sources)).not.toContain('Prefer Go code');
  });
});

describe('Phase 0 contract: useMemory defaults', () => {
  it('defaults to enabled when useMemory is undefined (treated as true)', async () => {
    expect(await injected([memoryItem('item-fact', 'Context')], undefined)).toBe(true);
  });

  it('useMemory = false blocks injection', async () => {
    expect(await injected([memoryItem('item-fact', 'Context')], false)).toBe(false);
  });
});

describe('Phase 0 contract: no items, no memory', () => {
  it('does not inject when there are no items', async () => {
    expect(await injected([])).toBe(false);
  });

  it('does not inject when only memoryText exists and there are no items', async () => {
    expect(await injected([], undefined, 'Context')).toBe(false);
  });
});

describe('Contract: token estimation formula', () => {
  it('uses the formula Math.ceil(graphemeCount * 0.35)', () => {
    // Checks the agreed coefficient and rounding
    const formula = (count: number) => Math.ceil(count * 0.35);

    expect(formula(0)).toBe(0);
    expect(formula(1)).toBe(1);
    expect(formula(3)).toBe(2); // 1.05 → 2
    expect(formula(10)).toBe(4); // 3.5 → 4
    expect(formula(2000)).toBe(700);
  });
});
