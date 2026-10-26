// @vitest-environment jsdom
/**
 * "Set as instruction" suggestion bar: the detection module + the production sendMessage handing off to detection.
 * After a new user send at the same place, memory candidates are generated in the background.
 * A new send is routed by propose_memory mode; in tool mode the v1 memory routing does not run.
 * Propose v3: in tool mode the instruction bar only comes from the model's instruct outcome; the fallback-route lexical bar only honors suggestionLanguages.
 */
import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Conversation, Provider } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  readStream: vi.fn(),
}));

vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../../../utils/chat-stream-utils', async () => ({
  ...await vi.importActual<typeof import('../../../../utils/chat-stream-utils')>('../../../../utils/chat-stream-utils'),
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
  readStream: (...args: unknown[]) => mocks.readStream(...args),
}));
vi.mock('../../../usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../../usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../../sync-port', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../../skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));
vi.mock('../../../metadata/metadata-client', async () => ({
  ...await vi.importActual<typeof import('../../../metadata/metadata-client')>('../../../metadata/metadata-client'),
  getMetadataRevision: () => undefined,
  getCapabilityRuntime: () => null,
  resolveGenerationProfileRef: vi.fn(() => undefined),
  resolveCatalogModel: vi.fn(),
  getDeclaredReasoningLevels: vi.fn(() => []),
  getDeclaredReasoningDefaultLevel: vi.fn(() => undefined),
  getRelayRuntimeConfig: vi.fn(() => null),
}));

import { detectDirective } from '@oriveo/core/context/directive-detector';
import { resetDBConnection } from '../../../../infra/storage/idb';
import { getActiveUIDSync } from '../../../../infra/storage/partition';
import { setPreference } from '../../../../infra/storage/preferences';
import { createMemoryCandidateRepository } from '../../../memory/memory-candidate-repository';
import { createMemoryItemRepository } from '../../../memory/memory-item-repository';
import { createAppStore } from '../../../store/app-store';
import { sendMessage } from '../../operations';
import {
  __resetDirectiveSuggestionForTest,
  acceptDirectiveSuggestion,
  evaluateDirectiveSuggestion,
  getDirectiveSuggestionIgnoreCount,
  getPendingDirectiveSuggestion,
  ignoreDirectiveSuggestion,
  offerInstructSuggestion,
} from '../directive-suggestion';
import { __resetMemorySuggestionForTest, beginMemorySuggestion, getPendingMemorySuggestion } from '../memory-suggestion';
import {
  __resetProposeMemoryDegradedForTest,
  markProposeMemoryDegraded,
  resolveProposeMemoryMode,
} from '../../propose-memory-runtime';

// The fallback-route lexical bar only honors suggestionLanguages (propose v3), so the fixture sentence is zh-Hans.
const DIRECTIVE = '\u4ee5\u540e\u6bcf\u6b21\u56de\u7b54\u90fd\u5148\u7ed9\u7ed3\u8bba';
const EN_DIRECTIVE = 'From now on, always reply in English.';

const PROPOSE_V3 = JSON.parse(readFileSync(
  resolve(__dirname, '../../../../../../../../shared/context-contracts/memory-propose.v3.json'), 'utf8',
)) as { instructBarCases: Array<{ id: string; sentence: string; instructions: string; ignoreCount: number; expected: { show: boolean } }> };

const provider = {
  id: 'p-1', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-test', apiKeyPreview: '••test',
} as unknown as Provider;
const model = {
  id: 'gpt-4', name: 'GPT-4', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: 'standard',
} as AIModel;

function conversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'conv-1', title: 'T', hasCustomTitle: false, providerID: 'p-1', providerKind: 'openAI', modelID: 'gpt-4', previewText: '',
    estimatedCost: 0, isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-15T00:00:00.000Z', ...overrides,
  } as Conversation;
}

function expectedSentence(): string {
  const d = detectDirective(DIRECTIVE);
  if (!d.isDirective) throw new Error('fixture is not a directive');
  return d.span.trim() || DIRECTIVE.trim();
}

function evaluate(conversationId = 'conv-1', instructions = '', messageId = 'm-1') {
  return evaluateDirectiveSuggestion({ conversationId, messageId, text: DIRECTIVE, instructions });
}

async function clearAllDatabases() {
  for (const db of await indexedDB.databases()) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

beforeEach(async () => {
  resetDBConnection();
  await clearAllDatabases();
  localStorage.clear();
  __resetDirectiveSuggestionForTest();
  __resetMemorySuggestionForTest();
  __resetProposeMemoryDegradedForTest();
  mocks.sendStream.mockReset();
  mocks.readStream.mockReset();
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hi' }]);
  mocks.sendStream.mockReturnValue({ stream: {} as ReadableStream, abort: vi.fn() });
  mocks.readStream.mockResolvedValue({ fullText: 'ok', reasoningText: '', usage: undefined, imageAttachments: [], toolCalls: [] });
});

describe('directive suggestion', () => {
  it('suggestion_shown_for_directive_message', async () => {
    // Tool mode does not run the lexical route (propose v3); this connection is already degraded, so fallback uses the lexical bar.
    markProposeMemoryDegraded('p-1', 'gpt-4');
    const conv = conversation();
    const store = createAppStore({ providers: [provider], conversations: [conv] });
    const ctx = { store, appendChunk: vi.fn(), te: (key: string) => key };
    const handle = sendMessage(ctx, {
      text: DIRECTIVE, prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
    });
    await handle.done;

    const userMsg = store.getState().conversations[0].messages.find((m) => m.role === 'user')!;
    expect(getPendingDirectiveSuggestion()).toEqual({
      conversationId: 'conv-1', messageId: userMsg.id, sentence: expectedSentence(),
    });

    // A non-instruction new message clears the pending one and does not count as ignored.
    await sendMessage(ctx, {
      text: 'What is the weather like?', prevMessages: store.getState().conversations[0].messages, conversation: conv,
      provider, model, reasoningMode: 'automatic',
    }).done;
    expect(getPendingDirectiveSuggestion()).toBeNull();
    expect(getDirectiveSuggestionIgnoreCount('conv-1')).toBe(0);

    // Regeneration is not evaluated.
    await sendMessage(ctx, {
      text: DIRECTIVE, prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
      attemptKind: 'regenerate',
    }).done;
    expect(getPendingDirectiveSuggestion()).toBeNull();

    // First send of a new conversation: use the id after the conversation is created.
    const fresh = sendMessage(ctx, {
      text: DIRECTIVE, prevMessages: [], conversation: undefined, provider, model, reasoningMode: 'automatic',
    });
    await fresh.done;
    expect(getPendingDirectiveSuggestion()?.conversationId).toBe(fresh.convId);
  });

  it('suggestion_not_shown_after_three_ignores', () => {
    for (let i = 0; i < 3; i += 1) {
      expect(evaluate('conv-1', '', `m-${i}`)).not.toBeNull();
      ignoreDirectiveSuggestion();
    }
    expect(getDirectiveSuggestionIgnoreCount('conv-1')).toBe(3);
    expect(evaluate('conv-1', '', 'm-4')).toBeNull();
    expect(getPendingDirectiveSuggestion()).toBeNull();
    // Counted per conversation.
    expect(evaluate('conv-2', '', 'm-5')).not.toBeNull();
  });

  it('suggestion_accept_appends_and_undo_restores', () => {
    const store = createAppStore({ providers: [provider], conversations: [conversation({ instructions: 'Be concise.' })] });
    expect(evaluate('conv-1', 'Be concise.')).not.toBeNull();
    const undo = acceptDirectiveSuggestion(store);
    expect(store.getState().conversations[0].instructions).toBe(`Be concise.\n${expectedSentence()}`);
    expect(getPendingDirectiveSuggestion()).toBeNull();
    undo?.();
    expect(store.getState().conversations[0].instructions).toBe('Be concise.');

    // With empty instructions, appending is just the original sentence.
    const empty = createAppStore({ providers: [provider], conversations: [conversation()] });
    evaluate('conv-1', '');
    acceptDirectiveSuggestion(empty);
    expect(empty.getState().conversations[0].instructions).toBe(expectedSentence());
  });

  it('suggestion_sentence_trims_unicode_white_space_and_keeps_bom', () => {
    // The lexical sentence is trimmed by Unicode White_Space: U+FEFF is not in it, so it is kept next to the directive (String.prototype.trim would strip it).
    // The detector itself does not treat a leading U+FEFF as a directive, so the trailing side is the one that reaches trim.
    const text = `${DIRECTIVE}\uFEFF`;
    expect(detectDirective(text)).toMatchObject({ isDirective: true, span: text });
    const suggestion = evaluateDirectiveSuggestion({ conversationId: 'conv-1', messageId: 'm-bom', text, instructions: '' });
    expect(suggestion?.sentence).toBe(`${DIRECTIVE}\uFEFF`);
  });

  it('suggestion_skipped_when_already_in_instructions', () => {
    expect(evaluate('conv-1', `Be concise.\n${expectedSentence()}`)).toBeNull();
    expect(getPendingDirectiveSuggestion()).toBeNull();
    // Not shown even after appending exceeds 8000 code points.
    expect(evaluate('conv-1', 'x'.repeat(8000))).toBeNull();
  });

  it('suggestion_accept_resets_ignore_streak', () => {
    const store = createAppStore({ providers: [provider], conversations: [conversation()] });
    evaluate('conv-1', '', 'm-1');
    ignoreDirectiveSuggestion();
    evaluate('conv-1', '', 'm-2');
    ignoreDirectiveSuggestion();
    expect(getDirectiveSuggestionIgnoreCount('conv-1')).toBe(2);
    evaluate('conv-1', '', 'm-3');
    acceptDirectiveSuggestion(store);
    expect(getDirectiveSuggestionIgnoreCount('conv-1')).toBe(0);
    evaluate('conv-1', '', 'm-4');
    ignoreDirectiveSuggestion();
    evaluate('conv-1', '', 'm-5');
    ignoreDirectiveSuggestion();
    expect(evaluate('conv-1', '', 'm-6')).not.toBeNull();
  });

  it('memory_candidate_generated_on_fresh_send', async () => {
    const REMEMBER = '\u8bb0\u4f4f\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54';
    const conv = conversation({ folderID: 'folder-1' } as Partial<Conversation>);
    const off = conversation({ id: 'conv-off', useMemory: false });
    const store = createAppStore({ providers: [provider], conversations: [conv, off] });
    const ctx = { store, appendChunk: vi.fn(), te: (key: string) => key };
    // This connection is already downgraded -> fallback: v1 memory routing as before.
    markProposeMemoryDegraded('p-1', 'gpt-4');
    const uid = getActiveUIDSync();
    const candidates = createMemoryCandidateRepository({
      uid,
      items: createMemoryItemRepository({ store, uid, deviceId: 'device-test', sync: () => null }),
    });

    // Regeneration and conversation useMemory=false do not generate.
    await sendMessage(ctx, {
      text: REMEMBER, prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
      attemptKind: 'regenerate',
    }).done;
    await sendMessage(ctx, {
      text: REMEMBER, prevMessages: [], conversation: off, provider, model, reasoningMode: 'automatic',
    }).done;

    // New user send: the repository actually stores one pending entry pointing at that user message.
    await sendMessage(ctx, {
      text: REMEMBER, prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
    }).done;
    const userMsgs = store.getState().conversations.find((c) => c.id === 'conv-1')!.messages.filter((m) => m.role === 'user');
    const fresh = userMsgs[userMsgs.length - 1];
    await vi.waitFor(async () => expect(await candidates.pending()).toHaveLength(1));
    const [pending] = await candidates.pending();
    expect(pending).toMatchObject({
      status: 'pending',
      source: { type: 'conversation', conversationId: 'conv-1', messageIds: [fresh.id] },
      scope: { type: 'folder', id: 'folder-1' },
    });
  });
});

describe('propose memory mode', () => {
  const REMEMBER = '\u8bb0\u4f4f\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54';

  it('attaches tools on a new send when tools are available', async () => {
    const conv = conversation();
    const store = createAppStore({ providers: [provider], conversations: [conv] });
    const ctx = { store, appendChunk: vi.fn(), te: (key: string) => key };
    const uid = getActiveUIDSync();
    const candidates = createMemoryCandidateRepository({
      uid,
      items: createMemoryItemRepository({ store, uid, deviceId: 'device-test', sync: () => null }),
    });
    expect(resolveProposeMemoryMode({ store, conversationId: 'conv-1', provider, model, freshSend: true })).toBe('tool');

    await sendMessage(ctx, {
      text: REMEMBER, prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
    }).done;
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(await candidates.pending()).toEqual([]);
    expect(getPendingMemorySuggestion()).toBeNull();

    // Propose v3: tool mode does not run the lexical instruction bar; no bar unless the model calls the tool.
    await sendMessage(ctx, {
      text: DIRECTIVE, prevMessages: store.getState().conversations[0].messages, conversation: conv,
      provider, model, reasoningMode: 'automatic',
    }).done;
    expect(getPendingDirectiveSuggestion()).toBeNull();
  });

  it('skips tools and uses the fallback when the connection cannot carry them', () => {
    const store = createAppStore({
      providers: [provider], conversations: [conversation(), conversation({ id: 'conv-off', useMemory: false })],
    });
    const base = { store, conversationId: 'conv-1', provider, model, freshSend: true };
    expect(resolveProposeMemoryMode(base)).toBe('tool');
    // Retry / regenerate / edit / continue / restore.
    expect(resolveProposeMemoryMode({ ...base, freshSend: false })).toBe('none');
    // Memory off.
    expect(resolveProposeMemoryMode({ ...base, conversationId: 'conv-off' })).toBe('fallback');
    // Moonshot built-in web-search loop.
    const moonshot = { ...provider, id: 'kimi-1', kind: 'moonshot' } as Provider;
    expect(resolveProposeMemoryMode({ ...base, provider: moonshot, webSearchEnabled: true })).toBe('fallback');
    // Auto candidates off.
    const uid = getActiveUIDSync();
    const candidates = createMemoryCandidateRepository({
      uid,
      items: createMemoryItemRepository({ store, uid, deviceId: 'device-test', sync: () => null }),
    });
    candidates.setAutoSuggestEnabled(false);
    expect(resolveProposeMemoryMode(base)).toBe('fallback');
    candidates.setAutoSuggestEnabled(true);
    // This connection x this model is already downgraded; other models are unaffected.
    markProposeMemoryDegraded('p-1', 'gpt-4');
    expect(resolveProposeMemoryMode(base)).toBe('fallback');
    expect(resolveProposeMemoryMode({ ...base, model: { ...model, id: 'gpt-4o' } })).toBe('tool');
  });
});

describe('propose v3 conversation instructions (model route + fallback language gate)', () => {
  const EN_TEXT = 'Thanks for the list! From now on, reply in bullet points.';
  const EN_SENTENCE = 'From now on, reply in bullet points.';
  const call = (id: string, args: Record<string, string>) => ({ id, name: 'propose_memory', arguments: JSON.stringify(args) });
  const instructArgs = (sourceQuote: string, kind = 'instruction') => ({
    proposition: 'Reply in bullet points.', kind, scope: 'conversation', sourceQuote,
  });

  function setupTool(conv = conversation()) {
    const store = createAppStore({ providers: [provider], conversations: [conv] });
    const ctx = { store, appendChunk: vi.fn(), te: (key: string) => key };
    const uid = getActiveUIDSync();
    const candidates = createMemoryCandidateRepository({
      uid,
      items: createMemoryItemRepository({ store, uid, deviceId: 'device-test', sync: () => null }),
    });
    expect(resolveProposeMemoryMode({ store, conversationId: conv.id, provider, model, freshSend: true })).toBe('tool');
    return { store, ctx, candidates, conv };
  }

  /** The first leg ends with the given propose_memory calls; the last leg is plain body text. */
  function firstLegCalls(...calls: ReturnType<typeof call>[]) {
    mocks.readStream.mockResolvedValueOnce({
      fullText: '', reasoningText: '', usage: undefined, imageAttachments: [], toolCalls: calls,
    });
  }

  async function sendTool(text: string, setup: ReturnType<typeof setupTool>) {
    await sendMessage(setup.ctx, {
      text, prevMessages: [], conversation: setup.conv, provider, model, reasoningMode: 'automatic',
    }).done;
    const msgs = setup.store.getState().conversations.find((c) => c.id === setup.conv.id)!.messages;
    return msgs.filter((m) => m.role === 'user').at(-1)!;
  }

  it('instruct_from_conversation_scope_shows_instruction_bar', async () => {
    const setup = setupTool();
    firstLegCalls(call('call_1', instructArgs(EN_SENTENCE)));
    const userMsg = await sendTool(EN_TEXT, setup);

    // The model route is not language gated: the bar shows even though en is not in suggestionLanguages
    expect(getPendingDirectiveSuggestion()).toEqual({ conversationId: 'conv-1', messageId: userMsg.id, sentence: EN_SENTENCE });
    // instruct creates no memory candidate and shows no memory bar
    expect(await setup.candidates.pending()).toEqual([]);
    expect(getPendingMemorySuggestion()).toBeNull();
    acceptDirectiveSuggestion(setup.store);
    expect(setup.store.getState().conversations[0].instructions).toBe(EN_SENTENCE);
  });

  it('instruct_with_non_instruction_kind_is_skipped', async () => {
    const setup = setupTool();
    firstLegCalls(call('call_1', instructArgs(EN_SENTENCE, 'preference')));
    await sendTool(EN_TEXT, setup);
    expect(getPendingDirectiveSuggestion()).toBeNull();
    expect(await setup.candidates.pending()).toEqual([]);
  });

  it('instruct_quote_not_in_user_message_is_skipped', async () => {
    const setup = setupTool();
    firstLegCalls(call('call_1', instructArgs('From now on, reply in haiku.')));
    await sendTool(EN_TEXT, setup);
    expect(getPendingDirectiveSuggestion()).toBeNull();
  });

  it('instruct_already_in_instructions_is_skipped', async () => {
    const setup = setupTool(conversation({ instructions: `Be concise.\n${EN_SENTENCE}` }));
    firstLegCalls(call('call_1', instructArgs(EN_SENTENCE)));
    await sendTool(EN_TEXT, setup);
    expect(getPendingDirectiveSuggestion()).toBeNull();

    // Shared fixture instructBarCases: the ignore / substring / length conditions match the lexical route
    for (const c of PROPOSE_V3.instructBarCases) {
      const store = createAppStore({
        providers: [provider],
        conversations: [conversation({ id: 'conv-bar', instructions: c.instructions, messages: [{ id: `u-${c.id}`, role: 'user', text: 'x' }] } as Partial<Conversation>)],
      });
      setPreference('directive_suggestion_ignores:conv-bar', c.ignoreCount);
      const ticket = beginMemorySuggestion('conv-bar', `u-${c.id}`, `a-${c.id}`);
      expect(offerInstructSuggestion(store, ticket, c.sentence) !== null, c.id).toBe(c.expected.show);
    }
  });

  it('instruct_second_in_turn_is_skipped', async () => {
    const setup = setupTool();
    const text = 'From now on, reply in English. Also, never use emojis.';
    firstLegCalls(
      call('call_1', instructArgs('From now on, reply in English.')),
      call('call_2', instructArgs('never use emojis.')),
    );
    await sendTool(text, setup);
    expect(getPendingDirectiveSuggestion()?.sentence).toBe('From now on, reply in English.');
    // After ignoring the first one, the second in the same turn does not fill in
    ignoreDirectiveSuggestion();
    expect(getPendingDirectiveSuggestion()).toBeNull();
  });

  it('tool_mode_does_not_run_lexical_suggestion', async () => {
    const setup = setupTool();
    expect(detectDirective(DIRECTIVE)).toMatchObject({ isDirective: true, lang: 'zh-Hans' });
    await sendTool(DIRECTIVE, setup);
    expect(getPendingDirectiveSuggestion()).toBeNull();
    // An instruct from a stale ticket (a newer send exists) does not show a bar either
    const stale = beginMemorySuggestion('conv-1', 'old', 'a-old');
    beginMemorySuggestion('conv-1', 'new', 'a-new');
    expect(offerInstructSuggestion(setup.store, stale, EN_SENTENCE)).toBeNull();
  });

  it('fallback_lexical_suggestion_only_for_gated_languages', async () => {
    markProposeMemoryDegraded('p-1', 'gpt-4');
    const conv = conversation();
    const store = createAppStore({ providers: [provider], conversations: [conv] });
    const ctx = { store, appendChunk: vi.fn(), te: (key: string) => key };
    expect(resolveProposeMemoryMode({ store, conversationId: 'conv-1', provider, model, freshSend: true })).toBe('fallback');

    // The en detector matches, but en is not in suggestionLanguages -> no bar
    expect(detectDirective(EN_DIRECTIVE)).toMatchObject({ isDirective: true, lang: 'en' });
    await sendMessage(ctx, {
      text: EN_DIRECTIVE, prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
    }).done;
    expect(getPendingDirectiveSuggestion()).toBeNull();

    // zh-Hans is inside the gate -> bar shows
    await sendMessage(ctx, {
      text: DIRECTIVE, prevMessages: store.getState().conversations[0].messages, conversation: conv,
      provider, model, reasoningMode: 'automatic',
    }).done;
    expect(getPendingDirectiveSuggestion()?.sentence).toBe(expectedSentence());
  });
});
