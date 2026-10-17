/**
 * DOCX text extraction (attachment extraction output spec section 5; blocks and tables per sections 3.2 / 3.3, finally normalized per section 3.1).
 */

import type { OfficePackage, Namespaces } from './office-package';
import {
  MC,
  attrNs,
  childElements,
  childNamed,
  childrenNamed,
  firstChoice,
  inNamespace,
  isNamed,
  namespaces,
} from './office-package';
import {
  formatTableCell,
  headingBlock,
  joinBlocks,
  listItemBlock,
  normalizeStructuredText,
  paragraphBlock,
  tableBlocks,
  type TextBlock,
} from './structured-text';

const W: Namespaces = namespaces(
  'http://schemas.openxmlformats.org/wordprocessingml/2006/main',
  'http://purl.oclc.org/ooxml/wordprocessingml/main',
);

/** Elements skipped entirely among paragraph descendants (section 5); `sdtPr` / `sdtEndPr` are content control properties, not content. */
const SKIPPED_INLINE = new Set([
  'del', 'moveFrom', 'pPr', 'rPr', 'delText', 'instrText', 'fldData', 'sdtPr', 'sdtEndPr',
  'footnoteRef', 'endnoteRef',
]);

/** Output elements not taken while a field is in the "instruction" state (section 5). */
const MUTED_IN_INSTRUCTION = new Set([
  't', 'tab', 'br', 'cr', 'noBreakHyphen', 'footnoteReference', 'endnoteReference', 'txbxContent',
]);

const MAX_STYLE_DEPTH = 10;

interface StyleInfo {
  name: string | null;
  basedOn: string | null;
  /** Value of the style's `w:pPr/w:outlineLvl`; null if the element is absent. */
  outlineLevel: number | null;
}

interface LevelInfo {
  format: string | null;
  start: number;
}

interface Numbering {
  numToAbstract: Map<string, string>;
  abstractLevels: Map<string, Map<number, LevelInfo>>;
}

type FieldState = 'instruction' | 'result';

/** Walk state of one part (body, or a footnote / endnote): the field stack is kept across paragraphs and tables (section 5). */
interface PartState {
  fields: FieldState[];
  /** Footnote / endnote references are recorded in the body, not inside notes. */
  recordNotes: boolean;
}

interface NoteRef {
  kind: 'footnote' | 'endnote';
  id: string;
}

interface DocxContext {
  styles: Map<string, StyleInfo>;
  numbering: Numbering | null;
  /** (numId, ilvl) → current number. */
  counters: Map<string, Map<number, number>>;
  noteRefs: NoteRef[];
  seenNoteRefs: Set<string>;
}

export async function extractDocxText(pkg: OfficePackage): Promise<string> {
  const main = await pkg.relatedPart('', '/officeDocument', 'word/document.xml');
  const document = await pkg.requiredXml(main);
  const [styles, numbering, footnotes, endnotes] = await Promise.all([
    pkg.relatedPart(main, '/styles', 'word/styles.xml'),
    pkg.relatedPart(main, '/numbering', 'word/numbering.xml'),
    pkg.relatedPart(main, '/footnotes', 'word/footnotes.xml'),
    pkg.relatedPart(main, '/endnotes', 'word/endnotes.xml'),
  ]);

  const ctx: DocxContext = {
    styles: parseStyles(await pkg.xml(styles)),
    numbering: parseNumbering(await pkg.xml(numbering)),
    counters: new Map(),
    noteRefs: [],
    seenNoteRefs: new Set(),
  };

  const blocks: TextBlock[] = [];
  const body = document.documentElement ? childNamed(document.documentElement, W, 'body') : null;
  if (body) walkBlocks(body, ctx, { fields: [], recordNotes: true }, blocks);

  if (ctx.noteRefs.length > 0) {
    const notes = {
      footnote: collectNotes(await pkg.xml(footnotes), 'footnote'),
      endnote: collectNotes(await pkg.xml(endnotes), 'endnote'),
    };
    let first = true;
    for (const ref of ctx.noteRefs) {
      const note = notes[ref.kind].get(ref.id);
      if (!note) continue;
      const label = ref.kind === 'footnote' ? `[^${ref.id}]` : `[^e${ref.id}]`;
      blocks.push({ text: `${label}: ${noteText(note, ctx)}`, spaced: false, blankBefore: first });
      first = false;
    }
  }

  return normalizeStructuredText(joinBlocks(blocks));
}

// MARK: - Blocks

/** `w:body` / `w:sdtContent` / text box: `w:p` paragraphs, `w:tbl` tables, `w:sdt` recursed, everything else ignored. */
function walkBlocks(container: Element, ctx: DocxContext, part: PartState, blocks: TextBlock[]): void {
  for (const child of childElements(container)) {
    if (isNamed(child, W, 'p')) {
      paragraphBlocks(child, ctx, part, blocks);
    } else if (isNamed(child, W, 'tbl')) {
      blocks.push(...tableBlocks(tableRows(child, ctx, part)));
    } else if (isNamed(child, W, 'sdt')) {
      const content = childNamed(child, W, 'sdtContent');
      if (content) walkBlocks(content, ctx, part, blocks);
    } else if (isNamed(child, MC, 'AlternateContent')) {
      const choice = firstChoice(child);
      if (choice) walkBlocks(choice, ctx, part, blocks);
    }
  }
}

function paragraphBlocks(paragraph: Element, ctx: DocxContext, part: PartState, blocks: TextBlock[]): void {
  const textBoxes: Element[] = [];
  const text = paragraphText(paragraph, ctx, part, textBoxes);
  const block = classifyParagraph(paragraph, text, ctx);
  if (block) blocks.push(block);
  for (const box of textBoxes) walkBlocks(box, ctx, part, blocks);
}

function classifyParagraph(paragraph: Element, text: string, ctx: DocxContext): TextBlock | null {
  const properties = childNamed(paragraph, W, 'pPr');

  // 1. The paragraph's own outline level
  const ownOutline = outlineLevelOf(properties);
  if (ownOutline !== null && ownOutline >= 0 && ownOutline <= 8) return headingBlock(ownOutline + 1, text);

  const styleChain = styleChainOf(properties, ctx);
  // 2. First heading N / title on the style chain
  for (const style of styleChain) {
    const name = (style.name ?? '').toLowerCase();
    const heading = /^heading ([1-9])$/.exec(name);
    if (heading) return headingBlock(Number(heading[1]), text);
    if (name === 'title') return headingBlock(1, text);
  }
  // 3. First outline level on the style chain
  const styled = styleChain.find((style) => style.outlineLevel !== null);
  if (styled && styled.outlineLevel! >= 0 && styled.outlineLevel! <= 8) {
    return headingBlock(styled.outlineLevel! + 1, text);
  }

  // 4. Numbering
  const numberProperties = properties ? childNamed(properties, W, 'numPr') : null;
  const numId = numberProperties ? valOf(childNamed(numberProperties, W, 'numId')) : null;
  if (numberProperties && numId !== null && numId !== '0') {
    const levelValue = valOf(childNamed(numberProperties, W, 'ilvl'));
    const level = levelValue !== null && /^\d+$/.test(levelValue) ? Number(levelValue) : 0;
    const marker = listMarker(numId, level, ctx);
    if (marker !== null) return listItemBlock(level, marker, text);
  }

  // 5. Plain paragraph
  return paragraphBlock(text);
}

/** List marker; `none` returns null (treated as a plain paragraph). */
function listMarker(numId: string, level: number, ctx: DocxContext): string | null {
  const abstractId = ctx.numbering?.numToAbstract.get(numId);
  const info = abstractId !== undefined ? ctx.numbering?.abstractLevels.get(abstractId)?.get(level) : undefined;
  if (!info || info.format === null) return '- ';
  if (info.format === 'bullet') return '- ';
  if (info.format === 'none') return null;

  let levels = ctx.counters.get(numId);
  if (!levels) {
    levels = new Map();
    ctx.counters.set(numId, levels);
  }
  // When an item of some level appears, counters of deeper levels under the same numId are reset.
  for (const deeper of [...levels.keys()]) {
    if (deeper > level) levels.delete(deeper);
  }
  const value = levels.has(level) ? levels.get(level)! + 1 : info.start;
  levels.set(level, value);
  return `${value}. `;
}

function styleChainOf(properties: Element | null, ctx: DocxContext): StyleInfo[] {
  const chain: StyleInfo[] = [];
  let id = properties ? valOf(childNamed(properties, W, 'pStyle')) : null;
  while (id !== null && chain.length <= MAX_STYLE_DEPTH) {
    const style = ctx.styles.get(id);
    if (!style) break;
    chain.push(style);
    id = style.basedOn;
  }
  return chain;
}

// MARK: - Paragraph text

function paragraphText(paragraph: Element, ctx: DocxContext, part: PartState, textBoxes: Element[]): string {
  const out = { text: '' };
  walkInline(paragraph, ctx, part, out, textBoxes);
  return out.text;
}

function walkInline(
  node: Element,
  ctx: DocxContext,
  part: PartState,
  out: { text: string },
  textBoxes: Element[],
): void {
  for (const child of childElements(node)) {
    if (isNamed(child, MC, 'AlternateContent')) {
      const choice = firstChoice(child);
      if (choice) walkInline(choice, ctx, part, out, textBoxes);
      continue;
    }
    if (isNamed(child, MC, 'Fallback')) continue;
    if (!inNamespace(child, W)) {
      walkInline(child, ctx, part, out, textBoxes);
      continue;
    }
    const local = child.localName;
    if (SKIPPED_INLINE.has(local)) continue;
    // While any layer on the stack is in the "instruction" state, no output (text, tabs, line breaks, note references, text boxes) is taken (section 5).
    if (MUTED_IN_INSTRUCTION.has(local) && part.fields.includes('instruction')) continue;
    switch (local) {
      case 't':
        out.text += child.textContent ?? '';
        break;
      case 'r':
        if (!isHiddenRun(child)) walkInline(child, ctx, part, out, textBoxes);
        break;
      case 'fldChar': {
        const type = attrNs(child, W, 'fldCharType');
        if (type === 'begin') part.fields.push('instruction');
        else if (type === 'separate' && part.fields.length > 0) part.fields[part.fields.length - 1] = 'result';
        else if (type === 'end') part.fields.pop();
        break;
      }
      case 'tab':
        out.text += '\t';
        break;
      case 'br':
      case 'cr':
        out.text += '\n';
        break;
      case 'noBreakHyphen':
        out.text += '-';
        break;
      case 'softHyphen':
      case 'sym':
        break;
      case 'footnoteReference':
      case 'endnoteReference': {
        const id = attrNs(child, W, 'id') ?? '';
        const kind = local === 'footnoteReference' ? 'footnote' : 'endnote';
        out.text += kind === 'footnote' ? `[^${id}]` : `[^e${id}]`;
        const key = `${kind}:${id}`;
        if (part.recordNotes && !ctx.seenNoteRefs.has(key)) {
          ctx.seenNoteRefs.add(key);
          ctx.noteRefs.push({ kind, id });
        }
        break;
      }
      case 'txbxContent':
        textBoxes.push(child);
        break;
      default:
        // hyperlink, smartTag, customXml, ins, moveTo, sdt / sdtContent, fldSimple, drawing, etc.: recurse and take text as usual.
        walkInline(child, ctx, part, out, textBoxes);
    }
  }
}

/** `w:rPr` contains `w:vanish` (with no `w:val`, or a value other than `0` / `false`). */
function isHiddenRun(run: Element): boolean {
  const properties = childNamed(run, W, 'rPr');
  const vanish = properties ? childNamed(properties, W, 'vanish') : null;
  if (!vanish) return false;
  const value = attrNs(vanish, W, 'val');
  return value === null || (value !== '0' && value.toLowerCase() !== 'false');
}

// MARK: - Tables

function tableRows(table: Element, ctx: DocxContext, part: PartState): string[][] {
  return rowElements(table).map((row) => {
    const cells: string[] = [];
    for (const cell of cellElements(row)) {
      const properties = childNamed(cell, W, 'tcPr');
      const span = Number(valOf(properties ? childNamed(properties, W, 'gridSpan') : null) ?? '1');
      const merge = properties ? childNamed(properties, W, 'vMerge') : null;
      const continued = merge !== null && valOf(merge) !== 'restart';
      cells.push(continued ? '' : formatTableCell(cellParagraphs(cell, ctx, part)));
      for (let i = 1; i < (Number.isFinite(span) ? span : 1); i++) cells.push('');
    }
    return cells;
  });
}

/** Rows may be wrapped in `w:sdt` / `w:customXml`. */
function rowElements(table: Element): Element[] {
  return wrappedChildren(table, 'tr');
}

function cellElements(row: Element): Element[] {
  return wrappedChildren(row, 'tc');
}

function wrappedChildren(parent: Element, local: string): Element[] {
  const out: Element[] = [];
  for (const child of childElements(parent)) {
    if (isNamed(child, W, local)) out.push(child);
    else if (isNamed(child, W, 'sdt')) {
      const content = childNamed(child, W, 'sdtContent');
      if (content) out.push(...wrappedChildren(content, local));
    } else if (isNamed(child, W, 'customXml')) out.push(...wrappedChildren(child, local));
  }
  return out;
}

/** Text of each paragraph in the cell (no heading or list markers); nested tables are flattened into one run (section 3.3). */
function cellParagraphs(container: Element, ctx: DocxContext, part: PartState): string[] {
  const out: string[] = [];
  for (const child of childElements(container)) {
    if (isNamed(child, W, 'p')) {
      const textBoxes: Element[] = [];
      out.push(paragraphText(child, ctx, part, textBoxes));
      for (const box of textBoxes) out.push(...cellParagraphs(box, ctx, part));
    } else if (isNamed(child, W, 'tbl')) {
      out.push(flattenTable(child, ctx, part));
    } else if (isNamed(child, W, 'sdt')) {
      const content = childNamed(child, W, 'sdtContent');
      if (content) out.push(...cellParagraphs(content, ctx, part));
    }
  }
  return out;
}

/** Nested table: rows separated by ` / `, cells by `; `. */
function flattenTable(table: Element, ctx: DocxContext, part: PartState): string {
  return rowElements(table)
    .map((row) => cellElements(row)
      .map((cell) => joinNonEmpty(cellParagraphs(cell, ctx, part), ' '))
      .join('; '))
    .join(' / ');
}

// MARK: - Footnotes

function collectNotes(doc: Document | null, kind: 'footnote' | 'endnote'): Map<string, Element> {
  const notes = new Map<string, Element>();
  if (!doc?.documentElement) return notes;
  for (const note of childrenNamed(doc.documentElement, W, kind)) {
    const type = attrNs(note, W, 'type');
    if (type === 'separator' || type === 'continuationSeparator') continue;
    const id = attrNs(note, W, 'id');
    if (id !== null && !notes.has(id)) notes.set(id, note);
  }
  return notes;
}

/** Note text: paragraphs trimmed, empty ones dropped, then joined with one space; each note has its own field stack. */
function noteText(note: Element, ctx: DocxContext): string {
  return joinNonEmpty(cellParagraphs(note, ctx, { fields: [], recordNotes: false }), ' ');
}

// MARK: - styles.xml / numbering.xml

function parseStyles(doc: Document | null): Map<string, StyleInfo> {
  const styles = new Map<string, StyleInfo>();
  if (!doc?.documentElement) return styles;
  for (const style of childrenNamed(doc.documentElement, W, 'style')) {
    const id = attrNs(style, W, 'styleId');
    if (id === null || styles.has(id)) continue;
    styles.set(id, {
      name: valOf(childNamed(style, W, 'name')),
      basedOn: valOf(childNamed(style, W, 'basedOn')),
      outlineLevel: outlineLevelOf(childNamed(style, W, 'pPr')),
    });
  }
  return styles;
}

function parseNumbering(doc: Document | null): Numbering | null {
  if (!doc?.documentElement) return null;
  const abstractLevels = new Map<string, Map<number, LevelInfo>>();
  for (const abstract of childrenNamed(doc.documentElement, W, 'abstractNum')) {
    const id = attrNs(abstract, W, 'abstractNumId');
    if (id === null || abstractLevels.has(id)) continue;
    const levels = new Map<number, LevelInfo>();
    for (const level of childrenNamed(abstract, W, 'lvl')) {
      const index = Number(attrNs(level, W, 'ilvl') ?? 'NaN');
      if (!Number.isInteger(index) || levels.has(index)) continue;
      const start = Number(valOf(childNamed(level, W, 'start')) ?? '1');
      levels.set(index, {
        format: valOf(childNamed(level, W, 'numFmt')),
        start: Number.isFinite(start) ? start : 1,
      });
    }
    abstractLevels.set(id, levels);
  }
  const numToAbstract = new Map<string, string>();
  for (const num of childrenNamed(doc.documentElement, W, 'num')) {
    const id = attrNs(num, W, 'numId');
    const abstractId = valOf(childNamed(num, W, 'abstractNumId'));
    if (id !== null && abstractId !== null && !numToAbstract.has(id)) numToAbstract.set(id, abstractId);
  }
  return { numToAbstract, abstractLevels };
}

// MARK: - Helpers

function valOf(element: Element | null): string | null {
  return element ? attrNs(element, W, 'val') : null;
}

function outlineLevelOf(properties: Element | null): number | null {
  const value = properties ? valOf(childNamed(properties, W, 'outlineLvl')) : null;
  if (value === null || !/^-?\d+$/.test(value.trim())) return null;
  return Number(value);
}

function joinNonEmpty(parts: readonly string[], separator: string): string {
  return parts.map((part) => part.trim()).filter((part) => part.length > 0).join(separator);
}
