function stripControlChars(text: string): string {
  return Array.from(text)
    .filter((char) => {
      const code = char.codePointAt(0);
      if (code === undefined) return false;
      if (code === 0xFFFD || code === 0xFFFC || code === 0x7F) return false;
      return !(code < 0x20 && char !== '\n' && char !== '\r' && char !== '\t');
    })
    .join('');
}

function stripMarkdownInlineMarkers(text: string): string {
  return text
    .replace(/`([^`]+)`/g, '$1')
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\[([^\]]*)\]\(([^)]*)\)/g, '$1')
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/__(.+?)__/g, '$1')
    .replace(/(^|\s)\*([^*]+)\*(?=\s|$|[.,!?;:])/g, '$1$2')
    .replace(/(^|\s)_([^_]+)_(?=\s|$|[.,!?;:])/g, '$1$2')
    .replace(/~~(.+?)~~/g, '$1');
}

function stripMarkdownBlockMarkers(text: string): string {
  return text
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/^>\s?/gm, '')
    .replace(/^[-*]\s+/gm, '')
    .replace(/^\d+\.\s+/gm, '');
}

/**
 * Table preview: drop the |---|:--:| separator row, strip the leading and trailing pipes from
 * data rows, and collapse inner pipes to spaces. Otherwise a one-line preview leaks raw markdown
 * such as "| a | b | |---|---| | hello | world |", which is ugly and hard to read.
 */
function stripMarkdownTableMarkers(text: string): string {
  return text
    .split('\n')
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed.includes('|')) return line;
      if (/^\|?[\s:|-]+\|?$/.test(trimmed)) return ''; // Separator row: only | : - and spaces.
      return line.replace(/^\s*\|/, '').replace(/\|\s*$/, '').replace(/\s*\|\s*/g, ' ');
    })
    .join('\n');
}

/**
 * Strip math delimiters while keeping the LaTeX content: the preview does not render formulas,
 * and bare `$..$` / `$$..$$` reads badly. Preview only - clipboard and note bodies keep the
 * delimiters, since the detail view renders them with KaTeX.
 */
function stripMathDelimiters(text: string): string {
  return text
    .replace(/\$\$([\s\S]+?)\$\$/g, '$1')
    .replace(/(^|[^$])\$([^$\n]+?)\$(?!\$)/g, '$1$2');
}

/**
 * Strip common Markdown markers and keep readable plain text for conversation list previews.
 * All whitespace collapses to a single space, which suits a one-line preview.
 */
export function stripMarkdownForPreview(text: string): string {
  const cleaned = stripControlChars(text);
  // Remove paired fenced code blocks first, then any unclosed fence: callers often slice the
  // text first (note and conversation list previews), which cuts off the trailing fence and
  // leaves a half-open block exposed.
  const noFences = cleaned.replace(/```[\s\S]*?```/g, ' ').replace(/```[\s\S]*$/, ' ');
  const noTables = stripMarkdownTableMarkers(noFences);

  return stripMarkdownBlockMarkers(stripMarkdownInlineMarkers(stripMathDelimiters(noTables)))
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * For clipboard copies: strip Markdown markers but keep paragraph and line structure.
 * Unlike stripMarkdownForPreview, fenced code blocks keep their code and lose only the fences,
 * newlines between paragraphs are preserved, and only runs of spaces within a line collapse.
 */
export function stripMarkdownForClipboard(text: string): string {
  const cleaned = stripControlChars(text);

  const fencedReplaced = cleaned
    .replace(/```[a-zA-Z0-9_-]*\n?([\s\S]*?)```/g, (_, code: string) => code.trimEnd())
    // Unclosed fence, which happens when a caller slices the text and cuts off the closing one: drop the opening marker and keep the code.
    .replace(/```[a-zA-Z0-9_-]*\n?/g, '');

  return stripMarkdownBlockMarkers(stripMarkdownInlineMarkers(fencedReplaced))
    .replace(/[ \t]+/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .replace(/^ +| +$/gm, '')
    .trim();
}
