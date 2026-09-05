import { describe, expect, it } from 'vitest';
import type { Note } from '@oriveo/shared';
import { getAllNoteTags, getSuggestedNoteTags, sortNotes, type NoteSortKey } from '../note-list';

function makeNote(id: string, overrides: Partial<Note>): Note {
  return {
    id,
    title: overrides.title ?? id,
    titleSource: overrides.titleSource ?? 'placeholder',
    body: overrides.body ?? '',
    tags: overrides.tags ?? [],
    captureKind: overrides.captureKind ?? 'blank',
    sourceProviderKind: overrides.sourceProviderKind,
    isPinned: overrides.isPinned,
    createdAt: overrides.createdAt ?? '2026-06-01T00:00:00.000Z',
    updatedAt: overrides.updatedAt ?? '2026-06-01T00:00:00.000Z',
  };
}

describe('sortNotes', () => {
  const notes = [
    makeNote('old-openai', {
      createdAt: '2026-06-01T10:00:00.000Z',
      updatedAt: '2026-06-03T10:00:00.000Z',
      sourceProviderKind: 'openAI',
    }),
    makeNote('new-anthropic', {
      createdAt: '2026-06-05T10:00:00.000Z',
      updatedAt: '2026-06-02T10:00:00.000Z',
      sourceProviderKind: 'anthropic',
    }),
    makeNote('pinned-gemini', {
      createdAt: '2026-06-02T10:00:00.000Z',
      updatedAt: '2026-06-01T10:00:00.000Z',
      sourceProviderKind: 'gemini',
      isPinned: true,
    }),
  ];

  it('always places pinned notes first', () => {
    for (const key of ['createdAt', 'updatedAt', 'sourceProviderKind'] satisfies NoteSortKey[]) {
      expect(sortNotes(notes, key)[0].id).toBe('pinned-gemini');
    }
  });

  it('sorts by created time descending after pinned notes', () => {
    expect(sortNotes(notes, 'createdAt').map((note) => note.id)).toEqual([
      'pinned-gemini',
      'new-anthropic',
      'old-openai',
    ]);
  });

  it('sorts by updated time descending after pinned notes', () => {
    expect(sortNotes(notes, 'updatedAt').map((note) => note.id)).toEqual([
      'pinned-gemini',
      'old-openai',
      'new-anthropic',
    ]);
  });

  it('sorts by provider kind after pinned notes', () => {
    expect(sortNotes(notes, 'sourceProviderKind').map((note) => note.id)).toEqual([
      'pinned-gemini',
      'new-anthropic',
      'old-openai',
    ]);
  });
});

describe('getAllNoteTags', () => {
  it('dedupes and sorts non-empty tags', () => {
    const notes = [
      makeNote('a', { tags: ['billing', ' cache ', ''] }),
      makeNote('b', { tags: ['cache', 'zebra'] }),
    ];

    expect(getAllNoteTags(notes)).toEqual(['billing', 'cache', 'zebra']);
  });
});

describe('getSuggestedNoteTags', () => {
  it('excludes existing tags case-insensitively and preserves original suggestion spelling', () => {
    const notes = [
      makeNote('current', { tags: ['Vector', 'web'] }),
      makeNote('other', { tags: ['vector', 'React', 'research'] }),
      makeNote('third', { tags: ['Research', 'ux'] }),
    ];

    expect(getSuggestedNoteTags(notes, ['Vector', 'web'])).toEqual(['React', 'research', 'ux']);
  });
});
