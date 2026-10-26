import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Manual compaction entry:
 * - always an AI summary: with the preference off and the breaker tripped it still sends one summary request, saves kind=summary, and sends no chat request;
 * - feature switch off: no request is sent, saves kind=fallback.
 * Assertions read the request body the production Relay orchestration layer actually sent through transport.fetch and the row the coordinator actually saved.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  store: null as unknown,
  flags: {} as Record<string, boolean>,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store, tryGetVanillaStore: () => mocks.store }));
vi.mock('../../../../components/Toast', () => ({ showToast: vi.fn() }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../metadata/metadata-client')>();
  return {
    ...actual,
    isRuntimeFeatureEnabled: (key: string) => (key in mocks.flags ? mocks.flags[key] : actual.isRuntimeFeatureEnabled(key)),
  };
});

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest } from '../../metadata/metadata-client';
import { resetDBConnection } from '../../../infra/storage/idb';
import { setActiveUID } from '../../../infra/storage/partition';
import { deleteContextCheckpoints, listContextCheckpoints } from '../../../infra/storage/context-checkpoint-store';
import { CompactionBreakers, createCompactionCoordinator, type CompactionContext } from './compaction-coordinator';
import { compactConversationNow } from './manual-compaction';

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

const CONV = 'conv-ctx';

interface WireMessage { role: string; content: string | Array<{ type: string; text?: string }> }
const sentBodies: Array<{ messages: WireMessage[]; tools?: unknown }> = [];
const replyOf = (text: string) => new Response(
  [`data: ${JSON.stringify({ choices: [{ delta: { content: text } }] })}`, 'data: [DONE]'].map((f) => `${f}\n\n`).join(''),
  { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
);
const replies: string[] = [];
const VALID_SUMMARY = ['## Goal', 'g', '## Key Facts & Decisions', 'k', '## Work Produced', 'w', '## Open Threads', 'o',
  '## Style & Language', 's'].join('\n');

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

function textOf(message: WireMessage): string {
  return typeof message.content === 'string'
    ? message.content
    : message.content.filter((part) => part.type === 'text').map((part) => part.text ?? '').join('');
}

/** Trips the conversation breaker to fallbackOnly with two unqualified automatic compactions, then clears the two rows they saved. */
async function tripBreaker(conversationId: string) {
  const tiny: CompactionContext = {
    messages: Array.from({ length: 6 }, (_, i) => ({
      id: `t${i}`, role: i % 2 === 0 ? 'user' as const : 'assistant' as const, text: `t ${i}`, estTokens: 5000,
    })),
    B: 40000, U: 100000, prefixTokens: 500, rhoHi: 0.5, fixedTokens: 0, model: 'gpt-x',
  };
  const run = createCompactionCoordinator({
    context: () => tiny, summarize: async () => 'no headings here', aiSummaryEnabled: () => true, remoteEnabled: () => true,
  });
  const forget = async () => {
    const rows = await listContextCheckpoints(conversationId);
    await deleteContextCheckpoints(conversationId, rows.map((r) => r.checkpointId));
  };
  await run.compact(conversationId, 'preSend');
  await forget();
  await run.compact(conversationId, 'preSend');
  await forget();
  expect(CompactionBreakers.mode(conversationId)).toBe('fallbackOnly');
}

beforeEach(async () => {
  localStorage.clear();
  resetDBConnection();
  await clearAllDatabases();
  await setActiveUID('guest');
  CompactionBreakers.reset();
  sentBodies.length = 0;
  replies.length = 0;
  mocks.flags = {};
  __resetMetadataClientForTest();
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: {
        fetch: async (_url, init) => {
          sentBodies.push(JSON.parse(String(init.body)) as { messages: WireMessage[] });
          return replyOf(replies.shift() ?? 'ok');
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    }));
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('manual compaction', () => {
  it('manual_compaction_request_body_from_production', async () => {
    const store = newStore(history(22, 1600));
    store.setState({ preferences: { ...store.getState().preferences, contextAISummaryEnabled: false } });
    await tripBreaker(CONV);
    replies.push(VALID_SUMMARY);

    const result = await compactConversationNow(CONV);

    expect(result.outcome).toBe('summary');
    // Only one summary request is sent, no chat request.
    expect(sentBodies).toHaveLength(1);
    const body = sentBodies[0];
    const chat = body.messages.filter((m) => m.role !== 'system');
    const last = chat[chat.length - 1];
    expect(last.role).toBe('user');
    expect(textOf(last)).toContain('CONTEXT CHECKPOINT');
    expect('tools' in body).toBe(false);
    const rows = await listContextCheckpoints(CONV);
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe('summary');
    expect(rows[0].summary).toBe(VALID_SUMMARY);
    expect(result.row).toEqual(rows[0]);
  });

  it('manual_compaction_retains_media_messages_after_checkpoint', async () => {
    const plain = history(22, 1600);
    // Without media, how far the same history gets compacted: proves the media message really cuts the covered range.
    newStore(plain);
    replies.push(VALID_SUMMARY);
    const baseline = await compactConversationNow(CONV);
    expect(baseline.outcome).toBe('summary');
    const baselineCovered = baseline.row!.messagesCovered;

    localStorage.clear();
    resetDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
    CompactionBreakers.reset();
    sentBodies.length = 0;
    const mediaIndex = 8;
    expect(baselineCovered).toBeGreaterThan(mediaIndex);
    const messages = plain.map((message, index) => index === mediaIndex
      ? { ...message, attachments: [{ id: 'img', kind: 'image', fileName: 'cat.png', mimeType: 'image/png', base64Data: 'iVBORw0KGgo=' }] }
      : message) as ChatMessage[];
    newStore(messages);
    replies.push(VALID_SUMMARY);

    const result = await compactConversationNow(CONV);

    expect(result.outcome).toBe('summary');
    const rows = await listContextCheckpoints(CONV);
    expect(rows).toHaveLength(1);
    // The message with the image and the history after it are not covered; they stay as-is after the compaction result.
    expect(rows[0].messagesCovered).toBeLessThanOrEqual(mediaIndex);
    expect(messages.findIndex((m) => m.id === rows[0].coversTo)).toBeLessThan(mediaIndex);
    // The summary request contains neither this message's body nor its image placeholder.
    const requestText = sentBodies[0].messages.map(textOf).join('\n');
    expect(requestText).not.toContain('cat.png');
    expect(requestText).not.toContain(`question ${mediaIndex} `);
  });

  it('manual_compaction_flag_off_uses_fallback', async () => {
    newStore(history(22, 1600));
    mocks.flags = { context_compaction_enabled: false };

    const result = await compactConversationNow(CONV);

    expect(mocks.sendStream).not.toHaveBeenCalled();
    expect(sentBodies).toHaveLength(0);
    expect(result.outcome).toBe('fallback');
    const rows = await listContextCheckpoints(CONV);
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe('fallback');
    expect(result.row).toEqual(rows[0]);
  });

  it('manual_compaction_without_conversation_is_noop', async () => {
    newStore(history(4, 10));
    const result = await compactConversationNow('missing');
    expect(result).toEqual({ outcome: 'noop', failures: [] });
    expect(sentBodies).toHaveLength(0);
  });
});
