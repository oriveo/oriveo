/**
 * RTF text extraction (attachment extraction output spec section 11): the same hand-written tokenizer on all three platforms (modeled on python striprtf), byte for byte identical.
 *
 * Walks the raw bytes directly: `\'hh` and raw bytes >= 0x80 accumulate into a run, decoded with `TextDecoder` using the code page of the current font / `\ansicpg`.
 * The deadline is checked every 64 KB of input (section 14). Finally normalized per section 3.1.
 */

import type { ExtractionDeadline } from '../extraction-deadline';
import { normalizeStructuredText } from './structured-text';

const DEADLINE_CHECK_BYTES = 64 * 1024;

/** Destinations ignored as a whole group (`fonttbl` parses the font table first, then is ignored). */
const IGNORED_DESTINATIONS = new Set([
  'fonttbl', 'colortbl', 'stylesheet', 'listtable', 'listoverridetable', 'revtbl', 'rsidtbl', 'info', 'pict',
  'shppict', 'nonshppict', 'object', 'themedata', 'datastore', 'latentstyles', 'xmlnstbl', 'generator', 'fldinst',
  'header', 'headerl', 'headerr', 'headerf', 'footer', 'footerl', 'footerr', 'footerf',
]);

const CONTROL_WORD_OUTPUT: Readonly<Record<string, string>> = {
  par: '\n',
  line: '\n',
  sect: '\n\n',
  page: '\n\n',
  tab: '\t',
  cell: '\t',
  nestcell: '\t',
  row: '\n',
  nestrow: '\n',
  emdash: '—',
  endash: '–',
  bullet: '•',
  lquote: '‘',
  rquote: '’',
  ldblquote: '“',
  rdblquote: '”',
};

/** `\fcharset` → code page; 0 / 1 follow `\ansicpg` (returns null), anything outside the table is 1252. */
function charsetCodePage(charset: number): number | null {
  switch (charset) {
    case 0:
    case 1: return null;
    case 77: return 10000;
    case 128: return 932;
    case 129: return 949;
    case 134: return 936;
    case 136: return 950;
    case 161: return 1253;
    case 162: return 1254;
    case 163: return 1258;
    case 177: return 1255;
    case 178: return 1256;
    case 186: return 1257;
    case 204: return 1251;
    case 222: return 874;
    case 238: return 1250;
    default: return 1252;
  }
}

/** Code page → `TextDecoder` label. `\mac`(10000), `\pc`(437), `\pca`(850) and code pages outside the table are decoded as 1252. */
function codePageLabel(codePage: number): string {
  switch (codePage) {
    case 932: return 'shift_jis';
    case 936: return 'gb18030';
    case 949: return 'euc-kr';
    case 950: return 'big5';
    case 874: return 'windows-874';
    case 1250: case 1251: case 1252: case 1253: case 1254: case 1255: case 1256: case 1257: case 1258:
      return `windows-${codePage}`;
    default: return 'windows-1252';
  }
}

const DOUBLE_BYTE_LABELS = new Set(['shift_jis', 'gb18030', 'euc-kr', 'big5']);

/** Whether this byte starts a double-byte character in a double-byte code page. */
function isLeadByte(label: string, byte: number): boolean {
  if (label === 'shift_jis') return (byte >= 0x81 && byte <= 0x9f) || (byte >= 0xe0 && byte <= 0xfc);
  return byte >= 0x81 && byte <= 0xfe;
}

interface FontInfo {
  charset?: number;
  cpg?: number;
}

interface GroupState {
  ucSkip: number;
  ignore: boolean;
  hidden: boolean;
  font: number | null;
  inFontTable: boolean;
  inUpr: boolean;
  /** The first token of this group has not been read yet. */
  atStart: boolean;
  /** This group starts with `\*`; the next control word decides whether it is `\*\ud` inside `\upr`. */
  starStart: boolean;
  /** Ignore state outside the `\upr` group, which the `\*\ud` subgroup restores. */
  uprOuterIgnore: boolean;
}

const BACKSLASH = 0x5c;
const OPEN_BRACE = 0x7b;
const CLOSE_BRACE = 0x7d;
const CR = 0x0d;
const LF = 0x0a;

const isLetter = (byte: number) => (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a);
const isDigit = (byte: number) => byte >= 0x30 && byte <= 0x39;
const hexValue = (byte: number) => {
  if (isDigit(byte)) return byte - 0x30;
  if (byte >= 0x41 && byte <= 0x46) return byte - 0x37;
  if (byte >= 0x61 && byte <= 0x66) return byte - 0x57;
  return -1;
};

export function extractRtfText(bytes: Uint8Array, deadline?: ExtractionDeadline): string {
  return normalizeStructuredText(new RtfTokenizer(bytes, deadline).extract());
}

type Token =
  | { kind: 'open' }
  | { kind: 'close' }
  | { kind: 'word'; word: string; param: number | null }
  | { kind: 'symbol'; char: number }
  | { kind: 'hex'; byte: number }
  | { kind: 'text'; byte: number }
  | { kind: 'bin'; length: number };

class RtfTokenizer {
  private pos = 0;
  private nextDeadlineCheck = 0;
  private readonly out: string[] = [];
  private readonly fonts = new Map<number, FontInfo>();
  private fontTableCurrent: number | null = null;
  private ansiCodePage = 1252;
  private defaultFont: number | null = null;
  private readonly stack: GroupState[] = [];
  private state: GroupState = {
    ucSkip: 1, ignore: false, hidden: false, font: null, inFontTable: false, inUpr: false,
    atStart: false, starStart: false, uprOuterIgnore: false,
  };

  // Accumulated byte run
  private pendingBytes: number[] = [];
  private pendingLabel = 'windows-1252';
  private trailPending = false;

  private skipUnits = 0;

  constructor(private readonly bytes: Uint8Array, private readonly deadline?: ExtractionDeadline) {}

  extract(): string {
    let depth = 0;
    let started = false;
    for (;;) {
      if (this.pos >= this.nextDeadlineCheck) {
        this.deadline?.check();
        this.nextDeadlineCheck += DEADLINE_CHECK_BYTES;
      }
      const token = this.nextToken();
      if (!token) break;

      if (token.kind === 'open') {
        this.flushRun();
        this.skipUnits = 0;
        if (started) this.stack.push(this.state);
        this.state = { ...this.state, atStart: true, starStart: false };
        started = true;
        depth += 1;
        continue;
      }
      if (token.kind === 'close') {
        this.flushRun();
        this.skipUnits = 0;
        if (depth === 0) continue;
        depth -= 1;
        // Content after the outermost group ends is ignored.
        if (depth === 0) break;
        this.state = this.stack.pop() ?? this.state;
        continue;
      }
      if (!started) continue;

      const atStart = this.state.atStart;
      this.state.atStart = false;

      if (this.skipUnits > 0) {
        // Fallback units after \uN: each \'hh, control word, or plain character counts as one.
        this.skipUnits -= 1;
        continue;
      }
      this.handle(token, atStart);
    }
    this.flushRun();
    // A lone surrogate yields U+FFFD.
    return this.out.join('')
      .replace(/[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g, '�');
  }

  private handle(token: Token, atStart: boolean): void {
    switch (token.kind) {
      case 'hex':
        this.pushByte(token.byte);
        return;
      case 'text':
        if (token.byte >= 0x80) this.pushByte(token.byte);
        else this.literal(token.byte);
        return;
      case 'bin':
        this.flushRun();
        return;
      case 'symbol':
        this.symbol(token.char, atStart);
        return;
      case 'word':
        this.word(token.word, token.param, atStart);
        return;
      default:
        return;
    }
  }

  private symbol(char: number, atStart: boolean): void {
    if (char === BACKSLASH || char === OPEN_BRACE || char === CLOSE_BRACE) {
      this.literal(char);
      return;
    }
    this.flushRun();
    if (char === 0x2a /* * */) {
      if (atStart) {
        this.state.starStart = true;
        this.state.ignore = true;
        // The next control word still counts as the "start of the group", used to recognize `\*\ud` inside `\upr`.
        this.state.atStart = true;
      }
      return;
    }
    if (char === CR || char === LF) {
      this.emit('\n');
      return;
    }
    if (char === 0x7e /* ~ */) this.emit(' ');
    else if (char === 0x5f /* _ */) this.emit('-');
    // `\-` and other control symbols produce no output.
  }

  private word(word: string, param: number | null, atStart: boolean): void {
    this.flushRun();
    const state = this.state;

    if (atStart) {
      if (state.starStart) {
        state.starStart = false;
        const parent = this.stack[this.stack.length - 1];
        if (word === 'ud' && parent?.inUpr) state.ignore = parent.uprOuterIgnore;
      } else if (word === 'upr') {
        state.inUpr = true;
        state.uprOuterIgnore = state.ignore;
        state.ignore = true;
        return;
      } else if (IGNORED_DESTINATIONS.has(word)) {
        state.ignore = true;
        if (word === 'fonttbl') state.inFontTable = true;
        return;
      }
    }

    if (state.inFontTable) {
      if (word === 'f' && param !== null) {
        this.fontTableCurrent = param;
        if (!this.fonts.has(param)) this.fonts.set(param, {});
      } else if (word === 'fcharset' && param !== null && this.fontTableCurrent !== null) {
        this.fonts.get(this.fontTableCurrent)!.charset = param;
      } else if (word === 'cpg' && param !== null && this.fontTableCurrent !== null) {
        this.fonts.get(this.fontTableCurrent)!.cpg = param;
      }
      return;
    }

    switch (word) {
      case 'ansicpg':
        if (param !== null) this.ansiCodePage = param;
        return;
      case 'mac': this.ansiCodePage = 10000; return;
      case 'pc': this.ansiCodePage = 437; return;
      case 'pca': this.ansiCodePage = 850; return;
      case 'deff':
        if (param !== null) this.defaultFont = param;
        return;
      case 'f':
        if (param !== null) state.font = param;
        return;
      case 'uc':
        if (param !== null && param >= 0) state.ucSkip = param;
        return;
      case 'v':
        state.hidden = param !== 0;
        return;
      case 'plain':
        state.hidden = false;
        return;
      case 'u':
        if (param === null) return;
        this.emit(String.fromCharCode(param < 0 ? param + 65536 : param & 0xffff));
        this.skipUnits = state.ucSkip;
        return;
      default: {
        const mapped = CONTROL_WORD_OUTPUT[word];
        if (mapped !== undefined) this.emit(mapped);
      }
    }
  }

  /** Plain ASCII characters (including `\\` `\{` `\}`); in a double-byte code page, 0x40-0x7E right after a lead byte counts as a trail byte. */
  private literal(byte: number): void {
    if (this.trailPending && byte >= 0x40 && byte <= 0x7e) {
      this.pendingBytes.push(byte);
      this.trailPending = false;
      return;
    }
    this.flushRun();
    this.emit(String.fromCharCode(byte));
  }

  private pushByte(byte: number): void {
    if (this.pendingBytes.length === 0) this.pendingLabel = codePageLabel(this.currentCodePage());
    this.pendingBytes.push(byte);
    if (!DOUBLE_BYTE_LABELS.has(this.pendingLabel)) return;
    if (this.trailPending) this.trailPending = false;
    else if (isLeadByte(this.pendingLabel, byte)) this.trailPending = true;
  }

  private currentCodePage(): number {
    const fontId = this.state.font ?? this.defaultFont;
    const font = fontId === null ? undefined : this.fonts.get(fontId);
    if (font?.cpg !== undefined) return font.cpg;
    if (font?.charset !== undefined) {
      const fromCharset = charsetCodePage(font.charset);
      if (fromCharset !== null) return fromCharset;
    }
    return this.ansiCodePage;
  }

  private flushRun(): void {
    if (this.pendingBytes.length === 0) return;
    const bytes = Uint8Array.from(this.pendingBytes);
    const label = this.pendingLabel;
    this.pendingBytes = [];
    this.trailPending = false;
    this.emit(decodeRun(label, bytes));
  }

  private emit(text: string): void {
    if (this.state.ignore || this.state.hidden) return;
    this.out.push(text);
  }

  // MARK: Tokens

  private nextToken(): Token | null {
    const bytes = this.bytes;
    while (this.pos < bytes.length) {
      const byte = bytes[this.pos];
      if (byte === OPEN_BRACE) {
        this.pos += 1;
        return { kind: 'open' };
      }
      if (byte === CLOSE_BRACE) {
        this.pos += 1;
        return { kind: 'close' };
      }
      if (byte === CR || byte === LF) {
        // CR / LF in the source are ignored.
        this.pos += 1;
        continue;
      }
      if (byte !== BACKSLASH) {
        this.pos += 1;
        return { kind: 'text', byte };
      }
      return this.controlToken();
    }
    return null;
  }

  private controlToken(): Token | null {
    const bytes = this.bytes;
    this.pos += 1; // backslash
    if (this.pos >= bytes.length) return null;
    const first = bytes[this.pos];

    if (!isLetter(first)) {
      this.pos += 1;
      if (first === 0x27 /* ' */) {
        const hi = this.pos < bytes.length ? hexValue(bytes[this.pos]) : -1;
        const lo = this.pos + 1 < bytes.length ? hexValue(bytes[this.pos + 1]) : -1;
        if (hi < 0 || lo < 0) return { kind: 'symbol', char: 0x27 };
        this.pos += 2;
        return { kind: 'hex', byte: hi * 16 + lo };
      }
      return { kind: 'symbol', char: first };
    }

    const wordStart = this.pos;
    while (this.pos < bytes.length && isLetter(bytes[this.pos])) this.pos += 1;
    let word = '';
    for (let i = wordStart; i < this.pos; i++) word += String.fromCharCode(bytes[i]);

    let param: number | null = null;
    const negative = bytes[this.pos] === 0x2d && this.pos + 1 < bytes.length && isDigit(bytes[this.pos + 1]);
    if (negative || (this.pos < bytes.length && isDigit(bytes[this.pos]))) {
      if (negative) this.pos += 1;
      let value = 0;
      while (this.pos < bytes.length && isDigit(bytes[this.pos])) {
        value = value * 10 + (bytes[this.pos] - 0x30);
        this.pos += 1;
      }
      param = negative ? -value : value;
    }
    // A single space right after belongs to this control word.
    if (bytes[this.pos] === 0x20) this.pos += 1;

    if (word === 'bin') {
      const length = Math.max(0, param ?? 0);
      this.pos = Math.min(bytes.length, this.pos + length);
      return { kind: 'bin', length };
    }
    return { kind: 'word', word, param };
  }
}

/**
 * Decode a byte run by code page. When strict decoding of a double-byte code page run fails as a whole, decode character unit by unit; each failed unit yields one U+FFFD.
 */
function decodeRun(label: string, bytes: Uint8Array): string {
  if (!DOUBLE_BYTE_LABELS.has(label)) return new TextDecoder(label).decode(bytes);
  try {
    return new TextDecoder(label, { fatal: true }).decode(bytes);
  } catch {
    // Fall back to unit-by-unit decoding.
  }
  const decoder = new TextDecoder(label, { fatal: true });
  let text = '';
  let i = 0;
  while (i < bytes.length) {
    const byte = bytes[i];
    let unit = 1;
    if (isLeadByte(label, byte) && i + 1 < bytes.length) {
      unit = label === 'gb18030' && isDigit(bytes[i + 1]) && i + 3 < bytes.length ? 4 : 2;
    }
    try {
      text += decoder.decode(bytes.subarray(i, i + unit));
    } catch {
      text += '�';
    }
    i += unit;
  }
  return text;
}
