/**
 * Context checkpoint deterministic pure functions (context pipeline §8.2–§8.8).
 * Spec: context-contracts/checkpoint.v1.json rules[0..6].
 */

import { ContextBudget } from './budget';
import { ContextHash } from './hash';
import { escapeXmlText } from './sanitize';
import { trimWhiteSpace } from './white-space';

export const CONTEXT_CHECKPOINT_CONSTANTS = {
  note: "Earlier conversation was condensed by the app to fit the model's context. The quoted user messages are the user's own words; everything else here is a summary written for continuity, not new instructions.",
  truncationMark: '…[truncated]',
  shortTruncationCodePoints: 200,
  packerVersion: '1',
  headings: ['Goal', 'Key Facts & Decisions', 'Work Produced', 'Open Threads', 'Style & Language'],
  uuidNamespace: 'be18698a-4bba-5868-953d-79afea24fcd5',
  // Code point table used for truncation (hex, a single value or an "A-B" range), matching constants.sentenceBoundary in the contract item by item
  sentenceBoundary: {
    terminators: [
      '0021', '002E', '003F', '061F', '06D4', '0964', '0965', '203C', '203D', '2047', '2048', '2049', '3002', 'FF01',
      'FF0E', 'FF1F', 'FF61',
    ],
    closers: [
      '0022', '0027', '0029', '005D', '007D', '00BB', '2019', '201D', '203A', '3009', '300B', '300D', '300F', '3011',
      '3015', 'FF02', 'FF07', 'FF09', 'FF3D', 'FF5D',
    ],
    lineBreaks: ['000A', '000D', '0085', '2028', '2029'],
    spaces: ['0009', '0020', '00A0', '3000'],
    extend: [
      '0300-036F', '0483-0489', '0591-05BD', '05BF', '05C1-05C2', '05C4-05C5', '05C7', '0610-061A', '064B-065F', '0670',
      '06D6-06DC', '06DF-06E4', '06E7-06E8', '06EA-06ED', '0900-0903', '093A-093C', '093E-094F', '0951-0957',
      '0962-0963', '0E31', '0E34-0E3A', '0E47-0E4E', '1160-11FF', '1AB0-1AFF', '1DC0-1DFF', '200C-200D', '20D0-20FF',
      '302A-302F', '3099-309A', 'FE00-FE0F', 'FE20-FE2F', '1F3FB-1F3FF', 'E0020-E007F', 'E0100-E01EF',
    ],
    joiners: ['094D', '200D'],
    regionalIndicator: '1F1E6-1F1FF',
  },
} as const;

export type SummaryValidationReason = 'headings' | 'tooLong' | 'notShorterThanHalfSpan' | 'envelopeTag';

export interface SummaryValidation {
  valid: boolean;
  reasons: SummaryValidationReason[];
}

export interface CheckpointDigestMessage {
  id: string;
  text: string;
}

export interface CheckpointConcurrencyCandidate {
  checkpointId: string;
  coversToIndex: number;
  createdAtMillis: number;
}

export interface CheckpointSpanMessage {
  id: string;
  role: 'user' | 'assistant';
  estTokens: number;
}

export type CheckpointSpan =
  | {
      action: 'compact';
      /** null when the tail is empty (no user message after the span). */
      tailStartId: string | null;
      spanIds: string[];
      coversFrom: string;
      coversTo: string;
      messagesCovered: number;
    }
  | { action: 'noop'; tailStartId: string | null };

export interface CheckpointUserCandidate {
  id: string;
  text: string;
  isDirective?: boolean;
}

export interface CheckpointKeptMessage {
  id: string;
  text: string;
  truncated: boolean;
}

export interface CheckpointFallbackMessage extends CheckpointSpanMessage {
  text?: string;
  isDirective?: boolean;
}

export interface CheckpointFallbackResult {
  checkpointText?: string;
  tailStartId: string | null;
  keptUserIds: string[];
  total: number;
  targetMet: boolean;
  stages: string[];
}

const encoder = new TextEncoder();
const { truncationMark, shortTruncationCodePoints, sentenceBoundary } = CONTEXT_CHECKPOINT_CONSTANTS;

type CodePointRange = readonly [number, number];

function parseRanges(entries: readonly string[]): CodePointRange[] {
  return entries.map((entry) => {
    const [from, to = from] = entry.split('-');
    return [parseInt(from, 16), parseInt(to, 16)] as const;
  });
}

function inRanges(ranges: readonly CodePointRange[], cp: number | undefined): boolean {
  return cp !== undefined && ranges.some(([from, to]) => cp >= from && cp <= to);
}

const TERMINATORS = parseRanges(sentenceBoundary.terminators);
const CLOSERS = parseRanges(sentenceBoundary.closers);
const LINE_BREAKS = parseRanges(sentenceBoundary.lineBreaks);
const SPACES = parseRanges(sentenceBoundary.spaces);
const EXTEND = parseRanges(sentenceBoundary.extend);
const JOINERS = parseRanges(sentenceBoundary.joiners);
const REGIONAL_INDICATORS = parseRanges([sentenceBoundary.regionalIndicator]);
const CR = 0x0d;
const LF = 0x0a;
const FULL_STOP = 0x2e;
const EXCLAMATION = 0x21;
const QUESTION = 0x3f;

function isWhiteSpace(cp: number | undefined): boolean {
  return cp !== undefined && trimWhiteSpace(String.fromCodePoint(cp)).length === 0;
}

function isAsciiLower(cp: number | undefined): boolean {
  return cp !== undefined && cp >= 0x61 && cp <= 0x7a;
}

function isAsciiAlnum(cp: number | undefined): boolean {
  return (
    cp !== undefined && ((cp >= 0x30 && cp <= 0x39) || (cp >= 0x41 && cp <= 0x5a) || (cp >= 0x61 && cp <= 0x7a))
  );
}

/** Per code point layout used by the boundary search. */
interface TextLayout {
  cps: number[];
  chars: string[];
  /** Positions after a sentence end (run of terminators + closers, outside fence lines). */
  sentenceEnds: Set<number>;
  onFenceLine: boolean[];
}

interface FenceRun {
  char: string;
  length: number;
  /** Index right after the run. */
  after: number;
}

/** At most 3 U+0020 then >= 3 backticks or tildes; null when the line is not a fence line. */
function fenceRun(chars: readonly string[], lineStart: number, lineEnd: number): FenceRun | null {
  let i = lineStart;
  while (i < lineEnd && i - lineStart < 3 && chars[i] === ' ') i += 1;
  const char = chars[i];
  if (char !== '`' && char !== '~') return null;
  let j = i;
  while (j < lineEnd && chars[j] === char) j += 1;
  if (j - i < 3) return null;
  return { char, length: j - i, after: j };
}

interface FenceScan {
  onFenceLine: boolean[];
  /** Opening run of the fence still open at the end of the text; null when none. */
  openRun: string | null;
}

/** Reads fences line by line; a partial last line is just a shorter line (opens with >= 3, closes with the full run). */
function scanFences(chars: readonly string[], cps: readonly number[]): FenceScan {
  const L = cps.length;
  // Split into lines on line breaks (CR LF counts as one) and check fences line by line
  const lines: Array<{ start: number; end: number }> = [];
  let lineStart = 0;
  for (let i = 0; i < L; i += 1) {
    if (!inRanges(LINE_BREAKS, cps[i])) continue;
    lines.push({ start: lineStart, end: i });
    if (cps[i] === CR && cps[i + 1] === LF) i += 1;
    lineStart = i + 1;
  }
  lines.push({ start: lineStart, end: L });

  const onFenceLine = new Array<boolean>(L).fill(false);
  let open: { char: string; length: number; run: string; firstLine: number } | null = null;
  for (const [index, line] of lines.entries()) {
    const run = fenceRun(chars, line.start, line.end);
    if (open === null) {
      if (run !== null) {
        const opening = run.char.repeat(run.length);
        open = { char: run.char, length: run.length, run: opening, firstLine: index };
      }
      continue;
    }
    if (run === null || run.char !== open.char || run.length < open.length) continue;
    const rest = chars.slice(run.after, line.end);
    if (!rest.every((c) => c === ' ' || c === '\t')) continue;
    for (let k = open.firstLine; k <= index; k += 1) onFenceLine.fill(true, lines[k].start, lines[k].end);
    open = null;
  }
  if (open === null) return { onFenceLine, openRun: null };
  const { run, firstLine } = open;
  for (let k = firstLine; k < lines.length; k += 1) onFenceLine.fill(true, lines[k].start, lines[k].end);
  return { onFenceLine, openRun: run };
}

function layout(text: string): TextLayout {
  const chars = Array.from(text);
  const cps = chars.map((c) => c.codePointAt(0) ?? 0);
  const L = cps.length;
  const { onFenceLine } = scanFences(chars, cps);

  const sentenceEnds = new Set<number>();
  for (let i = 0; i < L; i += 1) {
    if (!inRanges(TERMINATORS, cps[i]) || (i > 0 && inRanges(TERMINATORS, cps[i - 1]))) continue;
    let j = i;
    while (j < L && inRanges(TERMINATORS, cps[j])) j += 1;
    let k = j;
    while (k < L && inRanges(CLOSERS, cps[k])) k += 1;
    if (onFenceLine[i]) continue;
    const last = cps[j - 1];
    const next = cps[k];
    if (last === FULL_STOP) {
      if (k < L && !isWhiteSpace(next)) continue;
      let n = k;
      while (n < L && isWhiteSpace(cps[n])) n += 1;
      if (isAsciiLower(cps[n])) continue;
    } else if ((last === EXCLAMATION || last === QUESTION) && isAsciiAlnum(next)) {
      continue;
    }
    sentenceEnds.add(k);
  }
  return { cps, chars, sentenceEnds, onFenceLine };
}

/** True when position p splits a grapheme (extend mark, after a joiner, or inside a regional-indicator pair). */
function splitsCluster(cps: readonly number[], p: number): boolean {
  if (inRanges(EXTEND, cps[p]) || inRanges(JOINERS, cps[p - 1])) return true;
  if (!inRanges(REGIONAL_INDICATORS, cps[p - 1]) || !inRanges(REGIONAL_INDICATORS, cps[p])) return false;
  let count = 0;
  for (let i = p - 1; i >= 0 && inRanges(REGIONAL_INDICATORS, cps[i]); i -= 1) count += 1;
  return count % 2 === 1;
}

function headCut(text: TextLayout, n: number): string {
  const { cps, chars, sentenceEnds, onFenceLine } = text;
  // The prefix is non-empty after trimming trailing whitespace iff it contains a non-whitespace code point
  const firstContent = cps.findIndex((cp) => !isWhiteSpace(cp));
  const nonEmpty = (p: number) => firstContent >= 0 && p > firstContent;
  const isLineBreakBoundary = (p: number) => inRanges(LINE_BREAKS, cps[p]) && !(cps[p] === LF && cps[p - 1] === CR);
  let cut = -1;
  for (let p = n; p >= Math.ceil(n / 2) && cut < 0; p -= 1) {
    if ((sentenceEnds.has(p) || isLineBreakBoundary(p)) && nonEmpty(p)) cut = p;
  }
  for (let p = n; p >= Math.ceil(n / 2) && cut < 0; p -= 1) {
    if (inRanges(SPACES, cps[p]) && !onFenceLine[p] && nonEmpty(p)) cut = p;
  }
  if (cut < 0) {
    let p = n;
    while (p > 0 && splitsCluster(cps, p)) p -= 1;
    cut = p === 0 ? n : p;
  }
  let end = cut;
  while (end > 0 && isWhiteSpace(cps[end - 1])) end -= 1;
  // Whether it stops inside an open fence depends only on the retained prefix itself
  const { openRun } = scanFences(chars.slice(0, end), cps.slice(0, end));
  const prefix = chars.slice(0, end).join('');
  return openRun !== null ? `${prefix}\n${openRun}` : prefix;
}

function tailCut(text: TextLayout, m: number): string {
  const { cps, chars, sentenceEnds, onFenceLine } = text;
  const L = cps.length;
  let lastContent = L - 1;
  while (lastContent >= 0 && isWhiteSpace(cps[lastContent])) lastContent -= 1;
  const nonEmpty = (s: number) => s <= lastContent;
  const afterLineBreak = (s: number) => inRanges(LINE_BREAKS, cps[s - 1]) && !(cps[s - 1] === CR && cps[s] === LF);
  const from = Math.max(L - m, 0);
  const to = L - Math.ceil(m / 2);
  let cut = -1;
  for (let s = from; s <= to && cut < 0; s += 1) {
    if ((sentenceEnds.has(s) || afterLineBreak(s)) && nonEmpty(s)) cut = s;
  }
  for (let s = from; s <= to && cut < 0; s += 1) {
    if (s > 0 && inRanges(SPACES, cps[s - 1]) && !onFenceLine[s - 1] && nonEmpty(s)) cut = s;
  }
  if (cut < 0) {
    let s = from;
    while (s < L && splitsCluster(cps, s)) s += 1;
    cut = s === L ? from : s;
  }
  let begin = cut;
  while (begin < L && isWhiteSpace(cps[begin])) begin += 1;
  // Whether it starts inside an open fence depends only on the text before the start, text[0..begin)
  const { openRun } = scanFences(chars.slice(0, begin), cps.slice(0, begin));
  const suffix = chars.slice(begin).join('');
  return openRun !== null ? `${openRun}\n${suffix}` : suffix;
}

/**
 * Rule Truncate: cut raw text on sentence / line / space boundaries (code points; XML escaping happens later).
 * tail null → head only; returns text unchanged when it already fits.
 */
function truncate(text: string, head: number, tail: number | null): string {
  const length = Array.from(text).length;
  if (length <= head + (tail ?? 0)) return text;
  const parsed = layout(text);
  const headText = headCut(parsed, head);
  return tail === null ? headText + truncationMark : headText + truncationMark + tailCut(parsed, tail);
}

function lastUserIndex(messages: readonly CheckpointSpanMessage[], before = messages.length): number {
  for (let i = before - 1; i >= 0; i -= 1) {
    if (messages[i].role === 'user') return i;
  }
  return -1;
}

/** Index where the tail starts for a given tail budget; messages.length when there is no user message. */
function tailStart(messages: readonly CheckpointSpanMessage[], tailBudget: number, previousEnd: number): number {
  let start = messages.length;
  let sum = 0;
  while (start > 0 && sum + messages[start - 1].estTokens <= tailBudget) {
    sum += messages[start - 1].estTokens;
    start -= 1;
  }
  // Move the start forward to the first user message; if the tail is empty or has no user message, start from the latest user message
  while (start < messages.length && messages[start].role !== 'user') start += 1;
  if (start >= messages.length) {
    const latest = lastUserIndex(messages);
    start = latest >= 0 ? latest : messages.length;
  }
  // The tail must not fall inside the range covered by the previous checkpoint: if it does, start from the first user message after it
  if (start >= previousEnd) return start;
  for (let i = previousEnd; i < messages.length; i += 1) {
    if (messages[i].role === 'user') return i;
  }
  return previousEnd;
}

function spanWithTail(
  messages: readonly CheckpointSpanMessage[],
  tailBudget: number,
  previousCoversTo?: string | null,
): CheckpointSpan & { start: number } {
  const previousIndex = previousCoversTo ? messages.findIndex((m) => m.id === previousCoversTo) : -1;
  const previousEnd = previousIndex + 1;
  const start = tailStart(messages, tailBudget, previousEnd);
  const tailStartId = start < messages.length ? messages[start].id : null;
  const span = messages.slice(previousEnd, start);
  if (span.length === 0) return { action: 'noop', tailStartId, start };
  return {
    action: 'compact',
    tailStartId,
    spanIds: span.map((m) => m.id),
    coversFrom: messages[0].id,
    coversTo: span[span.length - 1].id,
    messagesCovered: start,
    start,
  };
}

function selectSpan(
  messages: readonly CheckpointSpanMessage[],
  B: number,
  previousCoversTo?: string | null,
): CheckpointSpan {
  const { start: _start, ...span } = spanWithTail(messages, ContextBudget.derive(B).tail, previousCoversTo);
  return span;
}

/** Longest prefix of at most maxBytes UTF-8 bytes, cut on a code point boundary. */
function headBytes(codePoints: readonly string[], maxBytes: number): string {
  let used = 0;
  let out = '';
  for (const cp of codePoints) {
    const size = encoder.encode(cp).length;
    if (used + size > maxBytes) break;
    used += size;
    out += cp;
  }
  return out;
}

/** Longest suffix of at most maxBytes UTF-8 bytes, cut on a code point boundary. */
function tailBytes(codePoints: readonly string[], maxBytes: number): string {
  let used = 0;
  let index = codePoints.length;
  while (index > 0) {
    const size = encoder.encode(codePoints[index - 1]).length;
    if (used + size > maxBytes) break;
    used += size;
    index -= 1;
  }
  return codePoints.slice(index).join('');
}

/** Text longer than shortTruncationCodePoints cut by truncate(text, 200, null); null when it already fits. */
function shortTruncation(text: string): string | null {
  const cut = truncate(text, shortTruncationCodePoints, null);
  return cut === text ? null : cut;
}

function pickUserMessages(
  candidates: readonly CheckpointUserCandidate[],
  B: number,
  rhoHi: number,
  userMessagesMax?: number,
): CheckpointKeptMessage[] {
  const max = userMessagesMax ?? ContextBudget.derive(B).userMessagesMax;
  const indexed = candidates.map((candidate, index) => ({ candidate, index }));
  const newestFirst = [...indexed].reverse();
  const order = [
    ...newestFirst.filter((e) => e.candidate.isDirective === true),
    ...newestFirst.filter((e) => e.candidate.isDirective !== true),
  ];
  let remaining = max;
  const kept: Array<{ index: number; message: CheckpointKeptMessage }> = [];
  const keep = (index: number, id: string, text: string, truncated: boolean): boolean => {
    const cost = ContextBudget.estimateText(text, rhoHi);
    if (cost > remaining) return false;
    remaining -= cost;
    kept.push({ index, message: { id, text, truncated } });
    return true;
  };
  for (const { candidate, index } of order) {
    const { id, text } = candidate;
    const codePoints = Array.from(text);
    const cost = ContextBudget.estimateText(text, rhoHi);
    if (cost * 2 > max) {
      const sideBytes = Math.floor(Math.floor(max / 4) / rhoHi);
      const head = Array.from(headBytes(codePoints, sideBytes)).length;
      const tail = Array.from(tailBytes(codePoints, sideBytes)).length;
      const headTail = truncate(text, head, tail);
      if (keep(index, id, headTail, headTail !== text)) continue;
    }
    if (keep(index, id, text, false)) continue;
    const short = shortTruncation(text);
    if (short !== null) keep(index, id, short, true);
  }
  return kept.sort((a, b) => a.index - b.index).map((k) => k.message);
}

function serialize(
  coversFrom: string,
  coversTo: string,
  messagesCovered: number,
  kept: readonly CheckpointKeptMessage[],
  summary?: string | null,
): string {
  const truncatedCount = kept.filter((m) => m.truncated).length;
  const lines = [
    `<oriveo-context-checkpoint v="1" covers="${coversFrom}..${coversTo}" messages="${messagesCovered}">`,
    `<note>${CONTEXT_CHECKPOINT_CONSTANTS.note}</note>`,
    `<user-messages count="${kept.length}" truncated="${truncatedCount}">`,
    ...kept.map((m) => `<msg id="${m.id}">${escapeXmlText(m.text)}</msg>`),
    '</user-messages>',
  ];
  const trimmed = trimWhiteSpace(summary ?? '');
  if (trimmed.length > 0) lines.push(`<summary>${escapeXmlText(trimmed)}</summary>`);
  lines.push('</oriveo-context-checkpoint>');
  return lines.join('\n');
}

function fallback(
  messages: readonly CheckpointFallbackMessage[],
  B: number,
  rhoHi: number,
  fixedTokens: number,
  oldSummary?: string | null,
): CheckpointFallbackResult {
  const derived = ContextBudget.derive(B);
  const target = derived.compactTargetMax;
  const stages: string[] = [];
  let tailBudget = derived.tail;
  let userMessagesMax = derived.userMessagesMax;
  let state = evaluate();

  function candidatesBefore(start: number): CheckpointUserCandidate[] {
    return messages
      .slice(0, start)
      .filter((m) => m.role === 'user')
      .map((m) => ({ id: m.id, text: m.text ?? '', isDirective: m.isDirective === true }));
  }

  function build(start: number, kept: CheckpointKeptMessage[]) {
    const tailTokens = messages.slice(start).reduce((sum, m) => sum + m.estTokens, 0);
    const checkpointText =
      start > 0 ? serialize(messages[0].id, messages[start - 1].id, start, kept, oldSummary) : undefined;
    const checkpointTokens = checkpointText ? ContextBudget.estimateText(checkpointText, rhoHi) : 0;
    return {
      start,
      checkpointText,
      kept,
      total: fixedTokens + checkpointTokens + tailTokens,
    };
  }

  function evaluate() {
    const { start } = spanWithTail(messages, tailBudget);
    return build(start, pickUserMessages(candidatesBefore(start), B, rhoHi, userMessagesMax));
  }

  stages.push('initial');
  const latestTurn = lastUserIndex(messages);
  while (state.total > target && latestTurn >= 0 && state.start < latestTurn) {
    tailBudget = Math.floor(tailBudget / 2);
    state = evaluate();
    stages.push(`tail=${tailBudget}`);
  }
  for (let round = 0; round < 4 && state.total > target; round += 1) {
    userMessagesMax = Math.floor(userMessagesMax / 2);
    state = evaluate();
    stages.push(`userMessages=${userMessagesMax}`);
  }
  if (state.total > target) {
    const candidates = candidatesBefore(state.start);
    const directive = [...candidates].reverse().find((c) => c.isDirective === true);
    const newest = candidates[candidates.length - 1];
    const minimal = candidates
      .filter((c) => c === directive || c === newest)
      .map((c) => {
        const short = shortTruncation(c.text);
        return short === null
          ? { id: c.id, text: c.text, truncated: false }
          : { id: c.id, text: short, truncated: true };
      });
    state = build(state.start, minimal);
    stages.push('minimal');
  }

  return {
    ...(state.checkpointText !== undefined ? { checkpointText: state.checkpointText } : {}),
    tailStartId: state.start < messages.length ? messages[state.start].id : null,
    keptUserIds: state.kept.map((m) => m.id),
    total: state.total,
    targetMet: state.total <= target,
    stages,
  };
}

/**
 * Normalize headings: a line "## <heading><spaces/tabs><—|–|-><anything>" becomes "## <heading>";
 * one trailing \r is set aside and put back; every other line is unchanged.
 */
function normalizeHeadings(summary: string): string {
  return summary
    .split('\n')
    .map((line) => {
      const cr = line.endsWith('\r');
      const body = cr ? line.slice(0, -1) : line;
      for (const heading of CONTEXT_CHECKPOINT_CONSTANTS.headings) {
        const prefix = `## ${heading}`;
        if (body.startsWith(prefix) && /^[ \t]+[—–-]/.test(body.slice(prefix.length))) {
          return cr ? `${prefix}\r` : prefix;
        }
      }
      return line;
    })
    .join('\n');
}

/** Rule 3: level-2 headings exact and in order, length caps, no envelope tags. */
function validateSummary(summary: string, summaryMax: number, spanTokens: number, rhoHi: number): SummaryValidation {
  const reasons: SummaryValidationReason[] = [];
  const headingLines = summary
    .split('\n')
    .map((line) => (line.endsWith('\r') ? line.slice(0, -1) : line))
    .filter((line) => line.startsWith('## '));
  const expected = CONTEXT_CHECKPOINT_CONSTANTS.headings.map((h) => `## ${h}`);
  if (headingLines.length !== expected.length || headingLines.some((line, i) => line !== expected[i])) {
    reasons.push('headings');
  }
  const est = ContextBudget.estimateText(summary, rhoHi);
  if (est > Math.floor(summaryMax * 1.2)) reasons.push('tooLong');
  if (est > Math.floor(0.5 * spanTokens)) reasons.push('notShorterThanHalfSpan');
  // Lower-case ASCII only: case mappings of non-ASCII characters do not take part in the decision
  if (summary.replace(/[A-Z]/g, (c) => c.toLowerCase()).includes('<oriveo-')) reasons.push('envelopeTag');
  return { valid: reasons.length === 0, reasons };
}

/** Rule 4: sha256 hex of the UTF-8 text. */
function textHash(text: string): string {
  return ContextHash.sha256Hex(text);
}

/** Rule 4: sha256 hex of concat(id + \n + textHash + \n) over covered messages in order. */
function coversDigest(messages: readonly CheckpointDigestMessage[]): string {
  return ContextHash.sha256Hex(messages.map((m) => `${m.id}\n${textHash(m.text)}\n`).join(''));
}

/** Rule 4: UUIDv5(namespace, conversationId + \n + coversTo + \n + packerVersion), lowercase. */
function checkpointId(conversationId: string, coversTo: string, packerVersion: string): string {
  return ContextHash.uuidV5(
    CONTEXT_CHECKPOINT_CONSTANTS.uuidNamespace,
    `${conversationId}\n${coversTo}\n${packerVersion}`,
  );
}

/** Rule 5: later coversTo wins; tie → earlier createdAt; tie → smaller checkpointId. */
function resolveConcurrency<T extends CheckpointConcurrencyCandidate>(a: T, b: T): T {
  if (a.coversToIndex !== b.coversToIndex) return a.coversToIndex > b.coversToIndex ? a : b;
  if (a.createdAtMillis !== b.createdAtMillis) return a.createdAtMillis < b.createdAtMillis ? a : b;
  return b.checkpointId < a.checkpointId ? b : a;
}

export const ContextCheckpoint = {
  constants: CONTEXT_CHECKPOINT_CONSTANTS,
  selectSpan,
  pickUserMessages,
  truncate,
  serialize,
  fallback,
  normalizeHeadings,
  validateSummary,
  textHash,
  coversDigest,
  checkpointId,
  resolveConcurrency,
};
