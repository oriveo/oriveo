import { describe, expect, it } from 'vitest';
import {
  applySkillKnowledgeBudget,
  normalizeKnowledgeSnippets,
  type KnowledgeSnippet,
  type ReferencePromptFile,
} from '../skill-knowledge';

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

  it('trims retrieval snippets before reference files when the context budget is tight', () => {
    const referenceFiles: ReferencePromptFile[] = [
      { fileName: 'reference.md', content: 'R'.repeat(1000) },
    ];
    const retrievalSnippets: KnowledgeSnippet[] = [
      { fileId: 'file-1', fileName: 'kb.md', text: 'K'.repeat(800), score: 0.91 },
    ];

    expect(
      applySkillKnowledgeBudget({
        referenceFiles,
        retrievalSnippets,
        maxPromptChars: 900,
      }),
    ).toEqual({
      referenceFiles: [{ fileName: 'reference.md', content: 'R'.repeat(900) }],
      retrievalSnippets: [],
    });
  });
});
