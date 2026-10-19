import { describe, expect, it } from 'vitest';
import { normalizeKnowledgeSnippets, type KnowledgeSnippet } from '../skill-knowledge';

describe('skill-knowledge helpers', () => {
  it('deduplicates repeated file_search results and clips each snippet to the configured size', () => {
    const input: KnowledgeSnippet[] = [
      { fileId: 'file-1', fileName: 'guide.md', text: 'Alpha Alpha', score: 0.91 },
      { fileId: 'file-1', fileName: 'guide.md', text: 'Alpha Alpha', score: 0.90 },
      { fileId: 'file-2', fileName: 'faq.md', text: 'B'.repeat(20), score: 0.88 },
    ];

    expect(
      normalizeKnowledgeSnippets(input, {
        maxResults: 6,
        maxSnippetChars: 10,
        maxTotalSnippetChars: 25,
      }),
    ).toEqual([
      { fileId: 'file-1', fileName: 'guide.md', text: 'Alpha Alph', score: 0.91 },
      { fileId: 'file-2', fileName: 'faq.md', text: 'BBBBBBBBBB', score: 0.88 },
    ]);
  });
});
