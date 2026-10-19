/**
 * Memory write intent (contract: context-contracts/memory-intent.v1.json).
 * Pure functions: classify one user message, derive a pending memory candidate, and move candidates through
 * accept / reject / sweep. Nothing here touches storage or the cloud; a classification never yields an active item.
 * Primitives come from directive-detector (directive-detector.v2); the lexicon only from the generated memory-intent-lexicon.ts.
 */

import {
  WORD_CP,
  anyMatch,
  detectDirective,
  forms,
  isQuestion,
  isWhiteSpace,
  mask,
  norm,
  passesStarts,
  prepare,
  preparedLexicon,
  sentences,
  wordCore,
  type PreparedLanguage,
  type PreparedTerm,
  type SentenceForms,
} from './directive-detector';
import { DIRECTIVE_LEXICON, DIRECTIVE_MAX_SCAN_CODE_POINTS, type DirectiveLexiconMode } from './directive-lexicon';
import { ContextHash } from './hash';
import { memoryLayerOfKind, type MemoryKind, type MemoryLayer, type MemoryScope } from './memory-items';
import {
  MEMORY_INTENT_CANDIDATE_TTL_MS,
  MEMORY_INTENT_CODE_TOKEN_CHARS,
  MEMORY_INTENT_CONFIDENCE_EXPLICIT,
  MEMORY_INTENT_CONFIDENCE_IMPLICIT,
  MEMORY_INTENT_CONTENT_MAX_CODE_POINTS,
  MEMORY_INTENT_LEXICON,
  MEMORY_INTENT_SECRET_PATTERNS,
  MEMORY_INTENT_SEPARATORS,
  MEMORY_INTENT_UUID_NAMESPACE,
  type MemoryIntentLexiconLanguage,
} from './memory-intent-lexicon';
import { trimWhiteSpace } from './white-space';

export type MemoryIntent =
  | 'explicit_persist'
  | 'implicit_persist'
  | 'transient'
  | 'recall'
  | 'delete_or_supersede'
  | 'ack_or_meta'
  | 'uncertain'
  | 'none';
export type MemoryIntentRule =
  | 'quoted'
  | 'meta'
  | 'question'
  | 'recall'
  | 'delete'
  | 'supersede'
  | 'transient'
  | 'reminder'
  | 'reminisce'
  | 'anaphor'
  | 'persist'
  | 'directive'
  | 'loose_directive'
  | 'ack'
  | 'anaphor_directive';
export type MemoryIntentScope = 'global' | 'folder' | 'conversation' | 'unspecified';
export type MemoryIntentSensitive = 'none' | 'secret' | 'special';
export type MemoryIntentBlocked = 'conversation_scope' | 'secret' | 'special' | 'too_long';
export type MemoryIntentSuggestion = 'memory' | 'conversationInstruction' | 'none';

export interface MemoryIntentClassification {
  readonly intent: MemoryIntent;
  readonly rule: MemoryIntentRule | null;
  readonly span: string | null;
  readonly proposition: string | null;
  readonly kind: MemoryKind | null;
  readonly scope: MemoryIntentScope | null;
  readonly sensitive: MemoryIntentSensitive;
  readonly blocked: MemoryIntentBlocked | null;
  readonly suggestion: MemoryIntentSuggestion;
}

export type MemoryCandidateStatus = 'pending' | 'accepted' | 'rejected' | 'superseded' | 'expired';
export type MemoryCandidateSkipReason =
  | 'no_suggestion'
  | 'auto_suggest_off'
  | 'duplicate_active'
  | 'exists'
  | 'duplicate_pending'
  | 'rejected_recently';
export type MemoryCandidateTransitionError = 'not_pending' | 'expired' | 'empty' | 'too_long';

export interface MemoryCandidateSource {
  readonly type: 'conversation';
  readonly conversationId: string | null;
  readonly messageIds: readonly string[];
  readonly observedAtMs: number | null;
}

/** A local-only candidate record (never cloud-synced, never backed up). Times are epoch milliseconds. */
export interface MemoryCandidateRecord {
  readonly id: string;
  readonly status: MemoryCandidateStatus;
  readonly proposedLayer: MemoryLayer;
  readonly proposedKind: MemoryKind;
  readonly content: string;
  readonly scope: MemoryScope;
  readonly source: MemoryCandidateSource;
  readonly sensitivity: 'normal';
  readonly confidence: number;
  readonly fingerprint: string;
  readonly createdAtMs: number;
  readonly expiresAtMs: number;
  readonly resolvedAtMs: number | null;
}

/** Draft for a new Memory Item; the client creates the item through its normal create path. */
export interface MemoryCandidateItemDraft {
  readonly layer: MemoryLayer;
  readonly kind: MemoryKind;
  readonly status: 'active';
  readonly content: string;
  readonly scope: MemoryScope;
  readonly source: MemoryCandidateSource;
  readonly sensitivity: 'normal';
  readonly confidence: number;
}

export interface MemoryCandidateContext {
  readonly conversationId: string;
  readonly folderId: string | null;
  readonly messageId: string;
  readonly nowMs: number;
  readonly activeContents: readonly string[];
  readonly records: readonly MemoryCandidateRecord[];
  /** Local auto-suggest switch; absent means on. Off only stops implicit_persist (an explicit "remember" still creates). */
  readonly autoSuggest?: boolean;
}

export type MemoryCandidateOutcome =
  | { action: 'create'; reason: null; candidate: MemoryCandidateRecord }
  | { action: 'skip'; reason: MemoryCandidateSkipReason; candidate: null };

export interface MemoryCandidateEdit {
  readonly content?: string | null;
  readonly kind?: MemoryKind | null;
  readonly scope?: MemoryScope | null;
}

export type MemoryCandidateAcceptResult =
  | { record: MemoryCandidateRecord; item: MemoryCandidateItemDraft }
  | { error: MemoryCandidateTransitionError };

export type MemoryCandidateRejectResult = { record: MemoryCandidateRecord } | { error: 'not_pending' };

export interface MemoryCandidateSweep {
  keptIds: string[];
  expiredIds: string[];
  supersededIds: string[];
  purgedIds: string[];
}

type TermKey = {
  [K in keyof MemoryIntentLexiconLanguage]: MemoryIntentLexiconLanguage[K] extends readonly string[] ? K : never;
}[keyof MemoryIntentLexiconLanguage];

const KIND_STARTS = [
  ['project', 'kindProject'],
  ['goal', 'kindGoal'],
  ['preference', 'kindPreference'],
  ['identity', 'kindIdentity'],
] as const satisfies ReadonlyArray<readonly [MemoryKind, TermKey]>;

/** A raw term for proposition extraction: code points plus whether a word boundary must follow. */
interface RawTerm {
  readonly cps: readonly string[];
  readonly word: boolean;
}

interface MemoryLanguage {
  readonly mode: DirectiveLexiconMode;
  readonly raw: MemoryIntentLexiconLanguage;
  readonly dir: PreparedLanguage;
  readonly dirFillers: readonly string[];
  readonly terms: ReadonlyMap<TermKey, readonly PreparedTerm[]>;
}

interface Prepared {
  readonly langs: readonly MemoryLanguage[];
  readonly persistStarts: readonly RawTerm[];
  readonly leading: readonly RawTerm[];
  readonly linkers: readonly RawTerm[];
  readonly separators: ReadonlySet<string>;
  readonly codeTokens: ReadonlySet<string>;
  readonly patterns: ReadonlyArray<{ readonly regex: RegExp; readonly luhn: boolean }>;
}

let preparedCache: Prepared | null = null;

function prepared(): Prepared {
  if (preparedCache) return preparedCache;
  const dirLexicon = preparedLexicon();
  const langs = MEMORY_INTENT_LEXICON.map((raw): MemoryLanguage => {
    const index = DIRECTIVE_LEXICON.findIndex((l) => l.code === raw.code);
    if (index < 0) throw new Error(`memory-intent language without directive language: ${raw.code}`);
    const terms = new Map<TermKey, readonly PreparedTerm[]>();
    for (const key of Object.keys(raw) as Array<keyof MemoryIntentLexiconLanguage>) {
      const value = raw[key];
      if (Array.isArray(value)) terms.set(key as TermKey, (value as readonly string[]).map(prepare));
    }
    return { mode: raw.mode, raw, dir: dirLexicon[index]!, dirFillers: DIRECTIVE_LEXICON[index]!.fillers, terms };
  });
  const rawTerms = (lang: MemoryLanguage, list: readonly string[]): RawTerm[] =>
    list.filter((t) => t.length > 0).map((t) => ({ cps: [...t], word: lang.mode === 'word' }));
  preparedCache = {
    langs,
    persistStarts: langs.flatMap((l) => rawTerms(l, l.raw.persistStarts)),
    leading: langs.flatMap((l) => [...rawTerms(l, l.dirFillers), ...rawTerms(l, l.raw.politePrefixes)]),
    linkers: langs.flatMap((l) => rawTerms(l, l.raw.linkers)),
    separators: new Set(MEMORY_INTENT_SEPARATORS),
    codeTokens: new Set(MEMORY_INTENT_CODE_TOKEN_CHARS),
    patterns: MEMORY_INTENT_SECRET_PATTERNS.map((p) => ({ regex: new RegExp(p.regex, 'g'), luhn: p.luhn })),
  };
  return preparedCache;
}

function termsOf(lang: MemoryLanguage, key: TermKey): readonly PreparedTerm[] {
  return lang.terms.get(key) ?? [];
}

function has(f: SentenceForms, key: TermKey): boolean {
  return prepared().langs.some((l) => anyMatch(l.mode, f, termsOf(l, key)));
}

function dirHas(f: SentenceForms, key: 'verbs' | 'vetoes'): boolean {
  return prepared().langs.some((l) => anyMatch(l.mode, f, l.dir[key]));
}

function dirHasAnyGlobal(f: SentenceForms): boolean {
  return preparedLexicon().some((l) => anyMatch(l.mode, f, l.globalMarkers));
}

function head(f: SentenceForms, key: TermKey): boolean {
  return prepared().langs.some((l) =>
    passesStarts({ mode: l.mode, fillers: l.dir.fillers, starts: termsOf(l, key) }, f),
  );
}

function hasExcept(text: string, key: TermKey, exKey: TermKey): boolean {
  return prepared().langs.some((l) => {
    if (l.mode === 'substring') {
      let s = norm(text);
      for (const e of termsOf(l, exKey)) {
        if (e.substring.length > 0) s = s.split(e.substring).join(' ');
      }
      return termsOf(l, key).some((t) => s.includes(t.substring));
    }
    let s = ` ${wordCore(text)} `;
    for (const e of termsOf(l, exKey)) {
      const pe = ` ${e.word} `;
      while (s.includes(pe)) s = s.replace(pe, () => ' ');
    }
    return termsOf(l, key).some((t) => s.includes(` ${t.word} `));
  });
}

const isAsciiGraphic = (cp: string): boolean => cp >= '!' && cp <= '~';
const isAsciiLower = (cp: string | undefined): boolean => cp !== undefined && cp >= 'a' && cp <= 'z';
const isAsciiUpper = (cp: string | undefined): boolean => cp !== undefined && cp >= 'A' && cp <= 'Z';
const isAsciiDigit = (cp: string | undefined): boolean => cp !== undefined && cp >= '0' && cp <= '9';
const isAsciiLetter = (cp: string | undefined): boolean => isAsciiLower(cp) || isAsciiUpper(cp);

function isCodeRun(run: readonly string[]): boolean {
  const tokens = prepared().codeTokens;
  for (let k = 0; k < run.length; k++) {
    const cp = run[k]!;
    if (tokens.has(cp)) return true;
    if (isAsciiLower(cp) && isAsciiUpper(run[k + 1])) return true;
    if ((isAsciiLetter(cp) || isAsciiDigit(cp)) && run[k + 1] === '.' && isAsciiLetter(run[k + 2])) return true;
  }
  return false;
}

/** Blanks maximal printable-ASCII runs that look like code; length unchanged. */
function codeMask(m: readonly string[]): string[] {
  const out = [...m];
  let i = 0;
  while (i < m.length) {
    if (!isAsciiGraphic(m[i]!)) {
      i++;
      continue;
    }
    let j = i;
    while (j < m.length && isAsciiGraphic(m[j]!)) j++;
    if (isCodeRun(m.slice(i, j))) for (let k = i; k < j; k++) out[k] = ' ';
    i = j;
  }
  return out;
}

function isSeparator(cp: string): boolean {
  return isWhiteSpace(cp) || prepared().separators.has(cp);
}

function foldAscii(cp: string): string {
  return isAsciiUpper(cp) ? cp.toLowerCase() : cp;
}

/** Length of the longest term matching at i, 0 when none. */
function longestAt(folded: readonly string[], i: number, terms: readonly RawTerm[]): number {
  let best = 0;
  outer: for (const t of terms) {
    const n = t.cps.length;
    if (n <= best || i + n > folded.length) continue;
    for (let k = 0; k < n; k++) if (folded[i + k] !== t.cps[k]) continue outer;
    const next = folded[i + n];
    if (t.word && next !== undefined && WORD_CP.test(next)) continue;
    best = n;
  }
  return best;
}

function proposition(span: string): string {
  const p = prepared();
  const cps = [...span];
  const folded = cps.map(foldAscii);
  const skip = (from: number): number => {
    let i = from;
    while (i < cps.length && isSeparator(cps[i]!)) i++;
    return i;
  };
  let i = 0;
  for (;;) {
    i = skip(i);
    if (longestAt(folded, i, p.persistStarts) > 0) break;
    const len = longestAt(folded, i, p.leading);
    if (len === 0) return trimWhiteSpace(span);
    i += len;
  }
  i += longestAt(folded, i, p.persistStarts);
  for (;;) {
    i = skip(i);
    const len = longestAt(folded, i, p.linkers);
    if (len === 0) break;
    i += len;
  }
  return trimWhiteSpace(cps.slice(i).join(''));
}

function anaphorOnly(text: string): boolean {
  const cps = [...trimWhiteSpace(text)];
  while (cps.length > 0 && isSeparator(cps[cps.length - 1]!)) cps.pop();
  if (cps.length === 0) return true;
  const stripped = cps.join('');
  return prepared().langs.some((l) =>
    termsOf(l, 'anaphorOnly').some((t) =>
      l.mode === 'substring' ? norm(stripped) === t.substring : wordCore(text) === t.word,
    ),
  );
}

function kindOf(text: string): MemoryKind {
  const f = forms(text);
  if (detectDirective(text).isDirective || prepared().langs.some((l) => passesStarts(l.dir, f))) return 'instruction';
  for (const [kind, key] of KIND_STARTS) if (head(f, key)) return kind;
  return 'fact';
}

function luhn(digits: string): boolean {
  let sum = 0;
  let double = false;
  for (let k = digits.length - 1; k >= 0; k--) {
    let d = digits.charCodeAt(k) - 48;
    if (double) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    double = !double;
  }
  return digits.length > 0 && sum % 10 === 0;
}

function sensitive(scanned: string): MemoryIntentSensitive {
  const f = forms(scanned);
  if (has(f, 'secretTerms')) return 'secret';
  for (const p of prepared().patterns) {
    for (const m of scanned.matchAll(p.regex)) {
      if (!p.luhn || luhn(m[0].replace(/[^0-9]/g, ''))) return 'secret';
    }
  }
  return has(f, 'specialTerms') ? 'special' : 'none';
}

interface Decision {
  readonly intent: Exclude<MemoryIntent, 'none'>;
  readonly rule: MemoryIntentRule;
  readonly span: string;
  readonly proposition: string | null;
  readonly kind: MemoryKind | null;
  readonly scope: MemoryIntentScope | null;
}

const RANK: Record<Decision['intent'], number> = {
  delete_or_supersede: 80,
  explicit_persist: 70,
  implicit_persist: 60,
  uncertain: 50,
  recall: 40,
  transient: 30,
  ack_or_meta: 20,
};

function rank(d: Decision): number {
  return RANK[d.intent] + (d.intent === 'implicit_persist' && d.scope !== 'conversation' ? 5 : 0);
}

function decideSentence(span: string, m1: readonly string[], original: string): Decision | null {
  const masked1 = m1.join('');
  const masked2 = codeMask(m1).join('');
  const f2 = forms(masked2);
  const plain = (intent: Decision['intent'], rule: MemoryIntentRule): Decision => ({
    intent,
    rule,
    span,
    proposition: null,
    kind: null,
    scope: null,
  });
  const localScope = (): MemoryIntentScope => (has(f2, 'folderMarkers') ? 'folder' : 'conversation');
  const implicit = (rule: MemoryIntentRule, global: boolean): Decision => ({
    intent: 'implicit_persist',
    rule,
    span,
    proposition: span,
    kind: 'instruction',
    scope: global ? 'global' : localScope(),
  });

  if (has(forms(original), 'memoryWords') && !has(f2, 'memoryWords')) return plain('ack_or_meta', 'quoted');
  if (has(f2, 'memoryWords') && has(f2, 'metaTerms')) return plain('ack_or_meta', 'meta');
  if (isQuestion(trimWhiteSpace(masked1))) {
    if ((has(f2, 'memoryWords') && has(f2, 'recallAddressees')) || has(f2, 'recallTerms')) {
      return plain('recall', 'question');
    }
    return null;
  }
  if (has(f2, 'recallTerms')) return plain('recall', 'recall');
  if (hasExcept(masked2, 'deleteTerms', 'deleteExceptions')) return plain('delete_or_supersede', 'delete');
  if (has(f2, 'supersedeTerms')) return plain('delete_or_supersede', 'supersede');
  if (hasExcept(masked2, 'transientTerms', 'transientExceptions')) return plain('transient', 'transient');
  const detection = detectDirective(span);
  if (head(f2, 'reminderStarts')) {
    return detection.isDirective
      ? implicit('directive', detection.scope === 'global')
      : plain('transient', 'reminder');
  }
  if (head(f2, 'persistStarts') && !head(f2, 'ackTerms')) {
    const p = proposition(span);
    if (p.length > 0 && head(forms(p), 'reminisceStarts')) return plain('ack_or_meta', 'reminisce');
    if (anaphorOnly(p)) return plain('uncertain', 'anaphor');
    let scope: MemoryIntentScope = 'unspecified';
    if (dirHasAnyGlobal(f2)) scope = 'global';
    else if (has(f2, 'folderMarkers')) scope = 'folder';
    else if (has(f2, 'conversationMarkers')) scope = 'conversation';
    return { intent: 'explicit_persist', rule: 'persist', span, proposition: p, kind: kindOf(p), scope };
  }
  if (detection.isDirective) return implicit('directive', detection.scope === 'global');
  if (has(f2, 'implicitMarkers') && dirHas(f2, 'verbs') && !dirHas(f2, 'vetoes') && !has(f2, 'ackTerms')) {
    return implicit('loose_directive', dirHasAnyGlobal(f2));
  }
  if (has(f2, 'ackTerms')) return plain('ack_or_meta', 'ack');
  if (has(f2, 'uncertainMarkers') && has(f2, 'anaphorDirective')) return plain('uncertain', 'anaphor_directive');
  return null;
}

/** Classifies one user message into a closed write intent; never writes anything. */
export function classifyMemoryIntent(text: string): MemoryIntentClassification {
  const cps: string[] = [];
  for (const ch of text) {
    if (cps.length >= DIRECTIVE_MAX_SCAN_CODE_POINTS) break;
    cps.push(ch);
  }
  const masked = mask(cps);
  let best: Decision | null = null;
  for (const s of sentences(text)) {
    const d = decideSentence(s.span, masked.slice(s.start, s.end), cps.slice(s.start, s.end).join(''));
    if (d && (best === null || rank(d) > rank(best))) best = d;
  }
  const sens = sensitive(cps.join(''));
  const persists = best?.intent === 'explicit_persist' || best?.intent === 'implicit_persist';
  let blocked: MemoryIntentBlocked | null = null;
  if (persists && best) {
    if (best.scope === 'conversation') blocked = 'conversation_scope';
    else if (sens === 'secret') blocked = 'secret';
    else if (sens === 'special') blocked = 'special';
    else if ([...(best.proposition ?? '')].length > MEMORY_INTENT_CONTENT_MAX_CODE_POINTS) blocked = 'too_long';
  }
  let suggestion: MemoryIntentSuggestion = 'none';
  if (sens === 'secret') suggestion = 'none';
  else if (persists && blocked === null) suggestion = 'memory';
  else if (detectDirective(text).isDirective) suggestion = 'conversationInstruction';
  return {
    intent: best?.intent ?? 'none',
    rule: best?.rule ?? null,
    span: best?.span ?? null,
    proposition: persists ? best!.proposition : null,
    kind: persists ? best!.kind : null,
    scope: persists ? best!.scope : null,
    sensitive: sens,
    blocked,
    suggestion,
  };
}

/** norm(content) with White_Space runs collapsed to one U+0020, ends trimmed. */
export function memoryIntentCanonical(content: string): string {
  let out = '';
  let space = false;
  for (const ch of norm(content)) {
    if (isWhiteSpace(ch)) {
      space = true;
      continue;
    }
    if (space && out.length > 0) out += ' ';
    space = false;
    out += ch;
  }
  return out;
}

/** Lowercase SHA-256 hex of the UTF-8 canonical form. */
export function memoryIntentFingerprint(content: string): string {
  return ContextHash.sha256Hex(memoryIntentCanonical(content));
}

function candidateScope(scope: MemoryIntentScope, context: MemoryCandidateContext): MemoryScope {
  switch (scope) {
    case 'global':
      return { type: 'global', id: null };
    case 'folder':
      return context.folderId !== null
        ? { type: 'folder', id: context.folderId }
        : { type: 'conversation', id: context.conversationId };
    case 'unspecified':
      return context.folderId !== null ? { type: 'folder', id: context.folderId } : { type: 'global', id: null };
    case 'conversation':
      return { type: 'conversation', id: context.conversationId };
  }
}

function skip(reason: MemoryCandidateSkipReason): MemoryCandidateOutcome {
  return { action: 'skip', reason, candidate: null };
}

/** Derives a pending candidate from a classification; only ever pending, never an active item. */
export function makeMemoryCandidate(
  classification: MemoryIntentClassification,
  context: MemoryCandidateContext,
): MemoryCandidateOutcome {
  const { suggestion, proposition: content, kind, scope, intent } = classification;
  if (suggestion !== 'memory' || content === null || kind === null || scope === null) return skip('no_suggestion');
  if (context.autoSuggest === false && intent === 'implicit_persist') return skip('auto_suggest_off');
  const fingerprint = memoryIntentFingerprint(content);
  if (context.activeContents.some((a) => memoryIntentFingerprint(a) === fingerprint)) return skip('duplicate_active');
  const id = ContextHash.uuidV5(MEMORY_INTENT_UUID_NAMESPACE, `${context.messageId}\n${fingerprint}`);
  for (const r of context.records) {
    if (r.id === id) return skip('exists');
    if (r.fingerprint === fingerprint && r.status === 'pending') return skip('duplicate_pending');
    if (r.fingerprint === fingerprint && r.status === 'rejected' && context.nowMs < r.expiresAtMs) {
      return skip('rejected_recently');
    }
  }
  return {
    action: 'create',
    reason: null,
    candidate: {
      id,
      status: 'pending',
      proposedLayer: memoryLayerOfKind(kind),
      proposedKind: kind,
      content,
      scope: candidateScope(scope, context),
      source: {
        type: 'conversation',
        conversationId: context.conversationId,
        messageIds: [context.messageId],
        observedAtMs: context.nowMs,
      },
      sensitivity: 'normal',
      confidence: intent === 'explicit_persist' ? MEMORY_INTENT_CONFIDENCE_EXPLICIT : MEMORY_INTENT_CONFIDENCE_IMPLICIT,
      fingerprint,
      createdAtMs: context.nowMs,
      expiresAtMs: context.nowMs + MEMORY_INTENT_CANDIDATE_TTL_MS,
      resolvedAtMs: null,
    },
  };
}

function cleared(
  record: MemoryCandidateRecord,
  status: MemoryCandidateStatus,
  nowMs: number,
  expiresAtMs: number,
): MemoryCandidateRecord {
  return {
    id: record.id,
    status,
    proposedLayer: record.proposedLayer,
    proposedKind: record.proposedKind,
    content: '',
    scope: { type: record.scope.type, id: record.scope.id },
    source: { type: 'conversation', conversationId: null, messageIds: [], observedAtMs: null },
    sensitivity: record.sensitivity,
    confidence: record.confidence,
    fingerprint: record.fingerprint,
    createdAtMs: record.createdAtMs,
    expiresAtMs,
    resolvedAtMs: nowMs,
  };
}

/** Accepts a pending candidate: clears it and returns the draft for a new active Memory Item. */
export function acceptMemoryCandidate(
  record: MemoryCandidateRecord,
  edit: MemoryCandidateEdit | null | undefined,
  nowMs: number,
): MemoryCandidateAcceptResult {
  if (record.status !== 'pending') return { error: 'not_pending' };
  if (nowMs >= record.expiresAtMs) return { error: 'expired' };
  const content = edit?.content != null ? trimWhiteSpace(edit.content) : record.content;
  if (content.length === 0) return { error: 'empty' };
  if ([...content].length > MEMORY_INTENT_CONTENT_MAX_CODE_POINTS) return { error: 'too_long' };
  const scope = edit?.scope ?? record.scope;
  return {
    record: cleared(record, 'accepted', nowMs, record.expiresAtMs),
    item: {
      layer: memoryLayerOfKind(edit?.kind ?? record.proposedKind),
      kind: edit?.kind ?? record.proposedKind,
      status: 'active',
      content,
      scope: { type: scope.type, id: scope.id },
      source: {
        type: 'conversation',
        conversationId: record.source.conversationId,
        messageIds: [...record.source.messageIds],
        observedAtMs: record.source.observedAtMs,
      },
      sensitivity: record.sensitivity,
      confidence: content === record.content ? record.confidence : 1,
    },
  };
}

/** Rejects a pending candidate, keeping only its fingerprint for short-term de-duplication. */
export function rejectMemoryCandidate(record: MemoryCandidateRecord, nowMs: number): MemoryCandidateRejectResult {
  if (record.status !== 'pending') return { error: 'not_pending' };
  return { record: cleared(record, 'rejected', nowMs, nowMs + MEMORY_INTENT_CANDIDATE_TTL_MS) };
}

/** Expires, supersedes and purges candidates; a store keeps only pending and live rejected records. */
export function sweepMemoryCandidates(
  records: readonly MemoryCandidateRecord[],
  activeContents: readonly string[],
  nowMs: number,
): MemoryCandidateSweep {
  const active = new Set(activeContents.map(memoryIntentFingerprint));
  const out: MemoryCandidateSweep = { keptIds: [], expiredIds: [], supersededIds: [], purgedIds: [] };
  for (const r of records) {
    if (r.status === 'pending' && nowMs >= r.expiresAtMs) {
      out.expiredIds.push(r.id);
      out.purgedIds.push(r.id);
    } else if (r.status === 'pending' && active.has(r.fingerprint)) {
      out.supersededIds.push(r.id);
      out.purgedIds.push(r.id);
    } else if (r.status === 'pending' || (r.status === 'rejected' && nowMs < r.expiresAtMs)) {
      out.keptIds.push(r.id);
    } else {
      out.purgedIds.push(r.id);
    }
  }
  return out;
}
