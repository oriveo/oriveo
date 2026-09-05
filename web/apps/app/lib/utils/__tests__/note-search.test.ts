import { describe, expect, it } from 'vitest';
import type { Note } from '@oriveo/shared';
import { searchNotes } from '../note-search';

function makeNote(overrides: Partial<Note>): Note {
  return {
    id: overrides.id ?? 'note-1',
    title: overrides.title ?? 'Untitled',
    titleSource: overrides.titleSource ?? 'placeholder',
    body: overrides.body ?? '',
    userNote: overrides.userNote,
    tags: overrides.tags ?? [],
    captureKind: overrides.captureKind ?? 'blank',
    createdAt: overrides.createdAt ?? '2026-06-01T00:00:00.000Z',
    updatedAt: overrides.updatedAt ?? '2026-06-01T00:00:00.000Z',
  };
}

describe('searchNotes', () => {
  const notes = [
    makeNote({ id: 'n1', title: 'Qwen routing notes', body: 'OpenAI compatible endpoint' }),
    makeNote({ id: 'n2', title: 'Cost review', body: '\u6a21\u578b\u8d39\u7528\u5bf9\u6bd4', userNote: 'focus on the cache', tags: ['billing', 'cache'] }),
    makeNote({ id: 'n3', title: 'Safari selection', body: 'long-press word selection on mobile' }),
  ];

  it('returns every note for an empty query', () => {
    expect(searchNotes(notes, '   ')).toEqual(notes);
  });

  it('matches title, body, user note and tags case-insensitively', () => {
    expect(searchNotes(notes, 'qwen').map((note) => note.id)).toEqual(['n1']);
    expect(searchNotes(notes, 'ENDPOINT').map((note) => note.id)).toEqual(['n1']);
    expect(searchNotes(notes, 'cache').map((note) => note.id)).toEqual(['n2']);
    expect(searchNotes(notes, 'billing').map((note) => note.id)).toEqual(['n2']);
  });

  it('supports continuous Chinese substrings', () => {
    expect(searchNotes(notes, '\u6a21\u578b\u8d39\u7528').map((note) => note.id)).toEqual(['n2']);
  });
});
