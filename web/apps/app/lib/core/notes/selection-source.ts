/**
 * Selection capture: map the plain text of a rendered selection back to the source markdown.
 *
 * window.getSelection().toString() returns rendered plain text - the browser flattens a table into
 * whitespace-joined cells, and code and list structure is lost. At capture time the full source
 * markdown is available (message.text, which is also where bodySnapshot comes from). This module
 * splits the source into blocks, locates the lines the selection actually covers and returns the
 * corresponding raw markdown, so MarkdownRenderer renders tables, code and lists faithfully.
 *
 * Precision:
 * - Tables: only the selected rows, with the header and separator rows added back, so selecting 2
 *   of 10 rows yields those 2 rows as a valid table.
 * - Lists and headings: only the selected lines.
 * - Code blocks: kept whole. Stripping the fences off a partial block breaks both rendering and
 *   context, so a block is deliberately atomic.
 * Conservative by design: a result is returned only when it really contains structure (table, code,
 * list, heading). A pure prose selection returns null and the caller keeps the user's exact
 * selection, which rendered plain text already reproduces faithfully.
 */

interface SourceBlock {
  raw: string;
  start: number;
  end: number;
  sig: string;
}

const MIN_SIG_LENGTH = 8;

/**
 * Normalize to a content signature: keep letters, digits and CJK code points only, dropping
 * whitespace and all structural punctuation, so rendered plain text and source markdown can be
 * compared at the content level. Table pipes, |---| separators and code fences do not count.
 */
function contentSignature(text: string): string {
  let sig = '';
  for (const ch of text.toLowerCase()) {
    if (/[\p{L}\p{N}]/u.test(ch)) sig += ch;
  }
  return sig;
}

/** Split on blank lines. A fenced code block (``` or ~~~) is atomic and is not split on its internal blank lines. Block start/end are offsets into the source. */
function splitSourceBlocks(md: string): SourceBlock[] {
  const blocks: SourceBlock[] = [];
  const lines = md.split('\n');
  let offset = 0;
  let cur: { start: number; lines: string[] } | null = null;
  let inFence = false;
  let fenceMarker = '';

  const flush = () => {
    if (!cur) return;
    const raw = cur.lines.join('\n');
    if (raw.trim()) {
      blocks.push({ raw, start: cur.start, end: cur.start + raw.length, sig: contentSignature(raw) });
    }
    cur = null;
  };

  for (const line of lines) {
    const lineStart = offset;
    offset += line.length + 1; // + '\n'
    const fence = /^\s*(```|~~~)/.exec(line);

    if (inFence) {
      cur ??= { start: lineStart, lines: [] };
      cur.lines.push(line);
      if (fence && line.trim().startsWith(fenceMarker)) inFence = false;
      continue;
    }
    if (fence) {
      cur ??= { start: lineStart, lines: [] };
      cur.lines.push(line);
      inFence = true;
      fenceMarker = fence[1];
      continue;
    }
    if (line.trim() === '') {
      flush();
      continue;
    }
    cur ??= { start: lineStart, lines: [] };
    cur.lines.push(line);
  }
  flush();
  return blocks;
}

/** Whether the extracted fragment contains structure that flattening would lose: table, code fence, list, heading or math. */
function hasStructure(md: string): boolean {
  return (
    /(^|\n)[^\n]*\|[^\n]*\|/.test(md) ||      // table row
    /(^|\n)\s*(```|~~~)/.test(md) ||           // code fence
    /(^|\n)\s*([-*+]|\d+\.)\s+/.test(md) ||    // list
    /(^|\n)\s*#{1,6}\s+/.test(md) ||           // heading
    /\$\$[\s\S]+?\$\$/.test(md) ||             // block math
    /(^|[^$])\$[^$\n]+?\$(?!\$)/.test(md)      // inline math, written without lookbehind for older Safari
  );
}

function isSeparatorRow(line: string): boolean {
  const t = line.trim();
  return t.includes('|') && /-/.test(t) && /^\|?[\s:|-]+\|?$/.test(t);
}

/** Find the three table parts in a block: header row, separator row and data rows. Returns null when the block has no table. */
function findTableParts(blockRaw: string): { header: string; separator: string; bodyRows: string[] } | null {
  const lines = blockRaw.split('\n').filter((line) => line.trim() !== '');
  for (let i = 1; i < lines.length; i += 1) {
    if (!isSeparatorRow(lines[i]) || !lines[i - 1].includes('|')) continue;
    const header = lines[i - 1];
    const bodyRows: string[] = [];
    for (let j = i + 1; j < lines.length; j += 1) {
      if (!lines[j].includes('|')) break;
      bodyRows.push(lines[j]);
    }
    if (bodyRows.length === 0) return null;
    return { header, separator: lines[i], bodyRows };
  }
  return null;
}

/** Locate the selection over [signature, owner line] units and return the covered owner range [min, max] inclusive; null when nothing matches or only negative owners do. */
function locateCovered(units: Array<{ sig: string; owner: number }>, selSig: string): { min: number; max: number } | null {
  let concat = '';
  const owner: number[] = [];
  for (const unit of units) {
    for (const ch of unit.sig) {
      concat += ch;
      owner.push(unit.owner);
    }
  }
  const at = concat.indexOf(selSig);
  if (at < 0) return null;
  let min = Infinity;
  let max = -1;
  for (let k = at; k < at + selSig.length; k += 1) {
    const o = owner[k];
    if (o >= 0) {
      min = Math.min(min, o);
      max = Math.max(max, o);
    }
  }
  return max >= 0 ? { min, max } : null;
}

/** Tables: take only the selected data rows and add the header and separator back, producing a valid sub-table. */
function extractTableRowSelection(blockRaw: string, selSig: string): string | null {
  const parts = findTableParts(blockRaw);
  if (!parts) return null;
  const { header, separator, bodyRows } = parts;
  const units = [
    { sig: contentSignature(header), owner: -1 }, // the header is excluded from the selected range and only takes part in matching
    ...bodyRows.map((row, i) => ({ sig: contentSignature(row), owner: i })),
  ];
  const covered = locateCovered(units, selSig);
  if (!covered) return null;
  const selectedRows = bodyRows.slice(covered.min, covered.max + 1);
  return [header, separator, ...selectedRows].join('\n');
}

/** Lists, headings and the like: take only the selected lines. */
function extractLineSelection(blockRaw: string, selSig: string): string | null {
  const lines = blockRaw.split('\n');
  const covered = locateCovered(
    lines.map((line, i) => ({ sig: contentSignature(line), owner: i })),
    selSig,
  );
  if (!covered) return null;
  const selected = lines.slice(covered.min, covered.max + 1).join('\n').trim();
  return selected && hasStructure(selected) ? selected : null;
}

/** Exact extraction within one block: a code block is returned whole, a table goes by row plus header, lists and headings by line. */
function refineSingleBlock(blockRaw: string, selSig: string): string | null {
  if (/^\s*(```|~~~)/m.test(blockRaw)) {
    // Code blocks are atomic: stripping the fences off a partial block breaks rendering and context, so the whole block is stored.
    return blockRaw.trim();
  }
  return extractTableRowSelection(blockRaw, selSig) ?? extractLineSelection(blockRaw, selSig);
}

/**
 * Map a rendered selection back to source markdown. Returns the raw markdown when the match
 * contains structure, accurate to the line; otherwise null.
 */
export function extractSelectionMarkdown(sourceMarkdown: string, renderedSelection: string): string | null {
  const selSig = contentSignature(renderedSelection);
  if (selSig.length < MIN_SIG_LENGTH) return null;

  const blocks = splitSourceBlocks(sourceMarkdown);
  if (blocks.length === 0) return null;

  const matched = locateCovered(
    blocks.map((block, i) => ({ sig: block.sig, owner: i })),
    selSig,
  );
  if (!matched) return null;

  // Single block -> line accurate (tables by row, lists by item, code whole), so selecting 2 of 10 rows captures those rows rather than the whole table.
  if (matched.min === matched.max) {
    const refined = refineSingleBlock(blocks[matched.min].raw, selSig);
    if (refined) return refined;
  }

  // Spanning several blocks -> take the full source of the covered blocks, falling back to block granularity when structure crosses blocks.
  const extracted = sourceMarkdown.slice(blocks[matched.min].start, blocks[matched.max].end).trim();
  if (!extracted || !hasStructure(extracted)) return null;
  return extracted;
}
