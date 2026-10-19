import { graphemeCount, takeGraphemes } from '../../utils/grapheme-utils';

export interface KnowledgeSnippet {
  fileId: string;
  fileName: string;
  text: string;
  score: number;
}

interface SnippetLimits {
  maxResults: number;
  maxSnippetChars: number;
  maxTotalSnippetChars: number;
}

export function normalizeKnowledgeSnippets(
  snippets: KnowledgeSnippet[],
  limits: SnippetLimits,
): KnowledgeSnippet[] {
  const unique: KnowledgeSnippet[] = [];
  const seen = new Set<string>();
  let remainingChars = limits.maxTotalSnippetChars;

  for (const snippet of snippets) {
    if (unique.length >= limits.maxResults || remainingChars <= 0) {
      break;
    }

    const text = snippet.text.trim();
    if (!text) continue;

    const key = `${snippet.fileId}\u0000${text}`;
    if (seen.has(key)) continue;

    const clipLimit = Math.min(limits.maxSnippetChars, remainingChars);
    const clippedText = takeGraphemes(text, clipLimit);
    if (!clippedText.trim()) continue;

    seen.add(key);
    unique.push({
      ...snippet,
      text: clippedText,
    });
    remainingChars -= graphemeCount(clippedText);
  }

  return unique;
}
