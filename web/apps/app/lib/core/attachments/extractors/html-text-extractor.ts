/**
 * HTML / XHTML text extraction (attachment extraction output spec section 8).
 *
 * Bytes are first decoded into a string per section 8 "decoding" (BOM → `<meta charset>` → section 4 detection), then handed to `DOMParser('text/html')`
 * for HTML5 tree building; a hand-written traversal then produces blocks, finally normalized per section 3.1. The extraction entry already forbids SSR, so there is no DOM-less fallback here.
 */

import { decodeTextBytes } from './text-decoding';
import { formatTableCell, normalizeStructuredText, renderTableBlocks } from './structured-text';

export async function extractHtmlText(file: File, uiLanguage: string = 'en'): Promise<string> {
  const html = decodeHtmlBytes(new Uint8Array(await file.arrayBuffer()), uiLanguage);
  return renderHtmlText(html);
}

// MARK: - Decoding

const META_SNIFF_BYTES = 1024;

/** Label normalization from spec section 8; labels outside the table are treated as undeclared. */
const HTML_CHARSET_LABELS: Readonly<Record<string, string>> = {
  gbk: 'gb18030',
  gb2312: 'gb18030',
  'x-gbk': 'gb18030',
  gb18030: 'gb18030',
  shift_jis: 'shift_jis',
  sjis: 'shift_jis',
  ms932: 'shift_jis',
  big5: 'big5',
  'euc-kr': 'euc-kr',
  'ks_c_5601-1987': 'euc-kr',
  'iso-8859-1': 'windows-1252',
  latin1: 'windows-1252',
  ascii: 'windows-1252',
  'us-ascii': 'windows-1252',
  'windows-1252': 'windows-1252',
  // The target names of section 4 candidates are also accepted (gb18030, shift_jis, big5, euc-kr; windows-1252 is already above).
  'windows-1251': 'windows-1251',
  'utf-8': 'utf-8',
  utf8: 'utf-8',
};

/** Spec section 8 "decoding": BOM → first `<meta ... charset=...>` in the first 1024 bytes → the section 4 algorithm. */
export function decodeHtmlBytes(bytes: Uint8Array, uiLanguage: string = 'en'): string {
  if (!hasBom(bytes)) {
    const label = declaredCharset(bytes);
    if (label) {
      try {
        return new TextDecoder(label, { fatal: true, ignoreBOM: true }).decode(bytes);
      } catch {
        // Strict decoding with the declared encoding failed: fall back to section 4.
      }
    }
  }
  return decodeTextBytes(bytes, uiLanguage);
}

function hasBom(bytes: Uint8Array): boolean {
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return true;
  return bytes.length >= 2
    && ((bytes[0] === 0xff && bytes[1] === 0xfe) || (bytes[0] === 0xfe && bytes[1] === 0xff));
}

function declaredCharset(bytes: Uint8Array): string | null {
  let head = '';
  const end = Math.min(bytes.length, META_SNIFF_BYTES);
  for (let i = 0; i < end; i++) head += String.fromCharCode(bytes[i]);
  const match = /<meta\b[^>]*?\bcharset\s*=\s*["']?\s*([^\s"'>;/]+)/i.exec(head);
  if (!match) return null;
  return HTML_CHARSET_LABELS[match[1].toLowerCase()] ?? null;
}

// MARK: - Parsing and output

const DROPPED_ELEMENTS = new Set([
  'script', 'style', 'noscript', 'template', 'head', 'title', 'svg', 'math', 'iframe', 'object', 'embed',
  'canvas', 'audio', 'video', 'select', 'rp',
]);

const DOUBLE_BREAK_ELEMENTS = new Set([
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote', 'pre', 'table', 'hr', 'dl', 'figure', 'address',
]);

const SINGLE_BREAK_ELEMENTS = new Set([
  'div', 'li', 'dt', 'dd', 'section', 'article', 'header', 'footer', 'nav', 'aside', 'main', 'figcaption',
  'caption', 'tr', 'form', 'fieldset', 'legend', 'details', 'summary', 'center',
]);

const HEADING_LEVEL: Readonly<Record<string, number>> = { h1: 1, h2: 2, h3: 3, h4: 4, h5: 5, h6: 6 };

/** Spec section 8: HTML string → normalized text. Each EPUB chapter goes through here too. */
export function renderHtmlText(html: string): string {
  const doc = new DOMParser().parseFromString(html, 'text/html');
  const root = doc.body ?? doc.documentElement;
  if (!root) return '';
  const sink = new TextSink();
  new HtmlWalker().walk(root, sink, ROOT_CONTEXT);
  return normalizeStructuredText(sink.result());
}

interface WalkContext {
  /** Inside `pre`: text as-is, whitespace not collapsed. */
  pre: boolean;
  /** Number of enclosing `li` elements, i.e. the list item indent level. */
  listDepth: number;
  /** Inside a table cell: nested tables are flattened and block-level line breaks become in-cell segments. */
  cell: boolean;
}

const ROOT_CONTEXT: WalkContext = { pre: false, listDepth: 0, cell: false };

/**
 * Output buffer: line break requests merge by taking the maximum, requests at the start and end of the text are dropped; spaces produced by collapsing on either side of a request are removed.
 */
class TextSink {
  private out = '';
  private pending = 0;
  private trailingCollapsedSpace = false;
  private prefix: { text: string } | null = null;

  request(count: number): void {
    this.dropTrailingCollapsedSpace();
    if (this.out.length === 0) return;
    this.pending = Math.max(this.pending, count);
  }

  /** List item marker: pending, written only when the first text of this item appears; not written if the item is empty. */
  setPrefix(text: string): { text: string } {
    this.prefix = { text };
    return this.prefix;
  }

  clearPrefix(token: { text: string }): void {
    if (this.prefix === token) this.prefix = null;
  }

  /** Text whose whitespace has already been collapsed. */
  collapsed(text: string): void {
    let value = text;
    // Collapsed spaces adjacent across text nodes merge into one; collapsed spaces after a line break request, at the start, or after a list marker are removed.
    if (value.startsWith(' ')
      && (this.trailingCollapsedSpace || this.pending > 0 || this.out.length === 0 || this.prefix !== null)) {
      value = value.slice(1);
    }
    if (!value) return;
    this.flush();
    this.out += value;
    this.trailingCollapsedSpace = value.endsWith(' ');
  }

  /** Verbatim text (already-formed blocks such as `pre`, `br`, headings, tables). */
  raw(text: string): void {
    if (!text) return;
    this.flush();
    this.out += text;
    this.trailingCollapsedSpace = false;
  }

  result(): string {
    this.dropTrailingCollapsedSpace();
    return this.out;
  }

  private flush(): void {
    if (this.pending > 0 && this.out.length > 0) this.out += '\n'.repeat(this.pending);
    this.pending = 0;
    if (this.prefix) {
      this.out += this.prefix.text;
      this.prefix = null;
    }
  }

  private dropTrailingCollapsedSpace(): void {
    if (this.trailingCollapsedSpace) {
      this.out = this.out.slice(0, -1);
      this.trailingCollapsedSpace = false;
    }
  }
}

const ELEMENT_NODE = 1;
const TEXT_NODE = 3;

class HtmlWalker {
  /** Next item number for each `ol`. */
  private readonly orderedCounters = new Map<Element, number>();

  walk(node: Node, sink: TextSink, ctx: WalkContext): void {
    for (const child of Array.from(node.childNodes)) {
      if (child.nodeType === TEXT_NODE) {
        const data = (child as Text).data;
        if (ctx.pre) sink.raw(data);
        else sink.collapsed(data.replace(/[ \t\n\r\f]+/g, ' '));
      } else if (child.nodeType === ELEMENT_NODE) {
        this.element(child as Element, sink, ctx);
      }
    }
  }

  private element(el: Element, sink: TextSink, ctx: WalkContext): void {
    const name = el.localName.toLowerCase();
    if (DROPPED_ELEMENTS.has(name) || el.hasAttribute('hidden')) return;
    if ((el.getAttribute('epub:type') ?? '').includes('pagebreak')) return;

    if (name === 'br') {
      // Spec section 3.2: line breaks inside list item text become spaces.
      sink.raw(ctx.listDepth > 0 && !ctx.pre ? ' ' : '\n');
      return;
    }
    if (name === 'hr') {
      sink.request(2);
      sink.raw('---');
      sink.request(2);
      return;
    }
    const level = HEADING_LEVEL[name];
    if (level !== undefined && !ctx.cell) {
      this.heading(el, level, sink, ctx);
      return;
    }
    if (name === 'table') {
      if (ctx.cell) this.nestedTable(el, sink, ctx);
      else this.table(el, sink, ctx);
      return;
    }
    if (name === 'pre') {
      sink.request(2);
      this.walk(el, sink, { ...ctx, pre: true });
      sink.request(2);
      return;
    }
    if (name === 'ul' || name === 'ol') {
      const count = ctx.listDepth > 0 ? 1 : 2;
      sink.request(count);
      this.walk(el, sink, ctx);
      sink.request(count);
      return;
    }
    if (name === 'li') {
      sink.request(1);
      const token = sink.setPrefix('  '.repeat(ctx.listDepth) + this.listMarker(el));
      this.walk(el, sink, { ...ctx, listDepth: ctx.listDepth + 1 });
      sink.clearPrefix(token);
      sink.request(1);
      return;
    }
    const breaks = DOUBLE_BREAK_ELEMENTS.has(name) ? 2 : SINGLE_BREAK_ELEMENTS.has(name) ? 1 : 0;
    if (breaks > 0) sink.request(breaks);
    this.walk(el, sink, ctx);
    if (breaks > 0) sink.request(breaks);
  }

  private heading(el: Element, level: number, sink: TextSink, ctx: WalkContext): void {
    const inner = new TextSink();
    this.walk(el, inner, ctx);
    const text = inner.result().replace(/[\n\t]/g, ' ').trim();
    if (!text) return;
    sink.request(2);
    sink.raw(`${'#'.repeat(Math.min(level, 6))} ${text}`);
    sink.request(2);
  }

  private listMarker(li: Element): string {
    let list = li.parentElement;
    while (list && !['ul', 'ol', 'menu', 'li'].includes(list.localName.toLowerCase())) list = list.parentElement;
    if (!list || list.localName.toLowerCase() !== 'ol') return '- ';
    let next = this.orderedCounters.get(list);
    if (next === undefined) {
      const start = Number.parseInt(list.getAttribute('start') ?? '', 10);
      next = Number.isNaN(start) ? 1 : start;
    }
    this.orderedCounters.set(list, next + 1);
    return `${next}. `;
  }

  // MARK: Tables

  private table(table: Element, sink: TextSink, ctx: WalkContext): void {
    for (const caption of Array.from(table.children).filter((child) => child.localName.toLowerCase() === 'caption')) {
      this.element(caption, sink, ctx);
    }
    const rows = tableRows(table);
    const spanned = rows.some((row) => row.some((cell) => spanAbove1(cell, 'colspan') || spanAbove1(cell, 'rowspan')));

    let blocks: string[];
    if (spanned) {
      // Has merged cells: no pipe table, one line per row, cells separated by `\t`.
      const lines = rows
        .map((row) => row.map((cell) => this.inlineCellText(cell, ctx)))
        .filter((cells) => cells.some((cell) => cell.length > 0))
        .map((cells) => cells.join('\t'));
      blocks = lines.length > 0 ? [lines.join('\n')] : [];
    } else {
      blocks = renderTableBlocks(rows.map((row) => row.map((cell) => formatTableCell(this.cellLines(cell, ctx)))));
    }
    if (blocks.length === 0) return;
    sink.request(2);
    sink.raw(blocks.join('\n\n'));
    sink.request(2);
  }

  /** A table nested in a cell is flattened into one run: rows separated by ` / `, cells by `; `; empty cells and empty rows are kept (same as DOCX / ODF). */
  private nestedTable(table: Element, sink: TextSink, ctx: WalkContext): void {
    const text = tableRows(table)
      .map((row) => row.map((cell) => this.inlineCellText(cell, ctx)).join('; '))
      .join(' / ');
    if (!text) return;
    sink.request(1);
    sink.raw(text);
    sink.request(1);
  }

  /** Inline text within a cell; block-level line breaks split segments inside the cell (later joined with `<br>`). */
  private cellLines(cell: Element, ctx: WalkContext): string[] {
    const inner = new TextSink();
    this.walk(cell, inner, { ...ctx, pre: false, cell: true });
    return inner.result().split('\n');
  }

  private inlineCellText(cell: Element, ctx: WalkContext): string {
    return this.cellLines(cell, ctx)
      .map((line) => line.trim())
      .filter((line) => line.length > 0)
      .join(' ')
      .replace(/\t/g, ' ')
      .trim();
  }
}

/** The table's own rows (direct child `tr`, and `tr` under `thead` / `tbody` / `tfoot`), excluding rows of nested tables. */
function tableRows(table: Element): Element[][] {
  const rows: Element[] = [];
  for (const child of Array.from(table.children)) {
    const name = child.localName.toLowerCase();
    if (name === 'tr') rows.push(child);
    else if (name === 'thead' || name === 'tbody' || name === 'tfoot') {
      rows.push(...Array.from(child.children).filter((row) => row.localName.toLowerCase() === 'tr'));
    }
  }
  return rows.map((row) => Array.from(row.children).filter((cell) => {
    const name = cell.localName.toLowerCase();
    return name === 'td' || name === 'th';
  }));
}

function spanAbove1(cell: Element, attribute: 'colspan' | 'rowspan'): boolean {
  const value = Number.parseInt(cell.getAttribute(attribute) ?? '', 10);
  return !Number.isNaN(value) && value > 1;
}
