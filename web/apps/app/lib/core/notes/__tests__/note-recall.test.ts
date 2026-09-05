import { describe, expect, it } from 'vitest';
import type { Note } from '@oriveo/shared';
import {
  findRelatedNotes,
  NoteRecallIndex,
  NOTE_RECALL_MAX_BODY_CHARACTERS,
  NOTE_RECALL_MAX_CANDIDATES,
  NOTE_RECALL_MAX_TAG_CHARACTERS,
  NOTE_RECALL_MAX_TITLE_CHARACTERS,
  NOTE_RECALL_WORKER_MAX_INDEX_CHARS,
  NOTE_RECALL_WORKER_MAX_INDEX_NOTES,
  recallCandidates,
} from '../note-recall';

function note(overrides: Partial<Note>): Note {
  return {
    id: overrides.id ?? crypto.randomUUID(),
    title: overrides.title ?? 'Untitled',
    titleSource: overrides.titleSource ?? 'manual',
    body: overrides.body ?? '',
    tags: overrides.tags ?? [],
    captureKind: overrides.captureKind ?? 'blank',
    createdAt: overrides.createdAt ?? '2026-06-19T00:00:00.000Z',
    updatedAt: overrides.updatedAt ?? '2026-06-19T00:00:00.000Z',
    ...overrides,
  };
}

describe('findRelatedNotes', () => {
  it('returns empty for blank draft', () => {
    expect(findRelatedNotes('   ', [note({ title: 'React cache' })])).toEqual([]);
  });

  it('prepares a first-seen note even when a legacy fixture lacks updatedAt', () => {
    const legacy = note({ id: 'legacy', title: 'vector recall' });
    delete (legacy as Partial<Note>).updatedAt;

    expect(findRelatedNotes('vector recall', [legacy]).map((result) => result.note.id)).toEqual(['legacy']);
  });

  it('prioritizes tag matches over body-only keyword matches', () => {
    const tagged = note({
      id: 'tagged',
      title: 'Old design memo',
      tags: ['vector database'],
      body: 'Sparse details.',
    });
    const bodyOnly = note({
      id: 'body',
      title: 'Embeddings',
      body: 'The answer mentions vector database several times.',
    });

    const results = findRelatedNotes('Should I use a vector database for note recall?', [bodyOnly, tagged]);

    expect(results.map((result) => result.note.id)).toEqual(['tagged', 'body']);
    expect(results[0].score).toBeGreaterThan(results[1].score);
  });

  it('supports conservative continuous-phrase matching for scripts without word separators', () => {
    const japanese = note({
      id: 'ja',
      title: 'マルチモデルこうしょうのてじゅん',
      body: 'こたえをほぞんしたあと、にばんめのモデルでマルチモデルこうしょうができます。',
    });

    const results = findRelatedNotes('マルチモデルこうしょうはどうやりますか', [japanese]);

    expect(results.map((result) => result.note.id)).toEqual(['ja']);
  });

  it('returns empty when overlap is below the noise threshold', () => {
    const unrelated = note({
      id: 'noise',
      title: 'Billing webhook',
      body: 'Local backups and receipts.',
      tags: ['billing'],
    });

    expect(findRelatedNotes('How should I tune markdown rendering?', [unrelated])).toEqual([]);
  });

  it('omits deleted notes and caps results', () => {
    const notes = [
      note({ id: 'a', title: 'React prompt context', tags: ['prompt'] }),
      note({ id: 'deleted', title: 'React prompt context', tags: ['prompt'], deletedAt: '2026-06-19T01:00:00.000Z' }),
      note({ id: 'b', title: 'Prompt budget', tags: ['prompt'] }),
      note({ id: 'c', title: 'Prompt injection', tags: ['prompt'] }),
    ];

    const results = findRelatedNotes('prompt context budget', notes, { limit: 2 });

    expect(results.map((result) => result.note.id)).toEqual(['a', 'b']);
  });

  it('counts overlapping terms with one corpus scan', () => {
    const results = findRelatedNotes('banana ana nan', [note({ id: 'overlap', title: 'banana' })]);

    expect(results).toHaveLength(1);
    expect(results[0].score).toBe(12);
    expect(new Set(results[0].matchedTerms)).toEqual(new Set(['ana', 'banana', 'nan']));
  });

  it('bounds candidate count and note body work', () => {
    const candidates = Array.from({ length: NOTE_RECALL_MAX_CANDIDATES }, (_, index) => note({
      id: `recent-${index}`,
      title: `recent note ${index}`,
      body: 'unrelated',
    }));
    const outsideCandidateBound = note({ id: 'outside', title: 'kubernetes deployment' });
    const matchOutsideBodyBound = note({
      id: 'outside-body',
      title: 'unrelated',
      body: `${'x'.repeat(NOTE_RECALL_MAX_BODY_CHARACTERS)} kubernetes deployment`,
    });
    const matchOutsideTitleBound = note({
      id: 'outside-title',
      title: `${'x'.repeat(NOTE_RECALL_MAX_TITLE_CHARACTERS)} kubernetes deployment`,
    });
    const matchOutsideTagBound = note({
      id: 'outside-tag',
      tags: [`${'x'.repeat(NOTE_RECALL_MAX_TAG_CHARACTERS)}kubernetes`],
    });

    expect(findRelatedNotes('kubernetes deployment', [...candidates, outsideCandidateBound])).toEqual([]);
    expect(findRelatedNotes('kubernetes deployment', [matchOutsideBodyBound])).toEqual([]);
    expect(findRelatedNotes('kubernetes deployment', [matchOutsideTitleBound])).toEqual([]);
    expect(findRelatedNotes('kubernetes deployment', [matchOutsideTagBound])).toEqual([]);
  });

  // The upper bounds on worst-case work are the slice() calls in note-recall.ts, and the
  // assertions above pin all four of them deterministically (candidate / body / title / tag: put
  // the matching term past the bound and assert it is not found). Dropping any slice makes those
  // assertions name the exact one, where a stopwatch would only report "slower". Bounds are
  // proven by an out-of-bounds miss, not by wall-clock time.
});

describe('recallCandidates', () => {
  it('projects only bounded recall fields across the worker boundary', () => {
    const heavy = note({
      id: 'heavy',
      title: 'context budget',
      bodySnapshot: 'x'.repeat(100_000),
      sourcePrompt: 'y'.repeat(50_000),
      userNote: 'private remark',
    });

    const candidates = recallCandidates([heavy], NOTE_RECALL_MAX_CANDIDATES);

    expect(candidates).toHaveLength(1);
    expect(Object.keys(candidates[0]).sort()).toEqual(
      ['body', 'id', 'tags', 'title', 'updatedAt', 'updatedAtMs'],
    );
  });

  it('orders candidates by recency, drops trash, and enforces the cap', () => {
    const older = note({ id: 'older', updatedAt: '2026-06-01T00:00:00.000Z' });
    const newer = note({ id: 'newer', updatedAt: '2026-06-20T00:00:00.000Z' });
    const oldest = note({ id: 'oldest', updatedAt: '2026-05-01T00:00:00.000Z' });
    const trashed = note({ id: 'gone', deletedAt: '2026-06-21T00:00:00.000Z' });

    const candidates = recallCandidates([older, trashed, oldest, newer], 2);

    expect(candidates.map((candidate) => candidate.id)).toEqual(['newer', 'older']);
  });
});

describe('NoteRecallIndex', () => {
  it('enforces note-count and char budgets independently', () => {
    const candidates = recallCandidates([
      note({ id: 'a', title: 'kubernetes deployment', updatedAt: '2026-06-21T00:00:00.000Z' }),
      note({ id: 'b', title: 'kubernetes deployment', updatedAt: '2026-06-20T00:00:00.000Z' }),
      note({ id: 'c', title: 'kubernetes deployment', updatedAt: '2026-06-19T00:00:00.000Z' }),
    ], NOTE_RECALL_MAX_CANDIDATES);

    const countBudget = new NoteRecallIndex({ maxNotes: 2, maxTotalChars: 1_000_000 });
    countBudget.update(candidates);
    expect(countBudget.find('kubernetes deployment', { limit: 8 }).map((match) => match.id)).toEqual(['a', 'b']);

    const charBudget = new NoteRecallIndex({ maxNotes: 128, maxTotalChars: 40 });
    charBudget.update(candidates);
    expect(charBudget.find('kubernetes deployment', { limit: 8 }).map((match) => match.id)).toEqual(['a']);
  });

  it('recalls old notes beyond the main-thread cap with the worker index budget', () => {
    const filler = Array.from({ length: 300 }, (_, index) => note({
      id: `filler-${index}`,
      title: `filler ${index}`,
      updatedAt: '2026-06-20T00:00:00.000Z',
    }));
    const old = note({ id: 'old', title: 'kubernetes deployment', updatedAt: '2026-01-01T00:00:00.000Z' });

    const index = new NoteRecallIndex({
      maxNotes: NOTE_RECALL_WORKER_MAX_INDEX_NOTES,
      maxTotalChars: NOTE_RECALL_WORKER_MAX_INDEX_CHARS,
    });
    index.update(recallCandidates([...filler, old], NOTE_RECALL_WORKER_MAX_INDEX_NOTES));

    expect(index.find('kubernetes deployment').map((match) => match.id)).toEqual(['old']);
  });

  it('refreshes cached normalization when a legacy candidate lacks updatedAt', () => {
    const index = new NoteRecallIndex();
    const legacy = note({ id: 'legacy', body: 'kubernetes deployment guide' });
    delete (legacy as Partial<Note>).updatedAt;
    index.update(recallCandidates([legacy], NOTE_RECALL_MAX_CANDIDATES));
    expect(index.find('kubernetes deployment').map((match) => match.id)).toEqual(['legacy']);

    const edited = note({ id: 'legacy', body: 'terraform module registry' });
    delete (edited as Partial<Note>).updatedAt;
    index.update(recallCandidates([edited], NOTE_RECALL_MAX_CANDIDATES));
    expect(index.find('terraform module registry').map((match) => match.id)).toEqual(['legacy']);
    expect(index.find('kubernetes deployment')).toEqual([]);
  });
});
