import { graphemeCount, takeGraphemes } from '../../utils/grapheme-utils';

export interface KnowledgeSnippet {
  fileId: string;
  fileName: string;
  text: string;
  score: number;
}

export interface ReferencePromptFile {
  fileName: string;
  content: string;
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

export function applySkillKnowledgeBudget(params: {
  referenceFiles: ReferencePromptFile[];
  retrievalSnippets: KnowledgeSnippet[];
  maxPromptChars: number;
}): {
  referenceFiles: ReferencePromptFile[];
  retrievalSnippets: KnowledgeSnippet[];
} {
  let remainingChars = Math.max(0, params.maxPromptChars);

  const totalReferenceChars = params.referenceFiles.reduce(
    (sum, file) => sum + graphemeCount(file.content),
    0,
  );
  const totalSnippetChars = params.retrievalSnippets.reduce(
    (sum, snippet) => sum + graphemeCount(snippet.text),
    0,
  );
  let overflow = Math.max(0, totalReferenceChars + totalSnippetChars - remainingChars);

  const trimmedSnippets = params.retrievalSnippets
    .map((snippet) => {
      if (overflow <= 0) return snippet;
      const snippetChars = graphemeCount(snippet.text);
      if (overflow >= snippetChars) {
        overflow -= snippetChars;
        return null;
      }
      const keepChars = snippetChars - overflow;
      overflow = 0;
      return {
        ...snippet,
        text: takeGraphemes(snippet.text, keepChars),
      };
    })
    .filter((snippet): snippet is KnowledgeSnippet => Boolean(snippet));

  const trimmedReferences = params.referenceFiles
    .map((file) => {
      if (overflow <= 0) return file;
      const fileChars = graphemeCount(file.content);
      if (overflow >= fileChars) {
        overflow -= fileChars;
        return null;
      }
      const keepChars = fileChars - overflow;
      overflow = 0;
      return {
        ...file,
        content: takeGraphemes(file.content, keepChars),
      };
    })
    .filter((file): file is ReferencePromptFile => Boolean(file));

  return {
    referenceFiles: trimmedReferences,
    retrievalSnippets: trimmedSnippets,
  };
}
