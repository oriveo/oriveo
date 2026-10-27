import 'fake-indexeddb/auto';
/**
 * Compaction coordinator:
 * mode decision (preference / feature switch / breaker / manual), the two AI attempts and the fallback, the fields of the saved row, and breaker counting.
 * Assertions read the row the coordinator actually saved through putContextCheckpoint and the request summarize actually received.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ContextCheckpoint } from '@oriveo/core/context/checkpoint';
import { ContextCompactor, type SummaryRequest } from '@oriveo/core/context/compactor';

const mocks = vi.hoisted(() => ({
  aiPref: undefined as boolean | undefined,
  flags: {} as Record<string, boolean>,
  putFails: false,
}));

vi.mock('../../../../providers/StoreProvider', () => ({
  tryGetVanillaStore: () => ({
    getState: () => ({ preferences: { theme: 'dark', contextAISummaryEnabled: mocks.aiPref } }),
  }),
}));
vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../metadata/metadata-client')>()),
  isRuntimeFeatureEnabled: (key: string) => mocks.flags[key] !== false,
}));
vi.mock('../../../infra/storage/context-checkpoint-store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../infra/storage/context-checkpoint-store')>();
  return {
    ...actual,
    putContextCheckpoint: async (...args: Parameters<typeof actual.putContextCheckpoint>) => {
      if (mocks.putFails) throw new Error('quota exceeded');
      return actual.putContextCheckpoint(...args);
    },
  };
});

import { resetDBConnection } from '../../../infra/storage/idb';
import { setActiveUID } from '../../../infra/storage/partition';
import {
  type ContextCheckpointRow,
  deleteContextCheckpoints,
  listContextCheckpoints,
  putContextCheckpoint,
} from '../../../infra/storage/context-checkpoint-store';
import {
  CompactionBreakers,
  createCompactionCoordinator,
  type CompactionContext,
  type CompactionCoordinatorDeps,
} from './compaction-coordinator';
import { assembleChatPlan, chatCompactionContextOf, type ChatContextAssembly } from './chat-context';
import type { AIModel, Provider } from '@oriveo/shared';

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

// B=40000: tail=10000, summaryMax=2000; 5000 per message -> the tail starts at m5, span = m1..m4.
const B = 40000;
const history: CompactionContext['messages'] = [
  { id: 'm1', role: 'user', text: 'first question', estTokens: 5000 },
  { id: 'm2', role: 'assistant', text: 'first answer', estTokens: 5000 },
  { id: 'm3', role: 'user', text: 'second question', estTokens: 5000, isDirective: true },
  { id: 'm4', role: 'assistant', text: 'second answer', estTokens: 5000 },
  { id: 'm5', role: 'user', text: 'third question', estTokens: 5000 },
  { id: 'm6', role: 'assistant', text: 'third answer', estTokens: 5000 },
];

function context(overrides: Partial<CompactionContext> = {}): CompactionContext {
  return { messages: history, B, U: 100000, prefixTokens: 500, rhoHi: 0.5, fixedTokens: 0, model: 'gpt-x', ...overrides };
}

const VALID = ['## Goal', 'g', '## Key Facts & Decisions', 'k', '## Work Produced', 'w', '## Open Threads', 'o',
  '## Style & Language', 's'].join('\n');
const INVALID = 'no headings here';

function coordinator(summarize: CompactionCoordinatorDeps['summarize'], overrides: Partial<CompactionCoordinatorDeps> = {}) {
  return createCompactionCoordinator({ context: () => context(), summarize, now: () => 4242, ...overrides });
}

function digestThrough(index: number): string {
  return ContextCheckpoint.coversDigest(history.slice(0, index + 1).map((m) => ({ id: m.id, text: m.text })));
}

/** Deletes the rows already saved for the conversation so the next compaction covers the same span again (simulates invalidation after the history is rewritten). */
async function forgetRows(conversationId: string) {
  const rows = await listContextCheckpoints(conversationId);
  await deleteContextCheckpoints(conversationId, rows.map((r) => r.checkpointId));
}

describe('compaction coordinator', () => {
  beforeEach(async () => {
    resetDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
    mocks.aiPref = true;
    mocks.flags = {};
    mocks.putFails = false;
    CompactionBreakers.reset();
  });
  afterEach(() => vi.clearAllMocks());

  it('coordinator_fallback_mode_saves_fallback_row', async () => {
    mocks.aiPref = undefined; // missing counts as false -> fallback
    const summarize = vi.fn(async () => VALID);
    const result = await coordinator(summarize).compact('c1', 'preSend');

    expect(summarize).not.toHaveBeenCalled();
    expect(result.outcome).toBe('fallback');
    const fb = ContextCheckpoint.fallback(history, B, 0.5, 0, null);
    const expected: ContextCheckpointRow = {
      conversationId: 'c1',
      checkpointId: ContextCheckpoint.checkpointId('c1', 'm4', '1'),
      kind: 'fallback',
      coversFrom: 'm1',
      coversTo: 'm4',
      coversDigest: digestThrough(3),
      messagesCovered: 4,
      userMessageIds: fb.keptUserIds,
      text: fb.checkpointText!,
      summary: null,
      language: null,
      model: 'gpt-x',
      packerVersion: '1',
      createdAt: 4242,
      cost: null,
    };
    expect(result.row).toEqual(expected);
    expect(await listContextCheckpoints('c1')).toEqual([expected]);
  });

  it('coordinator_pre_send_reuses_row_landed_after_assembly_without_waiting', async () => {
    // Send arrives a step late: pre-compaction already finished and persisted its row, but send assembly has not used it yet → hand it back directly instead of summarizing the same span again.
    const summarize = vi.fn(async (_req: SummaryRequest) => VALID);
    const landed = await coordinator(summarize).compact('c1', 'preSend');
    expect(landed.row?.kind).toBe('summary');

    const late = await coordinator(summarize).compact('c1', 'preSend', { assembledCheckpointId: null });

    expect(summarize).toHaveBeenCalledTimes(1);
    expect(late.row?.checkpointId).toBe(landed.row?.checkpointId);
    expect(await listContextCheckpoints('c1')).toHaveLength(1);
  });

  it('coordinator_ai_mode_saves_summary_row', async () => {
    const summarize = vi.fn(async (_req: SummaryRequest) => VALID);
    const result = await coordinator(summarize).compact('c1', 'preSend');

    expect(summarize).toHaveBeenCalledTimes(1);
    const req = summarize.mock.calls[0][0];
    const expectedReq = ContextCompactor.summaryRequest({
      U: 100000, prefixTokens: 500, rhoHi: 0.5, language: null, summaryMax: 2000,
      previousCheckpointText: null, previousSummary: null,
      span: history.slice(0, 4).map((m) => ({ id: m.id, role: m.role, text: m.text })),
    });
    expect(req).toEqual(expectedReq);
    expect(result.outcome).toBe('summary');
    expect(result.failures).toEqual([]);
    const listed = await listContextCheckpoints('c1');
    expect(listed).toHaveLength(1);
    const row = listed[0];
    expect(result.row).toEqual(row);
    expect(row).toMatchObject({
      kind: 'summary', coversFrom: 'm1', coversTo: 'm4', messagesCovered: 4, summary: VALID,
      language: null, cost: null, model: 'gpt-x', packerVersion: '1', createdAt: 4242,
      checkpointId: ContextCheckpoint.checkpointId('c1', 'm4', '1'), coversDigest: digestThrough(3),
    });
    expect(row.userMessageIds).toEqual(['m1', 'm3']);
    expect(row.text).toContain(`<summary>`);

    // Whitespace around the summary output: the row's summary stores the trimmed text, from the same source as the <summary> in the body.
    const padded = vi.fn(async () => `\n\n${VALID} \n\n`);
    const paddedResult = await coordinator(padded).compact('c2', 'preSend');
    expect(paddedResult.outcome).toBe('summary');
    const [paddedRow] = await listContextCheckpoints('c2');
    expect(paddedRow.summary).toBe(VALID);
    expect(paddedRow.text).toContain(`<summary>${VALID.replace(/&/g, '&amp;')}</summary>`);
  });

  it('compaction_inputs_mark_directives', () => {
    // Production path: chatCompactionContextOf marks the user messages of the compaction candidates with isDirective via the recognizer.
    const model = {
      id: 'ctx-model', name: 'ctx-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true,
      isDefault: true, priceTier: '', contextLength: 20000, maxOutputTokens: 1000,
    } as AIModel;
    const provider = { id: 'relay-ctx', kind: 'relay', models: [model], catalogModels: [] } as unknown as Provider;
    const assembly = {
      input: {
        purpose: 'chat',
        window: { W: 20000, windowKind: 'total', maxOutput: { user: null, recipe: null, model: 1000 } },
        rhoHi: 0.5,
        conversation: { id: 'c1', useMemory: false },
        history: [
          { id: 'u1', role: 'user', text: 'From now on, reply in English.', state: 'delivered', attachments: [] },
          { id: 'a1', role: 'assistant', text: 'Sure.', state: 'delivered', attachments: [] },
          { id: 'u2', role: 'user', text: 'Tell me about the weather today.', state: 'delivered', attachments: [] },
          { id: 'a2', role: 'assistant', text: 'Sunny.', state: 'delivered', attachments: [] },
          { id: 'u3', role: 'user', text: 'Thanks.', state: 'delivered', attachments: [] },
        ],
      },
      promptContext: {},
    } as unknown as ChatContextAssembly;
    const plan = assembleChatPlan(assembly, { provider, model });
    const ctx = chatCompactionContextOf(assembly, plan, { provider, model, userMaxOutput: null });

    expect(ctx).not.toBeNull();
    const users = ctx!.messages.filter((m) => m.role === 'user').map((m) => [m.id, m.isDirective]);
    expect(users).toEqual([['u1', true], ['u2', false]]);
  });

  it('coordinator_invalid_twice_falls_back_and_counts_failure', async () => {
    const summarize = vi.fn(async () => INVALID);
    const result = await coordinator(summarize).compact('c1', 'preSend');

    expect(summarize).toHaveBeenCalledTimes(2);
    expect(result.outcome).toBe('fallback');
    expect(result.failures).toHaveLength(2);
    expect(result.row?.kind).toBe('fallback');
    expect(CompactionBreakers.state('c1').failures).toBe(1);
    expect(CompactionBreakers.mode('c1')).toBe('llm');

    // First attempt errors (null / throw), second is qualified -> summary, failures reset to zero
    let call = 0;
    const flaky = vi.fn(async () => {
      call += 1;
      if (call === 1) throw new Error('boom');
      return VALID;
    });
    await forgetRows('c1');
    const second = await coordinator(flaky).compact('c1', 'preSend');
    expect(flaky).toHaveBeenCalledTimes(2);
    expect(second.outcome).toBe('summary');
    expect(second.failures).toEqual([['callError']]);
    expect(CompactionBreakers.state('c1').failures).toBe(0);
  });

  it('coordinator_two_failed_compactions_trip_breaker', async () => {
    const summarize = vi.fn(async () => INVALID);
    const run = coordinator(summarize);
    await run.compact('c1', 'preSend');
    await forgetRows('c1');
    await run.compact('c1', 'overflow');
    expect(summarize).toHaveBeenCalledTimes(4);
    expect(CompactionBreakers.mode('c1')).toBe('fallbackOnly');
    expect(CompactionBreakers.mode('c2')).toBe('llm');

    await forgetRows('c1');
    const tripped = await run.compact('c1', 'preSend');
    expect(summarize).toHaveBeenCalledTimes(4);
    expect(tripped.outcome).toBe('fallback');

    // Each chat send counts one turn; recovers after 10 turns
    for (let i = 0; i < 10; i += 1) CompactionBreakers.recordTurn('c1');
    expect(CompactionBreakers.mode('c1')).toBe('llm');

    await forgetRows('c1');
    await run.compact('c1', 'preSend');
    await forgetRows('c1');
    await run.compact('c1', 'preSend');
    expect(summarize).toHaveBeenCalledTimes(8);
    expect(CompactionBreakers.mode('c1')).toBe('fallbackOnly');
    CompactionBreakers.retry('c1');
    expect(CompactionBreakers.mode('c1')).toBe('llm');
    expect(CompactionBreakers.state('c1').failures).toBe(0);
  });

  it('coordinator_too_large_falls_back_without_failure', async () => {
    const summarize = vi.fn(async () => VALID);
    const result = await coordinator(summarize, { context: () => context({ U: 100 }) }).compact('c1', 'preSend');

    expect(summarize).not.toHaveBeenCalled();
    expect(result.outcome).toBe('fallback');
    expect(result.failures).toEqual([]);
    expect(result.row?.kind).toBe('fallback');
    expect(CompactionBreakers.state('c1').failures).toBe(0);
  });

  it('coordinator_remote_flag_off_forces_fallback', async () => {
    mocks.flags = { context_compaction_enabled: false };
    const summarize = vi.fn(async () => VALID);
    const run = coordinator(summarize);

    expect((await run.compact('c1', 'preSend')).outcome).toBe('fallback');
    expect((await run.compact('c1', 'manual')).outcome).toBe('fallback');
    expect(summarize).not.toHaveBeenCalled();
  });

  it('coordinator_manual_ignores_pref_and_breaker', async () => {
    mocks.aiPref = false;
    const failing = vi.fn(async () => INVALID);
    const run = coordinator(failing);
    await run.compact('c1', 'manual');
    await forgetRows('c1');
    await run.compact('c1', 'manual');
    // Manual still counts toward the breaker
    expect(failing).toHaveBeenCalledTimes(4);
    expect(CompactionBreakers.mode('c1')).toBe('fallbackOnly');

    const summarize = vi.fn(async () => VALID);
    await forgetRows('c1');
    const manual = await coordinator(summarize).compact('c1', 'manual');
    expect(summarize).toHaveBeenCalledTimes(1);
    expect(manual.outcome).toBe('summary');

    // Not manual: preference off -> fallback
    await forgetRows('c1');
    const preSend = await coordinator(summarize).compact('c1', 'preSend');
    expect(summarize).toHaveBeenCalledTimes(1);
    expect(preSend.outcome).toBe('fallback');
  });

  it('coordinator_incremental_passes_previous_summary', async () => {
    const previous: ContextCheckpointRow = {
      conversationId: 'c1',
      checkpointId: ContextCheckpoint.checkpointId('c1', 'm2', '1'),
      kind: 'summary',
      coversFrom: 'm1',
      coversTo: 'm2',
      coversDigest: digestThrough(1),
      messagesCovered: 2,
      userMessageIds: ['m1'],
      text: '<oriveo-context-checkpoint v="1">PREVIOUS</oriveo-context-checkpoint>',
      summary: 'PREVIOUS SUMMARY',
      language: null,
      model: 'gpt-x',
      packerVersion: '1',
      createdAt: 1,
      cost: null,
    };
    await putContextCheckpoint(previous);

    const summarize = vi.fn(async (_req: SummaryRequest) => VALID);
    const result = await coordinator(summarize).compact('c1', 'preSend');
    const req = summarize.mock.calls[0][0];
    expect(req).toEqual(ContextCompactor.summaryRequest({
      U: 100000, prefixTokens: 500, rhoHi: 0.5, language: null, summaryMax: 2000,
      previousCheckpointText: previous.text, previousSummary: previous.summary,
      span: history.slice(2, 4).map((m) => ({ id: m.id, role: m.role, text: m.text })),
    }));
    expect(req.shape).toBe('appended');
    if (req.shape !== 'tooLarge') expect(req.messages[0].text.startsWith(previous.text)).toBe(true);
    expect(result.outcome).toBe('summary');
    expect(result.row).toMatchObject({ coversFrom: 'm1', coversTo: 'm4', messagesCovered: 4 });

    // Fallback path: fallback carries the old summary
    mocks.aiPref = false;
    await putContextCheckpoint({ ...previous, conversationId: 'c4' });
    const fb = await coordinator(summarize).compact('c4', 'preSend');
    expect(summarize).toHaveBeenCalledTimes(1);
    expect(fb.outcome).toBe('fallback');
    expect(fb.row?.summary).toBe('PREVIOUS SUMMARY');
    expect(fb.row?.text).toBe(ContextCheckpoint.fallback(history, B, 0.5, 0, 'PREVIOUS SUMMARY').checkpointText);
  });

  it('coordinator_saved_row_is_persisted', async () => {
    const summarize = vi.fn(async () => VALID);
    const saved = await coordinator(summarize).compact('c1', 'preSend');
    expect(saved.outcome).toBe('summary');
    expect(await listContextCheckpoints('c1')).toEqual([saved.row]);
  });
  it('coordinator_keeps_older_rows_of_same_conversation', async () => {
    // The conversation already has one row (a different coversTo): the count covers all local checkpointIds of this conversation, not message ids.
    const older: ContextCheckpointRow = {
      conversationId: 'c1',
      checkpointId: ContextCheckpoint.checkpointId('c1', 'm2', '1'),
      kind: 'fallback',
      coversFrom: 'm1',
      coversTo: 'm2',
      coversDigest: digestThrough(1),
      messagesCovered: 2,
      userMessageIds: ['m1'],
      text: 'OLDER',
      summary: null,
      language: null,
      model: 'gpt-x',
      packerVersion: '1',
      createdAt: 1,
      cost: null,
    };
    await putContextCheckpoint(older);
    await putContextCheckpoint({ ...older, conversationId: 'other' });
    const result = await coordinator(vi.fn(async () => VALID)).compact('c1', 'preSend');
    expect(result.outcome).toBe('summary');
    const localIds = (await listContextCheckpoints('c1')).map((r) => r.checkpointId);
    expect(localIds).toHaveLength(2);
    expect(localIds).toContain(older.checkpointId);
    expect(localIds).toContain(result.row?.checkpointId);
  });

  it('coordinator_save_failure_returns_no_row', async () => {
    mocks.putFails = true;
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});
    const result = await coordinator(vi.fn(async () => VALID)).compact('c1', 'preSend');
    // Save failure returns noop; the caller falls back to the in-memory fallback.
    expect(result.outcome).toBe('noop');
    expect(result.row).toBeUndefined();
    expect(error).toHaveBeenCalled();
    expect(await listContextCheckpoints('c1')).toHaveLength(0);

    mocks.aiPref = false;
    const fallback = await coordinator(vi.fn(async () => VALID)).compact('c2', 'preSend');
    expect(fallback.outcome).toBe('noop');
    expect(fallback.row).toBeUndefined();
    error.mockRestore();
  });
});
