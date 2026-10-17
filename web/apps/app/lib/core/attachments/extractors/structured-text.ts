/**
 * Output rules shared by structured formats (attachment extraction output spec section 3.1 normalization, section 3.3 tables).
 *
 * HTML / EPUB / RTF and later Office extractors all go through here before truncation, keeping all three platforms byte for byte identical.
 */

/** Spec section 3.3: a table with more columns than this keeps only the first ones. */
export const MAX_TABLE_COLUMNS = 50;

/**
 * Spec section 3.1: `\r\n` / `\r` → `\n`, U+00A0 → space, strip trailing spaces and `\t` on each line, collapse 3 or more `\n` into 2, trim the whole text.
 */
export function normalizeStructuredText(text: string): string {
  return text
    .replace(/\r\n?/g, '\n')
    .replace(/ /g, ' ')
    .replace(/[ \t]+$/gm, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/**
 * Cell text per spec section 3.3: trim each paragraph, drop empty ones, join with `<br>`; leftover newlines → `<br>`, `\t` → space, `|` → `\|`, finally trim.
 */
export function formatTableCell(paragraphs: readonly string[]): string {
  return paragraphs
    .map((paragraph) => paragraph.trim())
    .filter((paragraph) => paragraph.length > 0)
    .join('<br>')
    .replace(/\r\n|\r|\n/g, '<br>')
    .replace(/\t/g, ' ')
    .replace(/\|/g, '\\|')
    .trim();
}

/**
 * Spec section 3.3: render cells already processed by {@link formatTableCell} as blocks.
 *
 * When `fullColumnCount` is given, N in `(N more columns not shown)` is computed from it (XLSX / ODS materialize only the first 50 columns).
 *
 * Returns 0 blocks (a fully empty table is dropped), 1 paragraph (1 row by 1 column, `<br>` restored to `\n`),
 * or 1 pipe table (followed by a `(N more columns not shown)` paragraph when over 50 columns).
 */
export function renderTableBlocks(rows: readonly (readonly string[])[], fullColumnCount?: number): string[] {
  const nonEmptyRows = rows.filter((row) => row.length > 0);
  if (nonEmptyRows.length === 0) return [];
  if (nonEmptyRows.every((row) => row.every((cell) => cell.length === 0))) return [];

  // fullColumnCount: when the caller supplies only the first 50 columns (the width computed from repeat counts is far larger), this gives the full width.
  const columnCount = Math.max(fullColumnCount ?? 0, ...nonEmptyRows.map((row) => row.length));
  if (nonEmptyRows.length === 1 && columnCount === 1) {
    return [nonEmptyRows[0][0].replace(/<br>/g, '\n')];
  }

  const shownColumns = Math.min(columnCount, MAX_TABLE_COLUMNS);
  const line = (cells: readonly string[]) => `| ${cells.join(' | ')} |`;
  const lines: string[] = [];
  nonEmptyRows.forEach((row, index) => {
    const cells = Array.from({ length: shownColumns }, (_, column) => row[column] ?? '');
    lines.push(line(cells));
    if (index === 0) lines.push(line(Array.from({ length: shownColumns }, () => '---')));
  });

  const blocks = [lines.join('\n')];
  if (columnCount > MAX_TABLE_COLUMNS) {
    blocks.push(`(${columnCount - MAX_TABLE_COLUMNS} more columns not shown)`);
  }
  return blocks;
}

/**
 * Blocks from spec section 3.2. `spaced` covers headings, tables, section headings, notes headings and page markers: a blank line separates them from adjacent blocks;
 * between two plain blocks (paragraph, list item) there is only a line break. `blankBefore` forces a blank line before this block (the first footnote entry).
 */
export interface TextBlock {
  text: string;
  spaced: boolean;
  blankBefore?: boolean;
}

/** Spec section 3.2: join with `\n` or `\n\n` depending on the block kind. */
export function joinBlocks(blocks: readonly TextBlock[]): string {
  let out = '';
  blocks.forEach((block, index) => {
    if (index > 0) {
      const previous = blocks[index - 1];
      out += previous.spaced || block.spaced || block.blankBefore ? '\n\n' : '\n';
    }
    out += block.text;
  });
  return out;
}

/** Spec section 3.2 paragraph: trim spaces and `\t`; return null if empty afterwards (block dropped). `\n` inside the paragraph is kept. */
export function paragraphBlock(text: string): TextBlock | null {
  const trimmed = text.replace(/^[ \t]+|[ \t]+$/g, '');
  return trimmed.length > 0 ? { text: trimmed, spaced: false } : null;
}

/** Spec section 3.2 heading: `#` x min(level, 6) + space + text (`\n` `\t` become spaces, then trim); null if empty. */
export function headingBlock(level: number, text: string): TextBlock | null {
  const flat = text.replace(/[\n\t]/g, ' ').trim();
  if (!flat) return null;
  return { text: `${'#'.repeat(Math.min(Math.max(level, 1), 6))} ${flat}`, spaced: true };
}

/** Spec section 3.2 list item: two spaces x depth + marker + text (`\n` becomes a space); null if the text is empty. */
export function listItemBlock(depth: number, marker: string, text: string): TextBlock | null {
  const flat = text.replace(/\n/g, ' ').trim();
  if (!flat) return null;
  return { text: `${'  '.repeat(Math.max(depth, 0))}${marker}${flat}`, spaced: false };
}

/** Blocks such as section headings and notes headings that have a blank line before and after. */
export function spacedBlock(text: string): TextBlock {
  return { text, spaced: true };
}

/**
 * Tables per spec section 3.3 rendered as blocks: a pipe table is a spaced block; the paragraph a 1x1 table degenerates into, and `(N more columns not shown)`, are plain paragraphs.
 */
export function tableBlocks(rows: readonly (readonly string[])[], fullColumnCount?: number): TextBlock[] {
  const rendered = renderTableBlocks(rows, fullColumnCount);
  if (rendered.length === 0) return [];
  const nonEmptyRows = rows.filter((row) => row.length > 0);
  const singleCell = nonEmptyRows.length === 1
    && Math.max(fullColumnCount ?? 0, ...nonEmptyRows.map((row) => row.length)) === 1;
  if (singleCell) return [{ text: rendered[0], spaced: false }];
  return rendered.map((text, index) => ({ text, spaced: index === 0 }));
}
