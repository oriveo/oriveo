import type { Note } from '@oriveo/shared';

export type NoteSortKey = 'createdAt' | 'updatedAt' | 'sourceProviderKind';

function timeValue(iso: string | undefined): number {
  const value = iso ? Date.parse(iso) : 0;
  return Number.isFinite(value) ? value : 0;
}

function compareBySortKey(a: Note, b: Note, sortKey: NoteSortKey): number {
  if (sortKey === 'sourceProviderKind') {
    const providerCompare = (a.sourceProviderKind ?? '').localeCompare(b.sourceProviderKind ?? '');
    if (providerCompare !== 0) return providerCompare;
    return timeValue(b.updatedAt) - timeValue(a.updatedAt);
  }
  return timeValue(b[sortKey]) - timeValue(a[sortKey]);
}

export function sortNotes(notes: Note[], sortKey: NoteSortKey): Note[] {
  return [...notes].sort((a, b) => {
    const pinnedA = a.isPinned === true;
    const pinnedB = b.isPinned === true;
    if (pinnedA !== pinnedB) return pinnedA ? -1 : 1;
    const primary = compareBySortKey(a, b, sortKey);
    if (primary !== 0) return primary;
    return a.title.localeCompare(b.title);
  });
}

export function getAllNoteTags(notes: Note[]): string[] {
  const tags = new Set<string>();
  for (const note of notes) {
    for (const rawTag of note.tags ?? []) {
      const tag = rawTag.trim();
      if (tag) tags.add(tag);
    }
  }
  return [...tags].sort((a, b) => a.localeCompare(b));
}

export function getSuggestedNoteTags(notes: Note[], existingTags: string[], limit = 12): string[] {
  const existing = new Set(existingTags.map((tag) => tag.trim().toLocaleLowerCase()).filter(Boolean));
  const seen = new Set<string>();
  const suggestions: string[] = [];
  for (const note of notes) {
    for (const rawTag of note.tags ?? []) {
      const tag = rawTag.trim();
      const key = tag.toLocaleLowerCase();
      if (!tag || existing.has(key) || seen.has(key)) continue;
      seen.add(key);
      suggestions.push(tag);
      if (suggestions.length >= limit) return suggestions;
    }
  }
  return suggestions;
}

export function filterNotesByTags(notes: Note[], selectedTags: string[]): Note[] {
  const activeTags = selectedTags.map((tag) => tag.trim()).filter(Boolean);
  if (activeTags.length === 0) return notes;
  return notes.filter((note) => {
    const noteTags = new Set((note.tags ?? []).map((tag) => tag.trim()));
    return activeTags.every((tag) => noteTags.has(tag));
  });
}
