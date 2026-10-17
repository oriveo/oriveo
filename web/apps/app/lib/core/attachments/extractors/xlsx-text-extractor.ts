/**
 * XLSX text extraction (attachment extraction output spec section 6; tables per section 3.3, finally normalized per section 3.1).
 */

import type { ExtractionDeadline } from '../extraction-deadline';
import type { Namespaces, OfficePackage } from './office-package';
import { R, attrNs, childElements, childNamed, childrenNamed, isNamed, namespaces } from './office-package';
import {
  MAX_TABLE_COLUMNS,
  formatTableCell,
  joinBlocks,
  normalizeStructuredText,
  spacedBlock,
  tableBlocks,
  type TextBlock,
} from './structured-text';

const S: Namespaces = namespaces(
  'http://schemas.openxmlformats.org/spreadsheetml/2006/main',
  'http://purl.oclc.org/ooxml/spreadsheetml/main',
);

/** Section 14: XLSX / ODS check the deadline every 1000 rows. */
export const ROWS_PER_DEADLINE_CHECK = 1000;

type DateKind = 'date' | 'time' | 'datetime';

const BUILTIN_DATE_FORMATS = new Map<number, DateKind>([
  ...[14, 15, 16, 17, 27, 28, 29, 30, 31, 34, 35, 36, 50, 51, 52, 53, 54, 57, 58].map((id) => [id, 'date'] as const),
  ...[18, 19, 20, 21, 32, 33, 45, 46, 47, 55, 56].map((id) => [id, 'time'] as const),
  [22, 'datetime'],
]);

interface Workbook {
  sharedStrings: string[];
  /** cellXfs index → date kind (null if not a date). */
  styleDateKinds: (DateKind | null)[];
  date1904: boolean;
}

export async function extractXlsxText(pkg: OfficePackage, deadline?: ExtractionDeadline): Promise<string> {
  const workbookPath = await pkg.relatedPart('', '/officeDocument', 'xl/workbook.xml');
  const workbookDoc = await pkg.requiredXml(workbookPath);
  const root = workbookDoc.documentElement;
  const sharedStringsPath = await pkg.relatedPart(workbookPath, '/sharedStrings', 'xl/sharedStrings.xml');
  const stylesPath = await pkg.relatedPart(workbookPath, '/styles', 'xl/styles.xml');
  const workbookProperties = childNamed(root, S, 'workbookPr');
  const date1904 = (workbookProperties?.getAttribute('date1904') ?? '').toLowerCase();

  const workbook: Workbook = {
    sharedStrings: parseSharedStrings(await pkg.xml(sharedStringsPath)),
    styleDateKinds: parseStyleDateKinds(await pkg.xml(stylesPath)),
    date1904: date1904 === '1' || date1904 === 'true',
  };

  const relationships = new Map((await pkg.relationships(workbookPath)).map((rel) => [rel.id, rel]));
  const sheets = childNamed(root, S, 'sheets');
  const blocks: TextBlock[] = [];
  for (const sheet of sheets ? childrenNamed(sheets, S, 'sheet') : []) {
    deadline?.check();
    const state = sheet.getAttribute('state') ?? 'visible';
    if (state === 'veryHidden') continue;
    const relationship = relationships.get(attrNs(sheet, R, 'id') ?? '');
    if (!relationship || !relationship.type.endsWith('/worksheet')) continue;
    const name = sheet.getAttribute('name') ?? '';
    blocks.push(spacedBlock(`## Sheet: ${name}${state === 'hidden' ? ' (hidden)' : ''}`));
    const sheetDoc = await pkg.xml(relationship.target);
    if (sheetDoc) blocks.push(...sheetBlocks(sheetDoc, workbook, deadline));
  }
  deadline?.check();
  return normalizeStructuredText(joinBlocks(blocks));
}

// MARK: - Worksheets

function sheetBlocks(doc: Document, workbook: Workbook, deadline?: ExtractionDeadline): TextBlock[] {
  const sheetData = childNamed(doc.documentElement, S, 'sheetData');
  if (!sheetData) return [];
  const grid = new SparseGrid();
  let rowNumber = 0;
  let rowsSeen = 0;
  for (const row of childrenNamed(sheetData, S, 'row')) {
    if (rowsSeen++ % ROWS_PER_DEADLINE_CHECK === 0) deadline?.check();
    const declaredRow = Number(row.getAttribute('r') ?? 'NaN');
    rowNumber = Number.isInteger(declaredRow) && declaredRow > 0 ? declaredRow : rowNumber + 1;
    let column = 0;
    for (const cell of childrenNamed(row, S, 'c')) {
      const reference = /^([A-Za-z]+)/.exec(cell.getAttribute('r') ?? '');
      column = reference ? columnNumber(reference[1]) : column + 1;
      const text = formatTableCell([cellValue(cell, workbook)]);
      if (text) grid.set(rowNumber, column, text, 1);
    }
  }
  return grid.render();
}

/** Sparse grid recording only non-empty cells: outputs the used range, compresses consecutive empty rows in the range into one empty table row, and materializes only the first 50 columns. */
export class SparseGrid {
  private readonly rows = new Map<number, { column: number; count: number; text: string }[]>();
  private minColumn = Infinity;
  private maxColumn = -Infinity;

  /** In row `row`, `count` consecutive cells starting at column `column` all hold `text` (ODS column repeat). */
  set(row: number, column: number, text: string, count: number): void {
    let cells = this.rows.get(row);
    if (!cells) {
      cells = [];
      this.rows.set(row, cells);
    }
    cells.push({ column, count, text });
    this.minColumn = Math.min(this.minColumn, column);
    this.maxColumn = Math.max(this.maxColumn, column + count - 1);
  }

  render(): TextBlock[] {
    if (this.rows.size === 0) return [];
    const width = this.maxColumn - this.minColumn + 1;
    const shown = Math.min(width, MAX_TABLE_COLUMNS);
    const out: string[][] = [];
    let previous: number | null = null;
    for (const rowNumber of [...this.rows.keys()].sort((a, b) => a - b)) {
      if (previous !== null && rowNumber > previous + 1) out.push(Array.from({ length: shown }, () => ''));
      const cells = Array.from({ length: shown }, () => '');
      for (const { column, count, text } of this.rows.get(rowNumber)!) {
        const from = Math.max(column - this.minColumn, 0);
        const to = Math.min(column - this.minColumn + count, shown);
        for (let index = from; index < to; index++) cells[index] = text;
      }
      out.push(cells);
      previous = rowNumber;
    }
    return tableBlocks(out, width);
  }
}

/** The letter part of `C5` is read in base 26 as the column number (A = 1). */
function columnNumber(letters: string): number {
  let value = 0;
  for (const char of letters.toUpperCase()) value = value * 26 + (char.charCodeAt(0) - 64);
  return value;
}

function cellValue(cell: Element, workbook: Workbook): string {
  const type = cell.getAttribute('t') ?? 'n';
  if (type === 'inlineStr') {
    const inline = childNamed(cell, S, 'is');
    return inline ? richText(inline) : '';
  }
  const valueElement = childNamed(cell, S, 'v');
  if (!valueElement) return '';
  const raw = valueElement.textContent ?? '';
  switch (type) {
    case 's': {
      const index = Number(raw.trim());
      return Number.isInteger(index) && index >= 0 ? workbook.sharedStrings[index] ?? '' : '';
    }
    case 'b':
      return raw.trim() === '1' ? 'TRUE' : 'FALSE';
    case 'str':
    case 'e':
    case 'd':
      return raw;
    default: {
      const style = Number(cell.getAttribute('s') ?? '0');
      const kind = Number.isInteger(style) && style >= 0 ? workbook.styleDateKinds[style] ?? null : null;
      if (kind) {
        const date = formatSerialDate(raw, kind, workbook.date1904);
        if (date !== null) return date;
      }
      return normalizeNumber(raw);
    }
  }
}

// MARK: - Shared strings

function parseSharedStrings(doc: Document | null): string[] {
  if (!doc?.documentElement) return [];
  return childrenNamed(doc.documentElement, S, 'si').map(richText);
}

/** `<si>` / `<is>`: concatenate all `t` descendants in order, skip `rPh` and `phoneticPr` entirely, then decode `_xHHHH_`. */
function richText(container: Element): string {
  let out = '';
  const walk = (element: Element) => {
    for (const child of childElements(element)) {
      if (isNamed(child, S, 'rPh') || isNamed(child, S, 'phoneticPr')) continue;
      if (isNamed(child, S, 't')) out += child.textContent ?? '';
      else walk(child);
    }
  };
  walk(container);
  return decodeEscapes(out);
}

/** Decode `_xHHHH_` into characters left to right; decoded characters take no further part in matching (`_x005F_x000D_` → `_x000D_`). */
export function decodeEscapes(text: string): string {
  return text.replace(/_x([0-9A-Fa-f]{4})_/g, (_match, hex: string) => String.fromCharCode(parseInt(hex, 16)));
}

// MARK: - Number normalization

const NUMBER_PATTERN = /^(-?)(\d+)(?:\.(\d+))?([eE][+-]?\d+)?$/;
const SIGNIFICANT_DIGITS = 15;

/** Section 6 number normalization: pure string arithmetic; beyond 15 significant digits, round (.5 away from zero) to 15 digits. */
export function normalizeNumber(raw: string): string {
  const match = NUMBER_PATTERN.exec(raw);
  if (!match) return raw;
  const [, sign, integer, fraction = '', exponent = ''] = match;
  const digits = (integer + fraction).split('').map(Number);
  const lead = digits.findIndex((digit) => digit !== 0);
  if (lead < 0 || digits.length - lead <= SIGNIFICANT_DIGITS) return raw;

  const keep = lead + SIGNIFICANT_DIGITS;
  const roundUp = digits[keep] >= 5;
  for (let index = keep; index < digits.length; index++) digits[index] = 0;
  let integerLength = integer.length;
  if (roundUp) {
    let index = keep - 1;
    while (index >= 0 && digits[index] === 9) {
      digits[index] = 0;
      index--;
    }
    if (index >= 0) digits[index] += 1;
    else {
      digits.unshift(1);
      integerLength += 1;
    }
  }
  const integerPart = digits.slice(0, integerLength).join('');
  const fractionPart = digits.slice(integerLength).join('').replace(/0+$/, '');
  return `${sign}${integerPart}${fractionPart ? `.${fractionPart}` : ''}${exponent}`;
}

// MARK: - Dates

function parseStyleDateKinds(doc: Document | null): (DateKind | null)[] {
  if (!doc?.documentElement) return [];
  const custom = new Map<number, string>();
  const numFmts = childNamed(doc.documentElement, S, 'numFmts');
  for (const format of numFmts ? childrenNamed(numFmts, S, 'numFmt') : []) {
    const id = Number(format.getAttribute('numFmtId') ?? 'NaN');
    if (Number.isInteger(id) && !custom.has(id)) custom.set(id, format.getAttribute('formatCode') ?? '');
  }
  const cellXfs = childNamed(doc.documentElement, S, 'cellXfs');
  return (cellXfs ? childrenNamed(cellXfs, S, 'xf') : []).map((xf) => {
    const id = Number(xf.getAttribute('numFmtId') ?? '0');
    if (!Number.isInteger(id)) return null;
    const builtin = BUILTIN_DATE_FORMATS.get(id);
    if (builtin) return builtin;
    const code = custom.get(id);
    return code === undefined ? null : classifyFormatCode(code);
  });
}

/** Section 6 custom format detection. */
export function classifyFormatCode(formatCode: string): DateKind | null {
  const section = formatCode.split(';')[0]
    .replace(/"[^"]*"?/g, '')
    .replace(/\\./g, '')
    .replace(/_./g, '')
    .replace(/\*./g, '')
    .replace(/\[(h{1,2}|m{1,2}|s{1,2})\]/gi, '$1')
    .replace(/\[[^\]]*\]?/g, '')
    .toLowerCase();
  const hasDate = /[yd\u5E74\u6708\u65E5]/.test(section);
  const hasTime = /[hs\u65F6\u6642\u5206\u79D2]/.test(section);
  if (hasDate && hasTime) return 'datetime';
  if (hasDate) return 'date';
  if (hasTime) return 'time';
  return section.includes('m') ? 'date' : null;
}

const DAY_MS = 86_400_000;

/** Section 6 date conversion (UTC throughout); returns null if `<v>` fails to parse or is negative (not treated as a date). */
export function formatSerialDate(raw: string, kind: DateKind, date1904: boolean): string | null {
  const text = raw.trim();
  if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(text)) return null;
  const serial = Number(text);
  if (!Number.isFinite(serial) || serial < 0) return null;
  let days = Math.floor(serial);
  let seconds = Math.round((serial - days) * 86_400);
  if (seconds === 86_400) {
    days += 1;
    seconds = 0;
  }

  let date: string;
  if (date1904) date = isoDate(Date.UTC(1904, 0, 1) + days * DAY_MS);
  else if (days === 60) date = '1900-02-29';
  else if (days < 60) date = isoDate(Date.UTC(1899, 11, 31) + days * DAY_MS);
  else date = isoDate(Date.UTC(1899, 11, 30) + days * DAY_MS);

  const pad = (value: number) => String(value).padStart(2, '0');
  const time = `${pad(Math.floor(seconds / 3600))}:${pad(Math.floor((seconds % 3600) / 60))}:${pad(seconds % 60)}`;
  if (kind === 'date') return date;
  if (kind === 'time') return time;
  return `${date} ${time}`;
}

function isoDate(ms: number): string {
  const date = new Date(ms);
  const year = date.getUTCFullYear();
  const yearText = year >= 0 && year <= 9999 ? String(year).padStart(4, '0') : String(year);
  return `${yearText}-${String(date.getUTCMonth() + 1).padStart(2, '0')}-${String(date.getUTCDate()).padStart(2, '0')}`;
}
