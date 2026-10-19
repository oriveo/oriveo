/**
 * Durable-directive detector (contract: context-contracts/directive-detector.v2.json, pipeline §7.4).
 * Pure functions over Unicode code points; lexicon and constants come only from the generated directive-lexicon.ts.
 * Primitives are exported for package-internal reuse (memory-intent.v1 builds on them); behaviour is unchanged.
 */

import {
  DIRECTIVE_IMAGE_STYLE_PREFIX_MAX,
  DIRECTIVE_LEXICON,
  DIRECTIVE_MAX_SCAN_CODE_POINTS,
  DIRECTIVE_QUESTION_ENDERS,
  DIRECTIVE_QUESTION_STARTERS,
  DIRECTIVE_QUOTE_PAIRS,
  DIRECTIVE_SENTENCE_ENDERS,
  type DirectiveLexiconLanguage,
  type DirectiveLexiconMode,
} from './directive-lexicon';
import { trimWhiteSpace } from './white-space';

export type DirectiveKind = 'language' | 'format' | 'style' | 'other';
export type DirectiveScope = 'conversation' | 'global';

export type DirectiveDetection =
  | { isDirective: false }
  | { isDirective: true; span: string; kind: DirectiveKind; scope: DirectiveScope };

const WHITE_SPACE_CP = /^[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]$/u;
export const WORD_CP = /^[\p{L}\p{N}\p{M}]$/u;
const NEWLINE = '\n';
const TRIPLE_TICK = '```';
const QUESTION_TRAILING = new Set(['。', '！', '!', '.']);

const DROPPED = (cp: number): boolean =>
  (cp >= 0x064b && cp <= 0x065f) || cp === 0x0670 || cp === 0x0640 || cp === 0x0307;
const MAPPED: ReadonlyMap<string, string> = new Map([
  ['\u0623', '\u0627'],
  ['\u0625', '\u0627'],
  ['\u0622', '\u0627'],
  ['\u0671', '\u0627'],
  ['\u0649', '\u064A'],
  ['\u0629', '\u0647'],
  ['\u0131', 'i'],
  ['\u03C2', '\u03C3'],
]);

export function isWhiteSpace(cp: string): boolean {
  return WHITE_SPACE_CP.test(cp);
}

export function norm(s: string): string {
  let out = '';
  for (const ch of s.normalize('NFKC').toLowerCase()) {
    if (DROPPED(ch.codePointAt(0)!)) continue;
    out += MAPPED.get(ch) ?? ch;
  }
  return out;
}

/** Word form without padding: non-L/N/M → space, runs collapsed, ends stripped. */
export function wordCore(s: string): string {
  let out = '';
  let space = true;
  for (const ch of norm(s)) {
    if (WORD_CP.test(ch)) {
      out += ch;
      space = false;
    } else if (!space) {
      out += ' ';
      space = true;
    }
  }
  return out.endsWith(' ') ? out.slice(0, -1) : out;
}

function padded(core: string): string {
  return core.length > 0 ? ` ${core} ` : ' ';
}

/** A lexicon term prepared for one mode. */
export interface PreparedTerm {
  readonly substring: string;
  readonly word: string;
}

export function prepare(term: string): PreparedTerm {
  return { substring: norm(term), word: wordCore(term) };
}

export interface PreparedLanguage {
  readonly mode: DirectiveLexiconMode;
  readonly markers: readonly PreparedTerm[];
  readonly verbs: readonly PreparedTerm[];
  readonly starts: readonly PreparedTerm[];
  readonly vetoes: readonly PreparedTerm[];
  readonly fillers: readonly PreparedTerm[];
  readonly questionParticlesAtEnd: readonly PreparedTerm[];
  readonly languageWords: readonly PreparedTerm[];
  readonly formatWords: readonly PreparedTerm[];
  readonly styleWords: readonly PreparedTerm[];
  readonly imageStyleWords: readonly PreparedTerm[];
  readonly globalMarkers: readonly PreparedTerm[];
}

let preparedCache: readonly PreparedLanguage[] | null = null;

export function preparedLexicon(): readonly PreparedLanguage[] {
  if (preparedCache) return preparedCache;
  preparedCache = DIRECTIVE_LEXICON.map((l: DirectiveLexiconLanguage) => ({
    mode: l.mode,
    markers: [...l.markers, ...l.globalMarkers].map(prepare),
    verbs: l.verbs.map(prepare),
    starts: l.starts.map(prepare),
    vetoes: l.vetoes.map(prepare),
    fillers: l.fillers.map(prepare),
    questionParticlesAtEnd: l.questionParticlesAtEnd.map(prepare),
    languageWords: l.languageWords.map(prepare),
    formatWords: l.formatWords.map(prepare),
    styleWords: l.styleWords.map(prepare),
    imageStyleWords: l.imageStyleWords.map(prepare),
    globalMarkers: l.globalMarkers.map(prepare),
  }));
  return preparedCache;
}

/** A sentence prepared once for matching in every mode. */
export interface SentenceForms {
  readonly norm: string;
  readonly word: string;
}

export function forms(s: string): SentenceForms {
  return { norm: norm(s), word: padded(wordCore(s)) };
}

function matches(mode: DirectiveLexiconMode, sentence: SentenceForms, term: PreparedTerm): boolean {
  if (mode === 'substring') return sentence.norm.includes(term.substring);
  if (mode === 'word') return sentence.word.includes(` ${term.word} `);
  return sentence.word.includes(` ${term.word}`);
}

export function anyMatch(mode: DirectiveLexiconMode, sentence: SentenceForms, terms: readonly PreparedTerm[]): boolean {
  return terms.some((t) => matches(mode, sentence, t));
}

export function passesStarts(
  lang: Pick<PreparedLanguage, 'mode' | 'fillers' | 'starts'>,
  sentence: SentenceForms,
): boolean {
  if (lang.mode === 'substring') {
    let head = trimWhiteSpace(sentence.norm);
    let dropped = true;
    while (dropped) {
      dropped = false;
      for (const f of lang.fillers) {
        if (head.startsWith(f.substring)) {
          head = trimWhiteSpace(head.slice(f.substring.length));
          dropped = true;
          break;
        }
      }
    }
    return lang.starts.some((s) => head.startsWith(s.substring));
  }
  let head = sentence.word;
  let dropped = true;
  while (dropped) {
    dropped = false;
    for (const f of lang.fillers) {
      const prefix = ` ${f.word} `;
      if (head.startsWith(prefix)) {
        head = ` ${head.slice(prefix.length)}`;
        dropped = true;
        break;
      }
    }
  }
  if (lang.mode === 'word') return lang.starts.some((s) => head.startsWith(` ${s.word} `));
  return lang.starts.some((s) => head.startsWith(` ${s.word}`));
}

function findFrom(cps: readonly string[], needle: readonly string[], from: number): number {
  outer: for (let i = from; i + needle.length <= cps.length; i++) {
    for (let k = 0; k < needle.length; k++) {
      if (cps[i + k] !== needle[k]) continue outer;
    }
    return i;
  }
  return -1;
}

export function mask(cps: readonly string[]): string[] {
  const out = [...cps];
  const blank = (from: number, to: number): void => {
    for (let k = from; k < to; k++) if (out[k] !== NEWLINE) out[k] = ' ';
  };
  const triple = [...TRIPLE_TICK];
  let i = 0;
  while (i < cps.length) {
    if (cps[i] === '`' && cps[i + 1] === '`' && cps[i + 2] === '`') {
      const close = findFrom(cps, triple, i + 3);
      const end = close < 0 ? cps.length : close + 3;
      blank(i, end);
      i = end;
      continue;
    }
    if (cps[i] === '`') {
      const close = cps.indexOf('`', i + 1);
      if (close >= 0) {
        blank(i, close + 1);
        i = close + 1;
        continue;
      }
      i++;
      continue;
    }
    const pair = DIRECTIVE_QUOTE_PAIRS.find(([open]) => open === cps[i]);
    if (pair) {
      const close = cps.indexOf(pair[1], i + 1);
      if (close >= 0) {
        blank(i, close + 1);
        i = close + 1;
        continue;
      }
    }
    i++;
  }
  return out;
}

export interface Sentence {
  readonly span: string;
  readonly masked: string;
  /** Code-point range [start, end) of the untrimmed sentence in the scanned text. */
  readonly start: number;
  readonly end: number;
}

export function sentences(text: string): Sentence[] {
  // Lazy prefix: a long paste must not be expanded in full before the cap.
  const cps: string[] = [];
  for (const ch of text) {
    if (cps.length >= DIRECTIVE_MAX_SCAN_CODE_POINTS) break;
    cps.push(ch);
  }
  const masked = mask(cps);
  const enders = new Set(DIRECTIVE_SENTENCE_ENDERS);
  const out: Sentence[] = [];
  let start = 0;
  const cut = (end: number): void => {
    const span = trimWhiteSpace(cps.slice(start, end).join(''));
    if (span.length > 0) out.push({ span, masked: trimWhiteSpace(masked.slice(start, end).join('')), start, end });
    start = end;
  };
  for (let i = 0; i < masked.length; i++) {
    const ch = masked[i]!;
    if (enders.has(ch) || ch === NEWLINE) cut(i + 1);
    else if (ch === '.' && (i + 1 === masked.length || isWhiteSpace(masked[i + 1]!))) cut(i + 1);
  }
  if (start < masked.length) cut(masked.length);
  return out;
}

export function isQuestion(masked: string): boolean {
  const cps = [...masked];
  if (cps.length > 0 && DIRECTIVE_QUESTION_ENDERS.includes(cps[cps.length - 1]!)) return true;
  if (cps.length > 0 && DIRECTIVE_QUESTION_STARTERS.includes(cps[0]!)) return true;
  let end = cps.length;
  while (end > 0 && QUESTION_TRAILING.has(cps[end - 1]!)) end--;
  const stripped = forms(trimWhiteSpace(cps.slice(0, end).join('')));
  return preparedLexicon().some((lang) =>
    lang.questionParticlesAtEnd.some((p) =>
      lang.mode === 'substring' ? stripped.norm.endsWith(p.substring) : stripped.word.endsWith(` ${p.word} `),
    ),
  );
}

function anyLanguage(sentence: SentenceForms, pick: (l: PreparedLanguage) => readonly PreparedTerm[]): boolean {
  return preparedLexicon().some((l) => anyMatch(l.mode, sentence, pick(l)));
}

function kindOf(sentence: SentenceForms): DirectiveKind {
  if (anyLanguage(sentence, (l) => l.languageWords)) return 'language';
  if (anyLanguage(sentence, (l) => l.formatWords)) return 'format';
  if (anyLanguage(sentence, (l) => l.styleWords) || anyLanguage(sentence, (l) => l.imageStyleWords)) return 'style';
  return 'other';
}

function isDirectiveSentence(sentence: SentenceForms): boolean {
  return preparedLexicon().some(
    (l) =>
      anyMatch(l.mode, sentence, l.markers) &&
      anyMatch(l.mode, sentence, l.verbs) &&
      !anyMatch(l.mode, sentence, l.vetoes) &&
      passesStarts(l, sentence),
  );
}

/** Detects the first durable directive sentence in text; never changes anything by itself. */
export function detectDirective(text: string): DirectiveDetection {
  for (const s of sentences(text)) {
    if (isQuestion(s.masked)) continue;
    const f = forms(s.masked);
    if (!isDirectiveSentence(f)) continue;
    return {
      isDirective: true,
      span: s.span,
      kind: kindOf(f),
      scope: anyLanguage(f, (l) => l.globalMarkers) ? 'global' : 'conversation',
    };
  }
  return { isDirective: false };
}

/** Image-generation style prefix from conversation instructions; empty when none. */
export function imageStylePrefix(instructions: string): string {
  const kept: string[] = [];
  for (const s of sentences(instructions)) {
    if (isQuestion(s.masked)) continue;
    const f = forms(s.masked);
    if (kindOf(f) === 'style' && anyLanguage(f, (l) => l.imageStyleWords)) kept.push(s.span);
  }
  if (kept.length === 0) return '';
  const first = [...kept[0]!];
  if (first.length > DIRECTIVE_IMAGE_STYLE_PREFIX_MAX) {
    return trimWhiteSpace(first.slice(0, DIRECTIVE_IMAGE_STYLE_PREFIX_MAX).join(''));
  }
  let joined = kept[0]!;
  let total = first.length;
  for (const span of kept.slice(1)) {
    const size = [...span].length + 1;
    if (total + size > DIRECTIVE_IMAGE_STYLE_PREFIX_MAX) break;
    joined += ` ${span}`;
    total += size;
  }
  return joined;
}
