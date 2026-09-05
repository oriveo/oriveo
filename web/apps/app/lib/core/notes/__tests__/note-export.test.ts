import { describe, expect, it } from 'vitest';
import type { Note } from '@oriveo/shared';
import {
  buildNoteMarkdown,
  buildNoteMarkdownFilename,
  sanitizeNoteFilenamePart,
} from '../note-export';

function makeNote(overrides: Partial<Note>): Note {
  return {
    id: overrides.id ?? 'note-1',
    title: overrides.title ?? 'Answer title',
    titleSource: overrides.titleSource ?? 'manual',
    body: overrides.body ?? 'Body **markdown**',
    userNote: overrides.userNote,
    tags: overrides.tags ?? [],
    captureKind: overrides.captureKind ?? 'fullAnswer',
    sourceModelName: overrides.sourceModelName,
    sourceProviderName: overrides.sourceProviderName,
    sourcePrompt: overrides.sourcePrompt,
    createdAt: overrides.createdAt ?? '2026-06-10T08:30:00.000Z',
    updatedAt: overrides.updatedAt ?? '2026-06-10T08:30:00.000Z',
  };
}

describe('buildNoteMarkdown', () => {
  it('exports title, user note, body, tags and source footnote', () => {
    const markdown = buildNoteMarkdown(makeNote({
      userNote: 'Keep this for release notes',
      tags: ['release', 'web'],
      sourceModelName: 'GPT-5.4',
      sourceProviderName: 'OpenAI',
      sourcePrompt: 'Summarize the change',
    }), 'Untitled');

    expect(markdown).toContain('# Answer title');
    expect(markdown).toContain('> Keep this for release notes');
    expect(markdown).toContain('Body **markdown**');
    expect(markdown).toContain('Tags: release, web');
    expect(markdown).toContain('Source: GPT-5.4 - OpenAI - 2026-06-10');
    expect(markdown).toContain('Prompt: Summarize the change');
  });

  it('omits source for blank notes', () => {
    const markdown = buildNoteMarkdown(makeNote({ captureKind: 'blank', sourceModelName: undefined }), 'Untitled');

    expect(markdown).not.toContain('Source:');
  });
});

describe('note export filenames', () => {
  it('sanitizes illegal filename characters and truncates long text', () => {
    expect(sanitizeNoteFilenamePart('a/b\\c:d*e?f"g<h>i|j\nk')).toBe('a-b-c-d-e-f-g-h-i-j k');
    expect(sanitizeNoteFilenamePart('x'.repeat(120))).toHaveLength(80);
  });

  it('uses fallback title and note date', () => {
    expect(buildNoteMarkdownFilename(makeNote({ title: '' }), 'Untitled')).toBe('Untitled-2026-06-10.md');
  });
});
