import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Compaction UI presentation model and the store's delete-all / change subscription.
 * separator_from_production_fallback_row feeds the row that compactConversationNow actually saved.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { isValidQuoteContext, quoteGraphemeCount, type AIModel, type ChatMessage, type Provider } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({
  store: null as unknown,
  flags: {} as Record<string, boolean>,
}));

vi.mock('../../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store, tryGetVanillaStore: () => mocks.store }));
vi.mock('../../../../../components/Toast', () => ({ showToast: vi.fn() }));
vi.mock('../../../providers/service', () => ({ sendStream: vi.fn() }));
vi.mock('../../../metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../metadata/metadata-client')>();
  return {
    ...actual,
    isRuntimeFeatureEnabled: (key: string) => (key in mocks.flags ? mocks.flags[key] : actual.isRuntimeFeatureEnabled(key)),
  };
});

import { ContextBudget } from '@oriveo/core/context/budget';
import { createAppStore } from '../../../store/app-store';
import { __resetMetadataClientForTest } from '../../../metadata/metadata-client';
import { resetDBConnection } from '../../../../infra/storage/idb';
import { setActiveUID } from '../../../../infra/storage/partition';
import {
  type ContextCheckpointRow,
  deleteAllContextCheckpoints,
  listContextCheckpoints,
  putContextCheckpoint,
} from '../../../../infra/storage/context-checkpoint-store';
import { compactConversationNow, precompactIfNeeded } from '../../context-pipeline/manual-compaction';
import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import type { StreamOptions } from '@oriveo/core/providers/types';
import {
  CompactionBreakers,
  cancelCompaction,
  createCompactionCoordinator,
  isAICompacting,
  subscribeAICompacting,
  type CompactionContext,
  type CompactionCoordinatorDeps,
} from '../../context-pipeline/compaction-coordinator';
import { stopStream } from '../../stop-stream';
import { sendStream } from '../../../providers/service';
import {
  compactionDetailOf,
  compactionSeparatorOf,
  formatCompactCount,
} from '../context-compaction-presentation';
import { ContextCompactionStore } from '../context-compaction-store';
import {
  __resetCompactionHintForTest,
  buildSummaryQuote,
  clearCompaction,
  dismissCompactionHint,
  manualCompact,
  pendingCompactionHint,
  recompact,
  setPendingComposerQuote,
  subscribeCompactionHint,
  takePendingComposerQuote,
} from '../context-compaction-actions';

const model = {
  id: 'ctx-model', name: 'ctx-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
  contextLength: 20000, maxOutputTokens: 1000,
} as AIModel;
const provider = {
  id: 'relay-ctx', kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;

const CONV = 'conv-ui';
const RHO = 0.5;

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

function history(count: number, chars: number): ChatMessage[] {
  return Array.from({ length: count }, (_, i) => ({
    id: `m-${String(i).padStart(3, '0')}`,
    role: i % 2 === 0 ? 'user' : 'assistant',
    text: `${i % 2 === 0 ? 'question' : 'answer'} ${i} ${'x'.repeat(chars)}`,
    state: 'delivered',
    createdAt: new Date(Date.UTC(2026, 9, 15, 0, 0, i)).toISOString(),
  }) as ChatMessage);
}

function newStore(messages: ChatMessage[]) {
  const conv = {
    id: CONV, title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, providerKind: 'relay', previewText: '', estimatedCost: 0,
    isDraft: false, messages, draftText: '', updatedAt: '2026-10-15T00:00:00.000Z', createdAt: '2026-10-15T00:00:00.000Z',
  };
  const store = createAppStore({ providers: [provider], conversations: [conv as never] });
  mocks.store = store;
  return store;
}

function rowOf(overrides: Partial<ContextCheckpointRow>): ContextCheckpointRow {
  return {
    conversationId: CONV, checkpointId: 'cp-1', kind: 'summary', coversFrom: 'm-000', coversTo: 'm-005', coversDigest: 'd',
    messagesCovered: 6, userMessageIds: ['m-000', 'm-002', 'm-004'], text: 'CONTEXT CHECKPOINT\n## Goal\ng', summary: '## Goal\ng',
    language: 'en', model: 'gpt-x', packerVersion: '1', createdAt: 1_700_000_000_000, cost: 0.0123, ...overrides,
  };
}

beforeEach(async () => {
  localStorage.clear();
  resetDBConnection();
  await clearAllDatabases();
  await setActiveUID('guest');
  mocks.flags = {};
  __resetMetadataClientForTest();
  __resetCompactionHintForTest();
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('compaction separator', () => {
  it('separator_summary_fields', () => {
    const messages = history(10, 40);
    const row = rowOf({});
    const separator = compactionSeparatorOf(row, messages, RHO);
    const before = messages.slice(0, 6).reduce((sum, m) => sum + ContextBudget.estimateMessage(m.text, RHO), 0);
    expect(separator).toEqual({
      kind: 'summary', count: 6, before, after: ContextBudget.estimateMessage(row.text, RHO), kept: 3, model: 'gpt-x',
      anchorMessageId: 'm-005',
    });
    expect(formatCompactCount(12345, 'en')).toBe('12.3K');
  });

  it('separator_fallback_counts', () => {
    const messages = history(10, 40);
    const row = rowOf({ kind: 'fallback', coversTo: 'm-006', messagesCovered: 7, userMessageIds: ['m-004', 'm-006'], summary: null, cost: null });
    const separator = compactionSeparatorOf(row, messages, RHO);
    // Among the first 7 messages the assistant ones are m-001/003/005.
    expect(separator).toEqual({
      kind: 'fallback', count: 3, before: null, after: null, kept: 2, model: 'gpt-x', anchorMessageId: 'm-006',
    });
  });

  it('separator_fallback_count_ends_at_covers_to', () => {
    // One uncovered assistant message precedes the history: count walks back messagesCovered messages from coversTo
    const messages = history(10, 40);
    const row = rowOf({ kind: 'fallback', coversTo: 'm-006', messagesCovered: 7, userMessageIds: ['m-004', 'm-006'], summary: null, cost: null });
    const longer = [{ ...messages[1], id: 'extra-a' }, ...messages];
    // Among m-000..m-006 the assistant ones are m-001/003/005
    expect(compactionSeparatorOf(row, longer, RHO)?.count).toBe(3);
  });

  it('separator_hidden_without_visible_checkpoint', () => {
    const messages = history(4, 10);
    expect(compactionSeparatorOf(null, messages, RHO)).toBeNull();
    expect(compactionSeparatorOf(rowOf({ coversTo: 'not-loaded' }), messages, RHO)).toBeNull();
  });

  it('separator_before_ends_at_covers_to', () => {
    // Two uncovered messages precede the history: before walks back messagesCovered messages from coversTo
    const messages = history(10, 40);
    const row = rowOf({ coversFrom: 'm-002', coversTo: 'm-007', messagesCovered: 6 });
    const before = messages.slice(2, 8).reduce((sum, m) => sum + ContextBudget.estimateMessage(m.text, RHO), 0);
    expect(compactionSeparatorOf(row, messages, RHO)?.before).toBe(before);
    // Making the earlier messages longer does not change before either
    const longer = [
      { ...messages[0], id: 'extra-0', text: 'y'.repeat(4000) },
      ...messages,
    ];
    expect(compactionSeparatorOf(row, longer, RHO)?.before).toBe(before);
  });

  it('separator_from_production_fallback_row', async () => {
    const messages = history(22, 1600);
    newStore(messages);
    mocks.flags = { context_compaction_enabled: false };

    const result = await compactConversationNow(CONV);

    expect(result.outcome).toBe('fallback');
    const [row] = await listContextCheckpoints(CONV);
    expect(row.kind).toBe('fallback');
    const separator = compactionSeparatorOf(row, messages, RHO);
    const covered = messages.slice(0, row.messagesCovered);
    expect(separator).not.toBeNull();
    expect(separator?.count).toBe(covered.filter((m) => m.role === 'assistant').length);
    expect(separator?.count).toBeGreaterThan(0);
    expect(separator?.kept).toBe(row.userMessageIds.length);
    expect(separator?.anchorMessageId).toBe(row.coversTo);
    expect(compactionDetailOf(row).cost).toEqual({ kind: 'noExtraCost' });
  });
});

describe('compaction detail', () => {
  it('detail_cost_unavailable_when_null', () => {
    const detail = compactionDetailOf(rowOf({ cost: null }));
    expect(detail).toEqual({
      summary: '## Goal\ng', kept: 3, model: 'gpt-x', cost: { kind: 'unavailable' }, createdAt: 1_700_000_000_000,
    });
    expect(compactionDetailOf(rowOf({ cost: 0.5 })).cost).toEqual({ kind: 'amount', amount: 0.5 });
    expect(compactionDetailOf(rowOf({ summary: '' })).summary).toBeUndefined();
    expect(compactionDetailOf(rowOf({ kind: 'fallback', summary: null, cost: null })).cost).toEqual({ kind: 'noExtraCost' });
  });
});

describe('compaction store changes', () => {
  it('delete_all_returns_ids_and_notifies', async () => {
    await putContextCheckpoint(rowOf({ checkpointId: 'a', createdAt: 1 }));
    await putContextCheckpoint(rowOf({ checkpointId: 'b', createdAt: 2 }));
    await putContextCheckpoint(rowOf({ conversationId: 'other', checkpointId: 'c', createdAt: 3 }));
    const seen: string[] = [];
    const unsubscribe = ContextCompactionStore.subscribeCheckpointChanges((cid) => seen.push(cid));

    const ids = await ContextCompactionStore.deleteAll(CONV);

    expect([...ids].sort()).toEqual(['a', 'b']);
    expect(await listContextCheckpoints(CONV)).toEqual([]);
    expect(await listContextCheckpoints('other')).toHaveLength(1);
    await ContextCompactionStore.put(rowOf({ checkpointId: 'd' }));
    expect(seen).toEqual([CONV, CONV]);
    unsubscribe();
    expect(await deleteAllContextCheckpoints(CONV)).toEqual(['d']);
    await ContextCompactionStore.deleteAll(CONV);
    expect(seen).toEqual([CONV, CONV]);
  });
});

describe('compaction actions', () => {
  it('clear_deletes_all', async () => {
    newStore(history(22, 1600));
    mocks.flags = { context_compaction_enabled: false };
    await compactConversationNow(CONV);
    const before = (await listContextCheckpoints(CONV)).map((r) => r.checkpointId);
    expect(before.length).toBeGreaterThan(0);
    const seen: string[] = [];
    const unsubscribe = ContextCompactionStore.subscribeCheckpointChanges((cid) => seen.push(cid));

    const ids = await clearCompaction(CONV);

    unsubscribe();
    expect([...ids].sort()).toEqual([...before].sort());
    expect(await listContextCheckpoints(CONV)).toEqual([]);
    expect(seen).toEqual([CONV]);
  });

  it('recompact_drops_latest_then_manual', async () => {
    newStore(history(22, 1600));
    mocks.flags = { context_compaction_enabled: false };
    await compactConversationNow(CONV);
    const [latest] = await listContextCheckpoints(CONV);
    const seen: string[] = [];
    const unsubscribe = ContextCompactionStore.subscribeCheckpointChanges((cid) => seen.push(cid));

    const toast = await recompact(CONV, latest.checkpointId);

    unsubscribe();
    expect(toast).toBe('fallback');
    const rows = await listContextCheckpoints(CONV);
    expect(rows).toHaveLength(1);
    expect(rows[0].createdAt).toBeGreaterThanOrEqual(latest.createdAt);
    expect(rows[0].kind).toBe('fallback');
    // R is deleted once and the new row is saved once.
    expect(seen).toEqual([CONV, CONV]);
  });

  it('manual_result_toasts', async () => {
    newStore(history(22, 1600));
    mocks.flags = { context_compaction_enabled: false };
    expect(await manualCompact(CONV)).toBe('fallback');
    expect(await manualCompact('missing-conversation')).toBe('noop');
  });

  it('coordinator_writes_notify', async () => {
    newStore(history(22, 1600));
    mocks.flags = { context_compaction_enabled: false };
    const seen: string[] = [];
    const unsubscribe = ContextCompactionStore.subscribeCheckpointChanges((cid) => seen.push(cid));

    await compactConversationNow(CONV);
    expect(seen).toEqual([CONV]);

    unsubscribe();
  });
});

describe('third compaction hint and new chat quote', () => {
  it('third_compaction_hint_once', async () => {
    newStore(history(22, 1600));
    mocks.flags = { context_compaction_enabled: false };
    // Two old rows (digest mismatch, so they do not take part in latestValid); after the local compaction saves there are exactly 3.
    await putContextCheckpoint(rowOf({ checkpointId: 'cp-old-1' }));
    const hinted: Array<string | null> = [];
    const unsubscribe = subscribeCompactionHint(() => hinted.push(pendingCompactionHint()));

    // With only 1 old row there are 2 after saving: no hint.
    await putContextCheckpoint(rowOf({ conversationId: 'conv-other', checkpointId: 'cp-other' }));
    expect(pendingCompactionHint()).toBeNull();
    await putContextCheckpoint(rowOf({ checkpointId: 'cp-old-2' }));

    await compactConversationNow(CONV);
    const rows = await listContextCheckpoints(CONV);
    expect(rows).toHaveLength(3);
    expect(pendingCompactionHint()).toBe(CONV);
    expect(hinted).toEqual([CONV]);

    dismissCompactionHint();
    expect(pendingCompactionHint()).toBeNull();

    // Reaching 3 again within the same page lifetime: no hint again.
    const fresh = rows.find((r) => !r.checkpointId.startsWith('cp-old'));
    expect(fresh).toBeDefined();
    await recompact(CONV, fresh!.checkpointId);
    expect(await listContextCheckpoints(CONV)).toHaveLength(3);
    unsubscribe();
    expect(pendingCompactionHint()).toBeNull();
    expect(hinted).toEqual([CONV, null]);
  });

  it('new_chat_quote_from_summary', () => {
    const messages = history(10, 40);
    const row = rowOf({ summary: '## Goal\nship it' });
    const quote = buildSummaryQuote(row, 'Summary of earlier chat', messages);
    expect(quote).toEqual({
      schemaVersion: 1, sourceMessageId: 'm-005', sourceRole: 'assistant', contentKind: 'prose',
      leadingText: 'Summary of earlier chat', selectedText: '## Goal\nship it', trailingText: '', contextTruncated: false,
    });
    expect(isValidQuoteContext(quote)).toBe(true);

    // Over 8000 graphemes: the summary is tail-truncated.
    const long = buildSummaryQuote(rowOf({ summary: `HEAD${'s'.repeat(9000)}` }), 'Label', messages);
    expect(isValidQuoteContext(long)).toBe(true);
    expect(long?.selectedText.startsWith('HEAD')).toBe(true);
    expect(quoteGraphemeCount(`Label${long?.selectedText}`)).toBe(8000);
    expect(long?.contextTruncated).toBe(true);

    // Pending handoff: taken once when the new conversation mounts.
    setPendingComposerQuote('conv-new', quote!);
    expect(takePendingComposerQuote('conv-other')).toBeNull();
    expect(takePendingComposerQuote('conv-new')).toEqual(quote);
    expect(takePendingComposerQuote('conv-new')).toBeNull();
    // Before the first send of a new conversation there is no id: the one-shot slot without an id.
    setPendingComposerQuote(null, quote!);
    expect(takePendingComposerQuote('conv-new')).toBeNull();
    expect(takePendingComposerQuote(null)).toEqual(quote);
    expect(takePendingComposerQuote(null)).toBeNull();
  });

  it('new_chat_quote_from_fallback', async () => {
    const messages = history(22, 1600);
    newStore(messages);
    mocks.flags = { context_compaction_enabled: false };
    await compactConversationNow(CONV);
    const [row] = await listContextCheckpoints(CONV);
    expect(row.kind).toBe('fallback');
    expect(row.summary ?? '').toBe('');
    expect(row.userMessageIds.length).toBeGreaterThan(0);

    const quote = buildSummaryQuote(row, 'Label', messages);
    expect(isValidQuoteContext(quote)).toBe(true);
    expect(quote?.sourceMessageId).toBe(row.coversTo);
    expect(quote?.sourceRole).toBe('assistant');
    const kept = messages.filter((m) => row.userMessageIds.includes(m.id)).map((m) => m.text);
    const paragraphs = quote!.selectedText.split('\n\n');
    // By time, dropping from the oldest: what is kept is a suffix of kept.
    expect(paragraphs.length).toBeGreaterThan(0);
    expect(paragraphs).toEqual(kept.slice(kept.length - paragraphs.length));

    // Synthesized: three messages of 3000 graphemes each, the oldest one is dropped.
    const big = messages.map((m) => ({ id: m.id, text: `${m.id}:${'y'.repeat(2995)}` }));
    const synthetic = buildSummaryQuote(
      rowOf({ kind: 'fallback', summary: null, userMessageIds: ['m-004', 'm-000', 'm-002'] }), 'Label', big,
    );
    expect(synthetic?.selectedText.split('\n\n').map((p) => p.slice(0, 5))).toEqual(['m-002', 'm-004']);
    expect(synthetic?.contextTruncated).toBe(true);
    expect(isValidQuoteContext(synthetic)).toBe(true);

    // Only the newest one is still too long: truncate its tail instead of returning null.
    const huge = [
      { id: 'm-000', text: 'old' },
      { id: 'm-002', text: `HEAD${'z'.repeat(9000)}` },
    ];
    const tail = buildSummaryQuote(rowOf({ kind: 'fallback', summary: null, userMessageIds: ['m-000', 'm-002'] }), 'Label', huge);
    expect(tail).not.toBeNull();
    expect(isValidQuoteContext(tail)).toBe(true);
    expect(tail?.selectedText.startsWith('HEAD')).toBe(true);
    expect(tail?.selectedText.length).toBe(8_000 - 'Label'.length);
    expect(tail?.contextTruncated).toBe(true);
  });
});

describe('compaction in progress', () => {
  // B=40000: 5000 per message -> span = m1..m4, AI mode sends one summary call.
  const ctx = (): CompactionContext => ({
    messages: Array.from({ length: 6 }, (_, i) => ({
      id: `m${i + 1}`, role: i % 2 === 0 ? 'user' as const : 'assistant' as const, text: `turn ${i + 1}`, estTokens: 5000,
    })),
    B: 40000, U: 100000, prefixTokens: 500, rhoHi: 0.5, fixedTokens: 0, model: 'gpt-x',
  });

  /** The summary call hangs until the received signal is aborted. */
  function hangingSummarize() {
    const signals: AbortSignal[] = [];
    const summarize = vi.fn<CompactionCoordinatorDeps['summarize']>((_req, signal) => {
      signals.push(signal);
      return new Promise<string | null>((_resolve, reject) => {
        signal.addEventListener('abort', () => reject(new Error('aborted')));
      });
    });
    return { summarize, signals };
  }

  function aiCoordinator(summarize: CompactionCoordinatorDeps['summarize']) {
    return createCompactionCoordinator({ context: () => ctx(), summarize, aiSummaryEnabled: () => true, remoteEnabled: () => true });
  }

  beforeEach(() => {
    CompactionBreakers.reset();
  });

  it('compacting_state_and_cancel_falls_back', async () => {
    const { summarize, signals } = hangingSummarize();
    const states: Array<[string, boolean]> = [];
    const unsubscribe = subscribeAICompacting((cid) => states.push([cid, isAICompacting(cid)]));

    // preSend: cancel -> continue with the fallback, no failure counted
    const pending = aiCoordinator(summarize).compact(CONV, 'preSend');
    await vi.waitFor(() => expect(isAICompacting(CONV)).toBe(true));
    cancelCompaction(CONV);
    const result = await pending;
    expect(signals[0]?.aborted).toBe(true);
    expect(summarize).toHaveBeenCalledTimes(1);
    expect(result.outcome).toBe('fallback');
    expect(result.failures).toEqual([]);
    expect(isAICompacting(CONV)).toBe(false);
    expect(CompactionBreakers.state(CONV)).toEqual(CompactionBreakers.state('never-compacted'));
    expect((await listContextCheckpoints(CONV)).map((r) => r.kind)).toEqual(['fallback']);

    // Fallback mode skips the AI summary: it never enters "in progress"
    const fallbackOnly = createCompactionCoordinator({
      context: () => ctx(), summarize, aiSummaryEnabled: () => false, remoteEnabled: () => true,
    });
    expect((await fallbackOnly.compact('conv-fallback', 'preSend')).outcome).toBe('fallback');
    unsubscribe();
    expect(states).toEqual([[CONV, true], [CONV, false]]);

    // Manual: cancel saves nothing and shows no toast (via production compactConversationNow -> requestCompactionSummary -> sendStream)
    newStore(history(22, 1600));
    let streamAborted = false;
    vi.mocked(sendStream).mockImplementation(() => {
      let controller!: ReadableStreamDefaultController;
      return {
        stream: new ReadableStream({ start(c) { controller = c; } }),
        abort: () => { streamAborted = true; controller.error(new Error('aborted')); },
      } as unknown as ReturnType<typeof sendStream>;
    });
    const manual = manualCompact(CONV);
    await vi.waitFor(() => expect(isAICompacting(CONV)).toBe(true));
    cancelCompaction(CONV);
    expect(await manual).toBeNull();
    expect(streamAborted).toBe(true);
    expect(isAICompacting(CONV)).toBe(false);
    expect((await listContextCheckpoints(CONV)).map((r) => r.kind)).toEqual(['fallback']);
    vi.mocked(sendStream).mockReset();
  });

  it('stop_during_compaction_saves_nothing', async () => {
    const store = newStore(history(4, 10));
    const { summarize, signals } = hangingSummarize();

    // Stop button: stopStream aborts the in-progress compaction of this conversation (including the summary call); nothing is saved and no fallback runs
    const pending = aiCoordinator(summarize).compact(CONV, 'preSend');
    await vi.waitFor(() => expect(isAICompacting(CONV)).toBe(true));
    const conversation = store.getState().conversations.find((c) => c.id === CONV)!;
    stopStream(store, conversation, conversation.messages, '', null);
    const result = await pending;
    expect(signals[0]?.aborted).toBe(true);
    expect(result.outcome).toBe('noop');
    expect(result.row).toBeUndefined();
    expect(isAICompacting(CONV)).toBe(false);
    expect(await listContextCheckpoints(CONV)).toEqual([]);

    // Abort signal passed in by the send path: aborting likewise cancels the whole compaction and saves nothing
    const send = new AbortController();
    const second = aiCoordinator(summarize).compact(CONV, 'overflow', { signal: send.signal });
    await vi.waitFor(() => expect(isAICompacting(CONV)).toBe(true));
    send.abort();
    expect((await second).outcome).toBe('noop');
    expect(signals[1]?.aborted).toBe(true);
    expect(await listContextCheckpoints(CONV)).toEqual([]);

    // Already-aborted signal: no summary call, nothing saved
    const aborted = new AbortController();
    aborted.abort();
    expect((await aiCoordinator(summarize).compact(CONV, 'preSend', { signal: aborted.signal })).outcome).toBe('noop');
    expect(summarize).toHaveBeenCalledTimes(2);
    expect(await listContextCheckpoints(CONV)).toEqual([]);
  });
});

describe('precompaction on focus', () => {
  const VALID_SUMMARY = ['## Goal', 'g', '## Key Facts & Decisions', 'k', '## Work Produced', 'w', '## Open Threads', 'o',
    '## Style & Language', 's'].join('\n');
  const replyOf = (text: string) => new Response(
    [`data: ${JSON.stringify({ choices: [{ delta: { content: text } }] })}`, 'data: [DONE]'].map((f) => `${f}\n\n`).join(''),
    { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
  );
  let requests = 0;

  function aiStore(messages: ChatMessage[], aiSummary = true) {
    const store = newStore(messages);
    store.setState({ preferences: { ...store.getState().preferences, contextAISummaryEnabled: aiSummary } });
    return store;
  }

  beforeEach(() => {
    CompactionBreakers.reset();
    requests = 0;
    vi.mocked(sendStream).mockReset().mockImplementation(((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string,
      options: StreamOptions) => sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: { fetch: async () => { requests += 1; return replyOf(VALID_SUMMARY); } },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    })) as never);
  });

  afterEach(() => {
    vi.mocked(sendStream).mockReset();
  });

  it('precompaction_on_focus_ai_only', async () => {
    // AI mode and P̂ >= 0.75·B: two concurrent calls on the same conversation send one summary request and save
    aiStore(history(22, 1600));
    const [first, second] = await Promise.all([precompactIfNeeded(CONV), precompactIfNeeded(CONV)]);
    expect(requests).toBe(1);
    expect([first.outcome, second.outcome].sort()).toEqual(['noop', 'summary']);
    const rows = await listContextCheckpoints(CONV);
    expect(rows.map((r) => r.kind)).toEqual(['summary']);
    expect(rows[0].summary).toBe(VALID_SUMMARY);
    // After the just-saved row is applied P̂ drops: focusing again does not send
    expect((await precompactIfNeeded(CONV)).outcome).toBe('noop');
    expect(requests).toBe(1);
    await deleteAllContextCheckpoints(CONV);

    // Preference off (fallback mode): nothing sent, no fallback row saved
    aiStore(history(22, 1600), false);
    expect((await precompactIfNeeded(CONV)).outcome).toBe('noop');

    // Remote switch off: nothing sent
    aiStore(history(22, 1600));
    mocks.flags = { context_compaction_enabled: false };
    expect((await precompactIfNeeded(CONV)).outcome).toBe('noop');
    mocks.flags = {};

    // P̂ below 0.75·B: nothing sent
    aiStore(history(4, 10));
    expect((await precompactIfNeeded(CONV)).outcome).toBe('noop');

    // The same conversation already has a compaction in progress: nothing sent
    aiStore(history(22, 1600));
    const hanging = createCompactionCoordinator({
      context: () => ({
        messages: Array.from({ length: 6 }, (_, i) => ({
          id: `h${i}`, role: i % 2 === 0 ? 'user' as const : 'assistant' as const, text: `turn ${i}`, estTokens: 5000,
        })),
        B: 40000, U: 100000, prefixTokens: 500, rhoHi: 0.5, fixedTokens: 0, model: 'gpt-x',
      }),
      summarize: (_req, signal) => new Promise((_resolve, reject) => signal.addEventListener('abort', () => reject(new Error('aborted')))),
      aiSummaryEnabled: () => true,
      remoteEnabled: () => true,
    });
    const busy = hanging.compact(CONV, 'manual');
    await vi.waitFor(() => expect(isAICompacting(CONV)).toBe(true));
    expect((await precompactIfNeeded(CONV)).outcome).toBe('noop');
    cancelCompaction(CONV);
    await busy;

    expect(requests).toBe(1);
    expect(await listContextCheckpoints(CONV)).toEqual([]);
    expect(isAICompacting(CONV)).toBe(false);
  });
  it('send_waits_for_inflight_precompaction', async () => {
    // A pre-compaction summary call is hanging while the send path also needs compaction: wait for it to save, then re-judge with latestValid;
    // if P̂ is already < 0.90·B, use that row directly and send no second summary request.
    // B=40000: 8 messages of 5000 each -> P̂ = B >= 0.90·B, so the send path needs compaction.
    const sendCtx = (): CompactionContext => ({
      messages: Array.from({ length: 8 }, (_, i) => ({
        id: `s${i}`, role: i % 2 === 0 ? 'user' as const : 'assistant' as const, text: `turn ${i}`, estTokens: 5000,
      })),
      B: 40000, U: 100000, prefixTokens: 500, rhoHi: 0.5, fixedTokens: 0, model: 'gpt-x',
    });
    let release: () => void = () => {};
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const summarize = vi.fn<CompactionCoordinatorDeps['summarize']>(async () => {
      await gate;
      return VALID_SUMMARY;
    });
    const deps = { context: () => sendCtx(), summarize, aiSummaryEnabled: () => true, remoteEnabled: () => true };
    const pre = createCompactionCoordinator(deps).compact(CONV, 'preSend', { aiOnly: true });
    await vi.waitFor(() => expect(isAICompacting(CONV)).toBe(true));
    const send = createCompactionCoordinator(deps).compact(CONV, 'preSend');
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(summarize).toHaveBeenCalledTimes(1);
    release();
    const [preResult, sendResult] = await Promise.all([pre, send]);
    expect(preResult.outcome).toBe('summary');
    expect(summarize).toHaveBeenCalledTimes(1);
    expect(sendResult.row?.checkpointId).toBe(preResult.row?.checkpointId);
    expect((await listContextCheckpoints(CONV)).map((r) => r.kind)).toEqual(['summary']);
  });

  it('precompaction_failure_writes_no_fallback', async () => {
    // AI fails both attempts: returns noop, no fallback row is saved, the breaker still counts the failure
    vi.mocked(sendStream).mockReset().mockImplementation(((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string,
      options: StreamOptions) => sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: { fetch: async () => { requests += 1; return replyOf('not a checkpoint'); } },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    })) as never);
    aiStore(history(22, 1600));
    const breakerBefore = CompactionBreakers.state(CONV);
    expect((await precompactIfNeeded(CONV)).outcome).toBe('noop');
    expect(requests).toBe(2);
    expect(await listContextCheckpoints(CONV)).toEqual([]);
    expect(CompactionBreakers.state(CONV)).not.toEqual(breakerBefore);

    // Cancel the in-progress pre-compaction: returns noop, no fallback row is saved
    CompactionBreakers.reset();
    requests = 0;
    vi.mocked(sendStream).mockReset().mockImplementation(((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string,
      options: StreamOptions) => sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: {
        fetch: (_url, init) => {
          requests += 1;
          return new Promise<Response>((_resolve, reject) => {
            init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
          });
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    })) as never);
    aiStore(history(22, 1600));
    const pending = precompactIfNeeded(CONV);
    await vi.waitFor(() => expect(isAICompacting(CONV)).toBe(true));
    cancelCompaction(CONV);
    expect((await pending).outcome).toBe('noop');
    expect(requests).toBe(1);
    expect(await listContextCheckpoints(CONV)).toEqual([]);
  });
});
