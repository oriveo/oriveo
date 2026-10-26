import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import type { ChatMessage } from '@oriveo/shared';
import { upsertMessages } from '../message-merge';

function msg(id: string, role: 'user' | 'assistant', createdAt: string, overrides: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id,
    role,
    text: id,
    providerKind: 'openRouter',
    providerName: 'OpenRouter',
    modelName: 'gpt',
    estimatedCost: 0,
    state: role === 'user' ? 'delivered' : 'generating',
    createdAt,
    ...overrides,
  };
}

type TiebreakCase = {
  case: string;
  messages: { id: string; role: string; createdAtMs: number | null }[];
  expectedOrder: string[];
};

function tiebreakCase(name: string): TiebreakCase {
  const fixture = JSON.parse(readFileSync(
    resolve(process.cwd(), '../../..', 'shared/test-fixtures/sync/message-order-tiebreak.v1.json'), 'utf8',
  )) as { cases: TiebreakCase[] };
  const found = fixture.cases.find((c) => c.case === name);
  if (!found) throw new Error(`fixture case missing: ${name}`);
  return found;
}

/** A fixture createdAtMs of null means createdAt is missing (read back as undefined, not epoch 0) */
function upsertFixtureOrder(fixtureCase: TiebreakCase): string[] {
  return upsertMessages([], fixtureCase.messages.map((m) => msg(
    m.id, m.role as 'user' | 'assistant', '',
    { state: 'delivered', createdAt: m.createdAtMs === null ? undefined : new Date(m.createdAtMs).toISOString() },
  ))).map((m) => m.id);
}

describe('upsertMessages (incremental merge by id + stable createdAt ordering, fixes rapid concurrent sends)', () => {
  it('returns base unchanged when incoming is empty', () => {
    const base = [msg('u1', 'user', '2026-06-01T00:00:00.000Z')];
    expect(upsertMessages(base, [])).toBe(base);
  });

  it('inserts new messages at the right position by createdAt (alternating order)', () => {
    const base = [
      msg('u1', 'user', '2026-06-01T00:00:00.000Z'),
      msg('a1', 'assistant', '2026-06-01T00:00:00.001Z', { state: 'delivered' }),
    ];
    const result = upsertMessages(base, [
      msg('u2', 'user', '2026-06-01T00:00:02.000Z'),
      msg('a2', 'assistant', '2026-06-01T00:00:02.001Z', { state: 'delivered' }),
    ]);
    expect(result.map((m) => m.id)).toEqual(['u1', 'a1', 'u2', 'a2']);
  });

  it('a multi-turn history where every message lacks createdAt (legacy backup import) keeps insertion order and is not reordered by role', () => {
    const base = [
      msg('u1', 'user', '', { createdAt: undefined }),
      msg('a1', 'assistant', '', { createdAt: undefined, state: 'delivered' }),
    ];
    const result = upsertMessages(base, [
      msg('u2', 'user', '', { createdAt: undefined }),
      msg('a2', 'assistant', '', { createdAt: undefined }),
    ]);
    expect(result.map((m) => m.id)).toEqual(['u1', 'a1', 'u2', 'a2']);
  });

  it('replaces an existing id instead of duplicating it (generating to delivered updates in place)', () => {
    const base = [
      msg('u1', 'user', '2026-06-01T00:00:00.000Z'),
      msg('a1', 'assistant', '2026-06-01T00:00:00.001Z', { state: 'generating', text: '' }),
    ];
    const result = upsertMessages(base, [
      msg('a1', 'assistant', '2026-06-01T00:00:00.001Z', { state: 'delivered', text: 'done' }),
    ]);
    expect(result.map((m) => m.id)).toEqual(['u1', 'a1']);
    expect(result[1].state).toBe('delivered');
    expect(result[1].text).toBe('done');
  });

  it('keeps a valid local snapshot when incoming from an older client lacks QuoteContext', () => {
    const quoteContext = {
      schemaVersion: 1 as const,
      sourceMessageId: 'source-1', sourceRole: 'assistant' as const, contentKind: 'prose' as const,
      leadingText: 'before ', selectedText: 'selected', trailingText: ' after', contextTruncated: false,
    };
    const base = [msg('u1', 'user', '2026-08-04T00:00:00.000Z', { quoteContext })];
    const result = upsertMessages(base, [
      msg('u1', 'user', '2026-08-04T00:00:00.000Z', { text: 'remote update' }),
    ]);
    expect(result[0].text).toBe('remote update');
    expect(result[0].quoteContext).toEqual(quoteContext);
  });

  it('rapid concurrent sends: upserting onto the latest base keeps the message that finished first (core root cause)', () => {
    // send1 has already written u1 and a1(delivered) into the store; when send2 completes it upserts u2
    // and a2 on top of that latest base.
    const latestBase = [
      msg('u1', 'user', '2026-06-01T00:00:00.000Z'),
      msg('a1', 'assistant', '2026-06-01T00:00:00.001Z', { state: 'delivered' }),
    ];
    const result = upsertMessages(latestBase, [
      msg('u2', 'user', '2026-06-01T00:00:01.000Z'),
      msg('a2', 'assistant', '2026-06-01T00:00:01.001Z', { state: 'delivered' }),
    ]);
    // The earlier implementation overwrote u1 and a1 with send2's stale snapshot [u2,a2]; an incremental
    // upsert must keep all of them and keep roles strictly alternating.
    expect(result.map((m) => m.id)).toEqual(['u1', 'a1', 'u2', 'a2']);
    expect(result.map((m) => m.role)).toEqual(['user', 'assistant', 'user', 'assistant']);
  });

  it('keeps insertion order when createdAt collides (same millisecond) instead of reordering by id, so an assistant never jumps ahead of the user in the same turn', () => {
    // Equal milliseconds return 0, which is stable and preserves insertion order, matching the semantics
    // of an ordered-by-createdAt read.
    const result = upsertMessages([], [
      msg('m-user', 'user', '2026-06-01T00:00:00.000Z'),
      msg('m-assistant', 'assistant', '2026-06-01T00:00:00.000Z', { state: 'delivered' }),
    ]);
    expect(result.map((m) => m.id)).toEqual(['m-user', 'm-assistant']);
  });

  it('messageOrderTiebreak_fixture: ties on createdAt compare roleRank first (user < assistant), and the same role keeps insertion order', () => {
    const fixture = JSON.parse(readFileSync(
      resolve(process.cwd(), '../../..', 'shared/test-fixtures/sync/message-order-tiebreak.v1.json'), 'utf8',
    )) as {
      cases: { case: string; messages: { id: string; role: string; createdAtMs: number | null }[]; expectedOrder: string[] }[];
    };
    // Cases with the same millisecond and the same role (the fixture orders them by ascending id) do not apply: here insertion order is kept and ids do not reorder
    const applicable = fixture.cases.filter((c) => !(
      c.messages.every((m) => m.createdAtMs !== null &&
        m.createdAtMs === c.messages[0].createdAtMs && m.role === c.messages[0].role)
    ));
    expect(applicable.length).toBeGreaterThan(0);
    for (const fixtureCase of applicable) {
      expect(upsertFixtureOrder(fixtureCase), fixtureCase.case).toEqual(fixtureCase.expectedOrder);
    }
  });

  it('bothMissingCreatedAt_keepsInsertionOrder', () => {
    const c = tiebreakCase('bothMissingCreatedAt_keepsInsertionOrder');
    expect(upsertFixtureOrder(c)).toEqual(c.expectedOrder);
  });

  it('missingCreatedAt_sortsBeforePresent', () => {
    const c = tiebreakCase('missingCreatedAt_sortsBeforePresent');
    expect(upsertFixtureOrder(c)).toEqual(c.expectedOrder);
    // Unparseable or <= 0 ms values also count as missing; times compare by numeric milliseconds, not ISO strings (different spellings of the same instant are equal)
    const result = upsertMessages([], [
      msg('later', 'user', '2026-06-01T00:00:01.000Z', { state: 'delivered' }),
      msg('bad', 'user', 'not-a-date', { state: 'delivered' }),
      msg('epoch', 'user', '1970-01-01T00:00:00.000Z', { state: 'delivered' }),
      msg('a-utc', 'assistant', '2026-06-01T00:00:00Z', { state: 'delivered' }),
      msg('u-offset', 'user', '2026-06-01T08:00:00.000+08:00', { state: 'delivered' }),
    ]);
    expect(result.map((m) => m.id)).toEqual(['bad', 'epoch', 'u-offset', 'a-utc', 'later']);
  });

  it('the same createdAt and the same role keep insertion order (not reordered by id)', () => {
    const result = upsertMessages([], [
      msg('BBBB', 'user', '2026-06-01T00:00:00.000Z'),
      msg('AAAA', 'user', '2026-06-01T00:00:00.000Z'),
    ]);
    expect(result.map((m) => m.id)).toEqual(['BBBB', 'AAAA']);
  });
});
