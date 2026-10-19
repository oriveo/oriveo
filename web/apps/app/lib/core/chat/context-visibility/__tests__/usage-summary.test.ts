import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it } from 'vitest';
import { ContextBudget } from '@oriveo/core/context/budget';
import { ContextCheckpoint } from '@oriveo/core/context/checkpoint';
import type { ContextManifest } from '@oriveo/core/context/manifest';
import { appendContextManifest } from '../../../../infra/storage/context-ledger-store';
import { putContextCheckpoint } from '../../../../infra/storage/context-checkpoint-store';
import { resetDBConnection } from '../../../../infra/storage/idb';
import { setActiveUID } from '../../../../infra/storage/partition';
import {
  summarizeContextUsage,
  usageRingOf,
  type ContextUsageSummary,
  type UsageCheckpointInput,
  type UsageManifestInput,
} from '../usage-summary';
import { ContextCompactionStore } from '../../context-compaction/context-compaction-store';
import {
  currentUsageBudgetOf,
  readContextUsage,
  readContextUsageState,
  usageRefreshKeyOf,
  usageStateForConversation,
} from '../use-context-usage';
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';

// Usage summary: production pure functions line up field by field with usage.v1 and are read back through the real idb ledger.

interface SummaryCase {
  id: string;
  input: { manifests: UsageManifestInput[]; checkpoint: UsageCheckpointInput | null; currentB?: number | null };
  expected: ContextUsageSummary;
}

// Fixture input.currentB: key absent = do not pass current; key present (including null) = pass a computed B.
function summarizeCase(testCase: SummaryCase): ContextUsageSummary {
  const { manifests, checkpoint } = testCase.input;
  return 'currentB' in testCase.input
    ? summarizeContextUsage(manifests, checkpoint, { B: testCase.input.currentB ?? null })
    : summarizeContextUsage(manifests, checkpoint);
}

function repoFile(relative: string): string {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, relative);
    if (existsSync(candidate)) return candidate;
    const next = path.dirname(current);
    if (next === current) throw new Error(relative);
    current = next;
  }
}

const fixture = JSON.parse(readFileSync(repoFile('shared/context-contracts/usage.v1.json'), 'utf8')) as {
  summaryCases: SummaryCase[];
};

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

function manifest(overrides: Partial<ContextManifest>): ContextManifest {
  return {
    requestId: 'r1',
    conversationId: 'c1',
    purpose: 'chat',
    transport: 't1',
    model: 'm1',
    W: 128000,
    O: 4096,
    B: 115200,
    basis: 'estimated',
    estimatedInput: 45000,
    segments: [],
    unansweredMerged: 0,
    reminder: false,
    createdAt: 2000,
    ...overrides,
  } as ContextManifest;
}

describe('ContextUsageSummary', () => {
  beforeEach(async () => {
    resetDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });

  it('usage_summary_matches_fixture', () => {
    expect(fixture.summaryCases.length).toBeGreaterThan(0);
    for (const testCase of fixture.summaryCases) {
      const actual = summarizeCase(testCase);
      expect({ id: testCase.id, ...actual }).toEqual({ id: testCase.id, ...testCase.expected });
    }
  });

  it('usage_summary_from_production_ledger', async () => {
    await appendContextManifest(
      manifest({ requestId: 'r0', createdAt: 1000, observedInput: 30000, stopReason: 'stop' }),
    );
    await appendContextManifest(
      manifest({
        requestId: 'r1',
        createdAt: 2000,
        observedInput: 43776,
        stopReason: 'stop',
        segments: [
          { kind: 'instructions', tokens: 300 },
          { kind: 'memory', tokens: 2000 },
          { kind: 'notes', tokens: 8000, omitted: 2 },
        ],
      }),
    );
    await appendContextManifest(manifest({ conversationId: 'other', requestId: 'x', createdAt: 5000 }));

    const history = [
      { id: 'u1', role: 'user', text: 'first question' },
      { id: 'a1', role: 'assistant', text: 'first answer' },
      { id: 'u2', role: 'user', text: 'second question' },
    ];
    const checkpointText = 'Summary of the earlier exchange.';
    await putContextCheckpoint({
      conversationId: 'c1',
      checkpointId: 'k1',
      kind: 'summary',
      coversFrom: 'u1',
      coversTo: 'a1',
      coversDigest: ContextCheckpoint.coversDigest(history.slice(0, 2)),
      messagesCovered: 2,
      userMessageIds: ['u1'],
      text: checkpointText,
      summary: checkpointText,
      language: 'en',
      model: 'm1',
      packerVersion: '1',
      createdAt: 1500,
      cost: null,
    });

    const rhoHi = 0.5;
    const summary = await readContextUsage('c1', history, rhoHi);
    const summaryTokens = ContextBudget.estimateMessage(checkpointText, rhoHi);
    expect(summary.display).toBe('percent');
    expect(summary.percent).toBe(38);
    expect(summary.basis).toBe('observed');
    expect(summary.used).toBe(43776);
    expect(summary.ring).toEqual({ label: '38', tone: 'neutral' });
    expect(summary.segments).toEqual({
      conversation: 43776 - 300 - 2000 - 8000 - summaryTokens,
      library: 8000,
      summary: summaryTokens,
      instructions: 300,
      memory: 2000,
      free: 115200 - 43776,
    });
    expect(summary.omitted).toEqual({ notes: 2, knowledge: 0, memory: 0 });

    const draft = await readContextUsage('missing', history, rhoHi);
    expect(draft.display).toBe('none');
    expect(draft.ring).toBeNull();
  });

  it('cleared_compaction_shows_unavailable_until_next_send', async () => {
    const history = [
      { id: 'u1', role: 'user', text: 'first question' },
      { id: 'a1', role: 'assistant', text: 'first answer' },
      { id: 'u2', role: 'user', text: 'second question' },
    ];
    const checkpointText = 'Summary of the earlier exchange.';
    await putContextCheckpoint({
      conversationId: 'c1',
      checkpointId: 'k1',
      kind: 'summary',
      coversFrom: 'u1',
      coversTo: 'a1',
      coversDigest: ContextCheckpoint.coversDigest(history.slice(0, 2)),
      messagesCovered: 2,
      userMessageIds: ['u1'],
      text: checkpointText,
      summary: checkpointText,
      language: 'en',
      model: 'm1',
      packerVersion: '1',
      createdAt: 1500,
      cost: null,
    });
    await appendContextManifest(
      manifest({ requestId: 'r1', createdAt: 2000, observedInput: 43776, stopReason: 'stop', checkpointId: 'k1' }),
    );
    const before = await readContextUsage('c1', history, 0.5);
    expect(before.display).toBe('percent');

    // Production clear action removes k1: the last measured value carried the summary size, so it is invalidated until the next send.
    expect(await ContextCompactionStore.deleteAll('c1')).toEqual(['k1']);
    const cleared = await readContextUsage('c1', history, 0.5);
    expect(cleared).toMatchObject({ display: 'unavailable', reason: 'cleared_since', percent: null, ring: null });
    expect(usageRingOf(cleared)).toBeNull();

    // The next send recorded a manifest without a checkpoint; display recovers.
    await appendContextManifest(
      manifest({ requestId: 'r2', createdAt: 3000, observedInput: 30000, stopReason: 'stop' }),
    );
    const next = await readContextUsage('c1', history, 0.5);
    expect(next.display).toBe('percent');
    expect(next.used).toBe(30000);
  });

  it('cap_change_recomputes_denominator', async () => {
    await appendContextManifest(manifest({ requestId: 'r1', createdAt: 2000, observedInput: 43776, stopReason: 'stop' }));
    const model = { id: 'm1', name: 'm1', contextLength: 128000, maxOutputTokens: 4096 } as AIModel;
    const provider = { id: 'p1', kind: 'openAI', models: [model], catalogModels: [] } as unknown as Provider;

    const autoB = currentUsageBudgetOf(provider, 'm1', 'c1', 'auto');
    const auto = (await readContextUsageState('c1', [], 0.5, autoB)).summary;
    expect(auto.B).toBe(115200);
    expect(auto.percent).toBe(38);

    // Switched to the 50000 tier: measured usage is kept, the denominator is recomputed for the new tier.
    const cappedB = currentUsageBudgetOf(provider, 'm1', 'c1', 50000);
    expect(cappedB).toBe(50000);
    const capped = (await readContextUsageState('c1', [], 0.5, cappedB)).summary;
    expect(capped).toMatchObject({ display: 'percent', used: 43776, B: 50000, basis: 'observed' });
    expect(capped.percent).toBeGreaterThan(auto.percent!);
    expect(capped.segments?.free).toBe(50000 - 43776);

    // Unknown window (auto tier) as before: do not guess the window, show window_unknown.
    const unknownModel = { id: 'm2', name: 'm2' } as AIModel;
    const unknownProvider = { ...provider, models: [unknownModel] } as Provider;
    const unknownB = currentUsageBudgetOf(unknownProvider, 'm2', 'c1', 'auto');
    expect(unknownB).toBeNull();
    const unknown = (await readContextUsageState('c1', [], 0.5, unknownB)).summary;
    expect(unknown).toMatchObject({ display: 'unavailable', reason: 'window_unknown', used: 43776 });
  });

  it('usage_drops_previous_conversation', async () => {
    const previous = await readContextUsageState('c1', [], 0.5);
    expect(previous.conversationId).toBe('c1');
    expect(usageStateForConversation(previous, 'c1')).toBe(previous);
    expect(usageStateForConversation(previous, 'c2')).toBeNull();
    expect(usageStateForConversation(previous, null)).toBeNull();
    expect(usageStateForConversation(null, 'c1')).toBeNull();
  });

  it('usage_refresh_key_ignores_streaming_text', () => {
    const base = [
      { id: 'u1', role: 'user', text: 'hi', state: 'done' },
      { id: 'a1', role: 'assistant', text: 'He', state: 'streaming' },
    ] as unknown as ChatMessage[];
    const key = usageRefreshKeyOf(base);
    const grown = [base[0], { ...base[1], text: 'Hello there' }] as ChatMessage[];
    expect(usageRefreshKeyOf(grown)).toBe(key);
    const finished = [base[0], { ...base[1], text: 'Hello there', state: 'done' }] as ChatMessage[];
    expect(usageRefreshKeyOf(finished)).not.toBe(key);
    const appended = [...base, { id: 'u2', role: 'user', text: 'x', state: 'done' }] as unknown as ChatMessage[];
    expect(usageRefreshKeyOf(appended)).not.toBe(key);
  });

  it('usage_ring_hidden_unless_percent', () => {
    for (const testCase of fixture.summaryCases) {
      const summary = summarizeCase(testCase);
      const ring = usageRingOf(summary);
      if (summary.display !== 'percent') {
        expect({ id: testCase.id, ring }).toEqual({ id: testCase.id, ring: null });
        continue;
      }
      expect(ring?.label).toBe(testCase.expected.ring?.label);
      expect(ring?.tone).toBe(testCase.expected.ring?.tone);
      if (ring?.label === '!') {
        expect(ring.a11y).toEqual({ key: 'ringOverA11y' });
      } else {
        expect(ring?.a11y).toEqual({ key: 'ringA11y', percent: summary.percent, limit: summary.B });
      }
    }
  });

  it('strings_present_in_16_locales', () => {
    const locales = [
      'zh-Hans', 'en', 'zh-Hant', 'ja', 'ko', 'de', 'fr', 'es',
      'pt-BR', 'ru', 'tr', 'ar', 'hi', 'vi', 'id', 'th',
    ];
    for (const locale of locales) {
      const messages = JSON.parse(
        readFileSync(repoFile(`web/apps/app/messages/${locale}.json`), 'utf8'),
      ) as { pages: { chat: { contextUsage?: { ringA11y?: string; ringOverA11y?: string } } } };
      const usage = messages.pages.chat.contextUsage;
      expect({ locale, ok: typeof usage?.ringA11y === 'string' }).toEqual({ locale, ok: true });
      expect(usage?.ringA11y).toContain('{percent}');
      expect(usage?.ringA11y).toContain('{limit}');
      expect(usage?.ringOverA11y?.trim().length ?? 0).toBeGreaterThan(0);
    }
  });
});
