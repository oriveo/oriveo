/**
 * ODF (ODT / ODS / ODP) text extraction (attachment extraction output spec section 9; blocks and tables per sections 3.2 / 3.3, finally normalized per section 3.1).
 *
 * Reads only `content.xml` and dispatches on `office:text` / `office:spreadsheet` / `office:presentation` under `office:body`.
 */

import type { ExtractionDeadline } from '../extraction-deadline';
import type { Namespaces, OfficePackage } from './office-package';
import { attrNs, childElements, childNamed, isElement, isNamed, namespaces } from './office-package';
import {
  MAX_TABLE_COLUMNS,
  formatTableCell,
  headingBlock,
  joinBlocks,
  listItemBlock,
  normalizeStructuredText,
  paragraphBlock,
  spacedBlock,
  tableBlocks,
  type TextBlock,
} from './structured-text';
import { ROWS_PER_DEADLINE_CHECK, SparseGrid } from './xlsx-text-extractor';

const ODF = 'urn:oasis:names:tc:opendocument:xmlns:';
const OFFICE: Namespaces = namespaces(`${ODF}office:1.0`);
const TEXT: Namespaces = namespaces(`${ODF}text:1.0`);
const TABLE: Namespaces = namespaces(`${ODF}table:1.0`);
const DRAW: Namespaces = namespaces(`${ODF}drawing:1.0`);
const PRESENTATION: Namespaces = namespaces(`${ODF}presentation:1.0`);
const SVG: Namespaces = namespaces(`${ODF}svg-compatible:1.0`);

/** Section 9 ODS: a non-empty row is repeated at most this many times. */
const MAX_ROW_REPEAT = 100;

const SKIPPED_PRESENTATION_CLASSES = new Set(['page-number', 'date-time', 'footer', 'header']);

/** Section 9: elements skipped entirely. */
function isSkipped(element: Element): boolean {
  if (element.localName.endsWith('-source')) return true;
  if (isNamed(element, OFFICE, 'annotation') || isNamed(element, OFFICE, 'annotation-end')) return true;
  if (isNamed(element, OFFICE, 'forms')) return true;
  if (isNamed(element, TEXT, 'tracked-changes') || isNamed(element, TEXT, 'sequence-decls')
    || isNamed(element, TEXT, 'variable-decls')) return true;
  return isNamed(element, SVG, 'title') || isNamed(element, SVG, 'desc');
}

interface Note {
  citation: string;
  text: string;
}

/** Walk state of one document: footnotes are collected in order of appearance and appended after the body. */
interface OdfContext {
  notes: Note[];
}

export async function extractOdfText(pkg: OfficePackage, deadline?: ExtractionDeadline): Promise<string> {
  const doc = await pkg.requiredXml('content.xml');
  const body = doc.documentElement ? childNamed(doc.documentElement, OFFICE, 'body') : null;
  const ctx: OdfContext = { notes: [] };
  const blocks: TextBlock[] = [];
  for (const child of body ? childElements(body) : []) {
    if (isNamed(child, OFFICE, 'text')) walkTextBlocks(child, ctx, blocks, -1);
    else if (isNamed(child, OFFICE, 'spreadsheet')) spreadsheetBlocks(child, ctx, blocks, deadline);
    else if (isNamed(child, OFFICE, 'presentation')) presentationBlocks(child, ctx, blocks, deadline);
  }
  ctx.notes.forEach((note, index) => {
    blocks.push({ text: `[^${note.citation}]: ${note.text}`, spaced: false, blankBefore: index === 0 });
  });
  deadline?.check();
  return normalizeStructuredText(joinBlocks(blocks));
}

// MARK: - Inline text

/**
 * Text in a paragraph: `[ \t\n\r]+` in character data collapses to one space, and `text:s` / `text:tab` / `text:line-break` restore whitespace;
 * `text:note` outputs `[^c]` in place; `draw:frame/draw:text-box` goes into `textBoxes`, which the caller places after the paragraph.
 */
function inlineText(element: Element, ctx: OdfContext, textBoxes: Element[]): string {
  let out = '';
  for (let node = element.firstChild; node; node = node.nextSibling) {
    if (node.nodeType === 3 || node.nodeType === 4) {
      out += (node.nodeValue ?? '').replace(/[ \t\n\r]+/g, ' ');
      continue;
    }
    if (!isElement(node) || isSkipped(node)) continue;
    if (isNamed(node, TEXT, 's')) {
      const count = Number(attrNs(node, TEXT, 'c') ?? '1');
      out += ' '.repeat(Number.isInteger(count) && count > 0 ? Math.min(count, 10_000) : 1);
    } else if (isNamed(node, TEXT, 'tab')) {
      out += '\t';
    } else if (isNamed(node, TEXT, 'line-break')) {
      out += '\n';
    } else if (isNamed(node, TEXT, 'soft-page-break')) {
      // Ignored
    } else if (isNamed(node, TEXT, 'note')) {
      out += noteReference(node, ctx);
    } else if (isNamed(node, DRAW, 'frame')) {
      for (const child of childElements(node)) {
        if (isNamed(child, DRAW, 'text-box')) textBoxes.push(child);
      }
    } else {
      out += inlineText(node, ctx, textBoxes);
    }
  }
  return out;
}

function noteReference(note: Element, ctx: OdfContext): string {
  const citationElement = childNamed(note, TEXT, 'note-citation');
  const citation = (citationElement?.textContent ?? '').trim();
  const body = childNamed(note, TEXT, 'note-body');
  const text = body
    ? paragraphElements(body).map((paragraph) => inlineText(paragraph, ctx, []).trim()).filter(Boolean).join(' ')
    : '';
  ctx.notes.push({ citation, text });
  return `[^${citation}]`;
}

/** `text:p` / `text:h` in document order within a container (not descending into paragraphs). */
function paragraphElements(container: Element): Element[] {
  const out: Element[] = [];
  for (const child of childElements(container)) {
    if (isSkipped(child)) continue;
    if (isNamed(child, TEXT, 'p') || isNamed(child, TEXT, 'h')) out.push(child);
    else out.push(...paragraphElements(child));
  }
  return out;
}

// MARK: - ODT blocks

function walkTextBlocks(container: Element, ctx: OdfContext, blocks: TextBlock[], listDepth: number): void {
  for (const child of childElements(container)) {
    if (isSkipped(child)) continue;
    if (isNamed(child, TEXT, 'h')) {
      const textBoxes: Element[] = [];
      const level = Number(attrNs(child, TEXT, 'outline-level') ?? '1');
      const block = headingBlock(Number.isInteger(level) && level > 0 ? level : 1, inlineText(child, ctx, textBoxes));
      if (block) blocks.push(block);
      for (const box of textBoxes) walkTextBlocks(box, ctx, blocks, -1);
    } else if (isNamed(child, TEXT, 'p')) {
      const textBoxes: Element[] = [];
      const text = inlineText(child, ctx, textBoxes);
      const block = listDepth >= 0 ? listItemBlock(listDepth, '- ', text) : paragraphBlock(text);
      if (block) blocks.push(block);
      for (const box of textBoxes) walkTextBlocks(box, ctx, blocks, -1);
    } else if (isNamed(child, TEXT, 'list')) {
      walkTextBlocks(child, ctx, blocks, listDepth + 1);
    } else if (isNamed(child, TEXT, 'list-header')) {
      walkTextBlocks(child, ctx, blocks, -1);
    } else if (isNamed(child, TABLE, 'table')) {
      blocks.push(...documentTableBlocks(child, ctx));
    } else {
      // text:list-item, text:section, table-of-contents / index bodies and other unlisted elements: recurse and take text.
      walkTextBlocks(child, ctx, blocks, listDepth);
    }
  }
}

// MARK: - Tables

interface RowEntry {
  row: Element;
  repeat: number;
}

/** Rows may be at any depth: direct children, or inside header-rows / rows / row-group. */
function tableRowElements(table: Element): RowEntry[] {
  const out: RowEntry[] = [];
  for (const child of childElements(table)) {
    if (isNamed(child, TABLE, 'table-row')) {
      const repeat = Number(attrNs(child, TABLE, 'number-rows-repeated') ?? '1');
      out.push({ row: child, repeat: Number.isInteger(repeat) && repeat > 0 ? repeat : 1 });
    } else if (isNamed(child, TABLE, 'table-header-rows') || isNamed(child, TABLE, 'table-rows')
      || isNamed(child, TABLE, 'table-row-group')) {
      out.push(...tableRowElements(child));
    }
  }
  return out;
}

interface CellEntry {
  text: string;
  repeat: number;
}

function rowCells(row: Element, valueOf: (cell: Element) => string): CellEntry[] {
  const out: CellEntry[] = [];
  for (const cell of childElements(row)) {
    const covered = isNamed(cell, TABLE, 'covered-table-cell');
    if (!covered && !isNamed(cell, TABLE, 'table-cell')) continue;
    const repeat = Number(attrNs(cell, TABLE, 'number-columns-repeated') ?? '1');
    out.push({
      text: covered ? '' : valueOf(cell),
      repeat: Number.isInteger(repeat) && repeat > 0 ? repeat : 1,
    });
  }
  return out;
}

/** Paragraph text in a cell (`<br>` joining is done by formatTableCell); nested tables are flattened into one run (section 3.3). */
function cellParagraphs(cell: Element, ctx: OdfContext): string[] {
  const out: string[] = [];
  for (const child of childElements(cell)) {
    if (isSkipped(child)) continue;
    if (isNamed(child, TEXT, 'p') || isNamed(child, TEXT, 'h')) out.push(inlineText(child, ctx, []));
    else if (isNamed(child, TABLE, 'table')) out.push(flattenTable(child, ctx));
    else if (isNamed(child, TEXT, 'list') || isNamed(child, TEXT, 'section')) {
      out.push(...paragraphElements(child).map((paragraph) => inlineText(paragraph, ctx, [])));
    }
  }
  return out;
}

function flattenTable(table: Element, ctx: OdfContext): string {
  return tableRowElements(table)
    .map(({ row }) => rowCells(row, (cell) => cellParagraphs(cell, ctx).map((p) => p.trim()).filter(Boolean).join(' '))
      .map((cell) => cell.text)
      .join('; '))
    .join(' / ');
}

/** ODT / ODP tables are rendered as blocks per section 3.3; beyond 50 columns, N uses the width computed in full from repeat counts. */
function documentTableBlocks(table: Element, ctx: OdfContext): TextBlock[] {
  const { rows, fullColumnCount } = documentTableRows(table, ctx);
  return tableBlocks(rows, fullColumnCount);
}

/**
 * Tables in ODT / ODP: repeated empty cells / rows are materialized only when content follows; a non-empty cell repeats up to column 50, a non-empty row at most 100 times.
 */
function documentTableRows(table: Element, ctx: OdfContext): { rows: string[][]; fullColumnCount: number } {
  const rows: string[][] = [];
  let pendingRows = 0;
  // Width computed in full from repeat counts (up to the last non-empty cell), used to write `(N more columns not shown)`.
  let fullColumnCount = 0;
  for (const { row, repeat } of tableRowElements(table)) {
    const cells: string[] = [];
    let pendingCells = 0;
    let width = 0;
    for (const cell of rowCells(row, (element) => formatTableCell(cellParagraphs(element, ctx)))) {
      if (!cell.text) {
        pendingCells += cell.repeat;
        continue;
      }
      for (let i = 0; i < pendingCells && cells.length < MAX_TABLE_COLUMNS; i++) cells.push('');
      width += pendingCells + cell.repeat;
      pendingCells = 0;
      for (let i = 0; i < cell.repeat && cells.length < MAX_TABLE_COLUMNS; i++) cells.push(cell.text);
    }
    fullColumnCount = Math.max(fullColumnCount, width);
    if (cells.length === 0) {
      pendingRows += repeat;
      continue;
    }
    for (let i = 0; i < Math.min(pendingRows, MAX_ROW_REPEAT); i++) rows.push([]);
    pendingRows = 0;
    for (let i = 0; i < Math.min(repeat, MAX_ROW_REPEAT); i++) rows.push([...cells]);
  }
  // Empty rows in the middle are padded with empty cells to the widest row's width, so renderTableBlocks does not drop them as "rows without cells"; empty rows are not merged and are output line by line.
  const width = Math.max(0, ...rows.map((row) => row.length));
  return {
    rows: rows.map((row) => (row.length === 0 ? Array.from({ length: width }, () => '') : row)),
    fullColumnCount,
  };
}

// MARK: - ODS

function spreadsheetBlocks(spreadsheet: Element, ctx: OdfContext, blocks: TextBlock[], deadline?: ExtractionDeadline): void {
  for (const table of childElements(spreadsheet)) {
    if (!isNamed(table, TABLE, 'table')) continue;
    deadline?.check();
    blocks.push(spacedBlock(`## Sheet: ${attrNs(table, TABLE, 'name') ?? ''}`));
    const grid = new SparseGrid();
    let rowNumber = 0;
    let rowsSeen = 0;
    for (const { row, repeat } of tableRowElements(table)) {
      if (rowsSeen++ % ROWS_PER_DEADLINE_CHECK === 0) deadline?.check();
      const cells = rowCells(row, (element) => spreadsheetCellValue(element, ctx));
      if (!cells.some((cell) => cell.text)) {
        // Empty rows only take a row number: those outside the used range do not appear, and consecutive empty rows inside the range are compressed into one row by SparseGrid.
        rowNumber += repeat;
        continue;
      }
      // A non-empty row repeats at most 100 times; column repeats of non-empty cells are recorded as one run by SparseGrid, and only the first 50 columns are materialized.
      for (let copy = 0; copy < Math.min(repeat, MAX_ROW_REPEAT); copy++) {
        rowNumber += 1;
        let column = 1;
        for (const cell of cells) {
          if (cell.text) grid.set(rowNumber, column, cell.text, cell.repeat);
          column += cell.repeat;
        }
      }
    }
    blocks.push(...grid.render());
  }
}

/** Each `text:p` is joined with `<br>`; without `text:p`, take the string / value / date / time / boolean attributes in turn. */
function spreadsheetCellValue(cell: Element, ctx: OdfContext): string {
  const paragraphs = childElements(cell).filter((child) => isNamed(child, TEXT, 'p'));
  if (paragraphs.length > 0) return formatTableCell(paragraphs.map((paragraph) => inlineText(paragraph, ctx, [])));
  for (const name of ['string-value', 'value', 'date-value', 'time-value', 'boolean-value']) {
    const value = attrNs(cell, OFFICE, name);
    if (value !== null) return formatTableCell([value]);
  }
  return '';
}

// MARK: - ODP

function presentationBlocks(presentation: Element, ctx: OdfContext, blocks: TextBlock[], deadline?: ExtractionDeadline): void {
  let number = 0;
  for (const page of childElements(presentation)) {
    if (!isNamed(page, DRAW, 'page')) continue;
    deadline?.check();
    number += 1;
    const frames = pageFrames(page);
    const titleFrame = frames.find((frame) => frameClass(frame) === 'title') ?? null;
    const title = titleFrame
      ? frameParagraphs(titleFrame, ctx).join(' ').replace(/\n/g, ' ').trim()
      : '';
    blocks.push(spacedBlock(`## Slide ${number}${title ? `: ${title}` : ''}`));

    for (const frame of frames) {
      if (frame === titleFrame || SKIPPED_PRESENTATION_CLASSES.has(frameClass(frame) ?? '')) continue;
      for (const child of childElements(frame)) {
        if (isNamed(child, DRAW, 'text-box')) {
          for (const paragraph of paragraphElements(child)) {
            const block = paragraphBlock(inlineText(paragraph, ctx, []));
            if (block) blocks.push(block);
          }
        } else if (isNamed(child, TABLE, 'table')) {
          blocks.push(...documentTableBlocks(child, ctx));
        }
      }
    }

    const notes = childNamed(page, PRESENTATION, 'notes');
    if (notes) {
      const paragraphs: TextBlock[] = [];
      for (const frame of pageFrames(notes)) {
        if (frameClass(frame) !== 'notes') continue;
        for (const text of frameParagraphs(frame, ctx)) {
          const block = paragraphBlock(text);
          if (block) paragraphs.push(block);
        }
      }
      if (paragraphs.length > 0) blocks.push(spacedBlock('### Notes'), ...paragraphs);
    }
  }
}

/** `draw:frame` in document order on a page (descends into containers such as `draw:g`, not into `presentation:notes`). */
function pageFrames(container: Element): Element[] {
  const out: Element[] = [];
  for (const child of childElements(container)) {
    if (isSkipped(child) || isNamed(child, PRESENTATION, 'notes')) continue;
    if (isNamed(child, DRAW, 'frame')) out.push(child);
    else out.push(...pageFrames(child));
  }
  return out;
}

function frameClass(frame: Element): string | null {
  return attrNs(frame, PRESENTATION, 'class');
}

function frameParagraphs(frame: Element, ctx: OdfContext): string[] {
  const out: string[] = [];
  for (const child of childElements(frame)) {
    if (isNamed(child, DRAW, 'text-box')) {
      out.push(...paragraphElements(child).map((paragraph) => inlineText(paragraph, ctx, [])));
    }
  }
  return out;
}
