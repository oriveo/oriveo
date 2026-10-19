/**
 * Memory injection: with the conversation memory switch on, the injectable items of the local memory item slice (`MemoryItems.injectable`) are injected,
 * standing conventions first and the other memories after; memoryText is only dual-written for older clients and is no longer injected as a whole; anti-forget no longer appends a reminder.
 * The assertions cover the memory items production buildChatContextSources hands to the assembler.
 */
import { describe, it, expect, vi } from 'vitest';
import type { Conversation } from '@oriveo/shared';
import { MemoryItems, type MemoryItem, type MemoryItemInput } from '@oriveo/core/context/memory-items';

vi.mock('../../skills/knowledge-api', () => ({
  retrieveKnowledgeSnippets: vi.fn(),
  fetchKnowledgeRuntimeConfigCached: vi.fn(),
}));

import { createAppStore } from '../../store/app-store';
import { buildChatContextSources } from '../prompt-injection';

const CONV_ID = 'conv-memory';

function memoryItem(id: string, content: string, extra: Partial<MemoryItemInput> = {}): MemoryItem {
  return MemoryItems.canonical({
    id, kind: 'fact', content, mutationId: `${id}-m`, deviceId: 'device-test', createdAt: '2026-10-01T00:00:00.000Z', ...extra,
  });
}

function conversation(extra: Partial<Conversation> = {}): Conversation {
  return {
    id: CONV_ID, title: 'T', hasCustomTitle: false, providerID: 'p-1', modelID: 'm-1', providerKind: 'openAI',
    previewText: '', estimatedCost: 0, isDraft: false, messages: [], draftText: '',
    createdAt: '2026-10-15T00:00:00.000Z', updatedAt: '2026-10-15T00:00:00.000Z', ...extra,
  };
}

async function sourcesFor(
  items: MemoryItem[],
  conv: Conversation = conversation(),
  prefs: { memoryText?: string; memoryAntiForgetEnabled?: boolean; memoryAntiForgetText?: string } = {},
) {
  const store = createAppStore({ conversations: [conv] });
  store.setState({ preferences: { ...store.getState().preferences, ...prefs }, memoryItems: items });
  return buildChatContextSources(store, conv, 'hello');
}

describe('Memory injection', () => {
  it('items + useMemory default (undefined) -> injected', async () => {
    const fact = memoryItem('item-fact', 'I am a Go engineer');
    const sources = await sourcesFor([fact]);
    expect(sources.promptContext.memoryInjected).toBe(true);
    expect(sources.conversation.useMemory).toBe(true);
    expect(sources.memoryItems).toEqual([{ id: fact.id, kind: 'fact', content: 'I am a Go engineer', pinned: false }]);
  });

  it('items + useMemory = false -> not injected', async () => {
    const sources = await sourcesFor([memoryItem('item-fact', 'I am a Go engineer')], conversation({ useMemory: false }));
    expect(sources.promptContext.memoryInjected).toBe(false);
    expect(sources.memoryItems).toEqual([]);
  });

  it('memoryText is no longer injected as a whole when there are no items', async () => {
    const sources = await sourcesFor([], conversation(), { memoryText: 'I am a Go engineer' });
    expect(sources.promptContext.memoryInjected).toBe(false);
    expect(sources.memoryItems).toEqual([]);
  });

  it('standing conventions first, pinned first, other memories after', async () => {
    const fact = memoryItem('item-fact', 'Lives in Berlin.');
    const pinnedFact = memoryItem('item-pinned-fact', 'Has a cat.', { pinned: true });
    const instruction = memoryItem('item-instruction', 'Answer briefly.', { kind: 'instruction' });
    const sources = await sourcesFor([fact, pinnedFact, instruction]);
    expect(sources.memoryItems.map((m) => m.id)).toEqual([instruction.id, pinnedFact.id, fact.id]);
  });

  it('scope: this conversation and its folder are injected, other conversations / folders are not', async () => {
    const own = memoryItem('item-own', 'Own chat.', { scope: { type: 'conversation', id: CONV_ID } });
    const other = memoryItem('item-other', 'Other chat.', { scope: { type: 'conversation', id: 'conv-other' } });
    const folder = memoryItem('item-folder', 'Own folder.', { scope: { type: 'folder', id: 'folder-1' } });
    const otherFolder = memoryItem('item-folder-2', 'Other folder.', { scope: { type: 'folder', id: 'folder-2' } });
    const sources = await sourcesFor([own, other, folder, otherFolder], conversation({ folderID: 'folder-1' }));
    expect(sources.memoryItems.map((m) => m.id)).toEqual([own.id, folder.id]);
  });

  it('paused / expired / non-semantic layer / tombstoned items are not injected', async () => {
    const sources = await sourcesFor([
      memoryItem('item-paused', 'Paused.', { status: 'paused' }),
      memoryItem('item-expired', 'Expired.', { expiresAt: '2026-01-01T00:00:00.000Z' }),
      memoryItem('item-episodic', 'Episode.', { layer: 'episodic', kind: 'event' }),
      memoryItem('item-deleted', '', { status: 'deleted', deletedAt: '2026-10-02T00:00:00.000Z' }),
    ]);
    expect(sources.promptContext.memoryInjected).toBe(false);
    expect(sources.memoryItems).toEqual([]);
  });
});

// -- Anti-forget reminder is no longer injected --

describe('anti-forget reminder is no longer appended', () => {
  it('the anti-forget preference being on does not enter injection either', async () => {
    const fact = memoryItem('item-fact', 'I am an engineer');
    const sources = await sourcesFor([fact], conversation(), {
      memoryText: 'I am an engineer',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Prefer Go code',
    });
    expect(sources.memoryItems.map((m) => m.content)).toEqual(['I am an engineer']);
    expect(JSON.stringify(sources)).not.toContain('Prefer Go code');
    expect(JSON.stringify(sources)).not.toContain('[Reminder:');
  });
});
