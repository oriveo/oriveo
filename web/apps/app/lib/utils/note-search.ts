import type { Note } from '@oriveo/shared';

function haystack(note: Note): string {
  return [
    note.title,
    note.body,
    note.userNote,
    ...(note.tags ?? []),
  ]
    .filter((value): value is string => typeof value === 'string' && value.length > 0)
    .join('\n')
    .toLowerCase();
}

export function searchNotes(notes: Note[], query: string): Note[] {
  const normalizedQuery = query.trim().toLowerCase();
  if (!normalizedQuery) return notes;
  return notes.filter((note) => haystack(note).includes(normalizedQuery));
}
