import type { Note } from '@oriveo/shared';

export interface RelatedNoteResult {
  note: Note;
  score: number;
  matchedTerms: string[];
}

/** A recall match: it carries only an id and a score, the smallest shape that has to cross the worker boundary. */
export interface NoteRecallMatch {
  id: string;
  score: number;
  matchedTerms: string[];
}

/**
 * Bounded candidate projection used for recall. Only this shape may be structured-cloned across
 * the worker boundary or held in the index cache; a whole Note must never cross, since
 * bodySnapshot, sourcePrompt, userNote and provenance are unbounded.
 */
export interface NoteRecallCandidate {
  id: string;
  title: string;
  body: string;
  tags: string[];
  /** Cache freshness token; when it is missing (older data) every update renormalizes. */
  updatedAt?: string;
  /** Sort timestamp computed once during projection, so the comparator does not call Date.parse repeatedly. */
  updatedAtMs: number;
}

export interface NoteRecallOptions {
  limit?: number;
  minScore?: number;
}

/** The index has two budgets, a row count and a total character count, which together bound the CPU cost of a single find pass. */
export interface NoteRecallIndexLimits {
  maxNotes: number;
  maxTotalChars: number;
}

const DEFAULT_LIMIT = 2;
const DEFAULT_MIN_SCORE = 4;
const TAG_WEIGHT = 8;
const TITLE_WEIGHT = 4;
const BODY_WEIGHT = 2;
export const NOTE_RECALL_MAX_DRAFT_CHARACTERS = 4_096;
export const NOTE_RECALL_MAX_TERMS = 128;
export const NOTE_RECALL_MAX_TITLE_CHARACTERS = 512;
export const NOTE_RECALL_MAX_BODY_CHARACTERS = 32_768;
export const NOTE_RECALL_MAX_TAGS = 32;
export const NOTE_RECALL_MAX_TAG_CHARACTERS = 128;
export const NOTE_RECALL_MAX_CANDIDATES = 128;
/**
 * Library-wide index cap for the worker. There is no FTS on the web, so recall uses a bounded
 * projection of the whole library resident in the worker plus a single Aho-Corasick pass:
 * truncated by descending updatedAt, which covers almost every note library while keeping memory
 * and the CPU cost of one recall bounded.
 */
export const NOTE_RECALL_WORKER_MAX_INDEX_NOTES = 1_024;
export const NOTE_RECALL_WORKER_MAX_INDEX_CHARS = 16_777_216;

const STOP_WORDS = new Set([
  'about',
  'after',
  'also',
  'and',
  'are',
  'can',
  'could',
  'does',
  'for',
  'from',
  'how',
  'into',
  'should',
  'that',
  'the',
  'this',
  'use',
  'what',
  'when',
  'where',
  'with',
  'would',
]);

function normalizeText(value: string): string {
  return value
    .toLowerCase()
    .normalize('NFKC')
    .replace(/[_-]+/g, ' ')
    .replace(/[^\p{L}\p{N}\s]+/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function tokenizeLatin(value: string): string[] {
  return normalizeText(value)
    .split(' ')
    .map((term) => term.trim())
    .filter((term) => term.length >= 3 && term.length <= 64 && !STOP_WORDS.has(term));
}

function extractCjkPhrases(value: string): string[] {
  const matches = value.match(/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]{2,}/gu) ?? [];
  const phrases = new Set<string>();
  for (const match of matches) {
    const normalized = normalizeText(match).replace(/\s+/g, '');
    if (normalized.length < 2) continue;
    phrases.add(normalized);
    if (normalized.length >= 4) {
      for (let i = 0; i <= normalized.length - 4; i += 1) {
        phrases.add(normalized.slice(i, i + 4));
      }
    }
    if (normalized.length >= 3) {
      for (let i = 0; i <= normalized.length - 3; i += 1) {
        phrases.add(normalized.slice(i, i + 3));
      }
    }
  }
  return Array.from(phrases);
}

function tokenize(value: string): string[] {
  return Array.from(new Set([...tokenizeLatin(value), ...extractCjkPhrases(value)]))
    .slice(0, NOTE_RECALL_MAX_TERMS);
}

function recallSample(value: string): string {
  if (value.length <= NOTE_RECALL_MAX_DRAFT_CHARACTERS) return value;
  const half = NOTE_RECALL_MAX_DRAFT_CHARACTERS / 2;
  return `${value.slice(0, half)}\n${value.slice(-half)}`;
}

interface PreparedNote {
  id: string;
  updatedAtMs: number;
  title: string;
  body: string;
  tags: string[];
}

interface MatcherNode {
  transitions: Map<string, number>;
  failure: number;
  outputs: number[];
}

class LiteralMultiPatternMatcher {
  private readonly nodes: MatcherNode[] = [{ transitions: new Map(), failure: 0, outputs: [] }];

  constructor(private readonly patterns: string[]) {
    patterns.forEach((pattern, patternIndex) => {
      let state = 0;
      for (const character of pattern) {
        const existing = this.nodes[state].transitions.get(character);
        if (existing !== undefined) {
          state = existing;
          continue;
        }
        const next = this.nodes.length;
        this.nodes.push({ transitions: new Map(), failure: 0, outputs: [] });
        this.nodes[state].transitions.set(character, next);
        state = next;
      }
      this.nodes[state].outputs.push(patternIndex);
    });

    const queue = Array.from(this.nodes[0].transitions.values());
    for (let cursor = 0; cursor < queue.length; cursor += 1) {
      const state = queue[cursor];
      for (const [character, next] of this.nodes[state].transitions) {
        queue.push(next);
        let fallback = this.nodes[state].failure;
        while (fallback !== 0 && !this.nodes[fallback].transitions.has(character)) {
          fallback = this.nodes[fallback].failure;
        }
        const target = this.nodes[fallback].transitions.get(character);
        if (target !== undefined && target !== next) this.nodes[next].failure = target;
        this.nodes[next].outputs.push(...this.nodes[this.nodes[next].failure].outputs);
      }
    }
  }

  matches(text: string): Set<number> {
    const matches = new Set<number>();
    let state = 0;
    for (const character of text) {
      while (state !== 0 && !this.nodes[state].transitions.has(character)) {
        state = this.nodes[state].failure;
      }
      const next = this.nodes[state].transitions.get(character);
      if (next !== undefined) state = next;
      this.nodes[state].outputs.forEach((index) => matches.add(index));
      if (matches.size === this.patterns.length) break;
    }
    return matches;
  }
}

/** Note to bounded candidate projection. Truncation happens before anything crosses the boundary. */
export function toRecallCandidate(note: Note): NoteRecallCandidate {
  return {
    id: note.id,
    title: note.title.slice(0, NOTE_RECALL_MAX_TITLE_CHARACTERS),
    body: note.body.slice(0, NOTE_RECALL_MAX_BODY_CHARACTERS),
    tags: note.tags
      .slice(0, NOTE_RECALL_MAX_TAGS)
      .map((tag) => tag.slice(0, NOTE_RECALL_MAX_TAG_CHARACTERS)),
    updatedAt: note.updatedAt,
    updatedAtMs: Date.parse(note.updatedAt ?? note.createdAt) || 0,
  };
}

/** Whole library to recall candidates: exclude the trash, sort by updatedAt descending, project, and truncate to maxNotes. */
export function recallCandidates(notes: Note[], maxNotes: number): NoteRecallCandidate[] {
  return notes
    .filter((note) => !note.deletedAt)
    .map(toRecallCandidate)
    .sort((left, right) => right.updatedAtMs - left.updatedAtMs)
    .slice(0, maxNotes);
}

function prepareCandidate(candidate: NoteRecallCandidate): PreparedNote {
  return {
    id: candidate.id,
    updatedAtMs: candidate.updatedAtMs,
    title: normalizeText(candidate.title.slice(0, NOTE_RECALL_MAX_TITLE_CHARACTERS)),
    body: normalizeText(candidate.body.slice(0, NOTE_RECALL_MAX_BODY_CHARACTERS)),
    tags: candidate.tags
      .slice(0, NOTE_RECALL_MAX_TAGS)
      .map((tag) => normalizeText(tag.slice(0, NOTE_RECALL_MAX_TAG_CHARACTERS)))
      .filter(Boolean),
  };
}

interface ScoredMatch extends NoteRecallMatch {
  updatedAtMs: number;
}

function scoreNote(
  draftTerms: string[],
  matcher: LiteralMultiPatternMatcher,
  prepared: PreparedNote,
): ScoredMatch | null {
  const titleMatches = matcher.matches(prepared.title);
  const bodyMatches = matcher.matches(prepared.body);
  const tagMatches = new Set<number>();
  for (const tag of prepared.tags) {
    matcher.matches(tag).forEach((index) => tagMatches.add(index));
    draftTerms.forEach((term, index) => {
      if (term.includes(tag)) tagMatches.add(index);
    });
  }

  const matchedIndexes = new Set([...tagMatches, ...titleMatches, ...bodyMatches]);
  const score = tagMatches.size * TAG_WEIGHT
    + titleMatches.size * TITLE_WEIGHT
    + bodyMatches.size * BODY_WEIGHT;

  return score > 0
    ? {
      id: prepared.id,
      score,
      matchedTerms: [...matchedIndexes].map((index) => draftTerms[index]),
      updatedAtMs: prepared.updatedAtMs,
    }
    : null;
}

export class NoteRecallIndex {
  private preparedByID = new Map<string, { updatedAt?: string; prepared: PreparedNote }>();
  private readonly limits: NoteRecallIndexLimits;

  constructor(limits: NoteRecallIndexLimits = {
    maxNotes: NOTE_RECALL_MAX_CANDIDATES,
    maxTotalChars: NOTE_RECALL_MAX_CANDIDATES * NOTE_RECALL_MAX_BODY_CHARACTERS,
  }) {
    this.limits = limits;
  }

  /** candidates arrive in priority order, newest first; both the row and character budgets truncate, and everything past the limit is dropped. */
  update(candidates: NoteRecallCandidate[]): void {
    const accepted: NoteRecallCandidate[] = [];
    let totalChars = 0;
    for (const candidate of candidates) {
      if (accepted.length >= this.limits.maxNotes) break;
      const chars = candidate.title.length
        + candidate.body.length
        + candidate.tags.reduce((sum, tag) => sum + tag.length, 0);
      if (accepted.length > 0 && totalChars + chars > this.limits.maxTotalChars) break;
      totalChars += chars;
      accepted.push(candidate);
    }

    const activeIDs = new Set(accepted.map((candidate) => candidate.id));
    for (const id of this.preparedByID.keys()) {
      if (!activeIDs.has(id)) this.preparedByID.delete(id);
    }
    for (const candidate of accepted) {
      const cached = this.preparedByID.get(candidate.id);
      if (cached && candidate.updatedAt !== undefined && cached.updatedAt === candidate.updatedAt) continue;
      this.preparedByID.set(candidate.id, {
        updatedAt: candidate.updatedAt,
        prepared: prepareCandidate(candidate),
      });
    }
  }

  find(draftText: string, options: NoteRecallOptions = {}): NoteRecallMatch[] {
    const draftTerms = tokenize(recallSample(draftText)).sort();
    if (draftTerms.length === 0) return [];
    const matcher = new LiteralMultiPatternMatcher(draftTerms);
    const limit = options.limit ?? DEFAULT_LIMIT;
    const minScore = options.minScore ?? DEFAULT_MIN_SCORE;

    return [...this.preparedByID.values()]
      .map(({ prepared }) => scoreNote(draftTerms, matcher, prepared))
      .filter((result): result is ScoredMatch => result !== null && result.score >= minScore)
      .sort((left, right) => {
        const scoreDiff = right.score - left.score;
        if (scoreDiff !== 0) return scoreDiff;
        return right.updatedAtMs - left.updatedAtMs;
      })
      .slice(0, limit)
      .map(({ id, score, matchedTerms }) => ({ id, score, matchedTerms }));
  }
}

export function findRelatedNotes(
  draftText: string,
  notes: Note[],
  options: NoteRecallOptions = {},
): RelatedNoteResult[] {
  const index = new NoteRecallIndex();
  index.update(recallCandidates(notes, NOTE_RECALL_MAX_CANDIDATES));
  const notesByID = new Map(notes.map((note) => [note.id, note]));
  return index.find(draftText, options).flatMap((match) => {
    const note = notesByID.get(match.id);
    return note ? [{ note, score: match.score, matchedTerms: match.matchedTerms }] : [];
  });
}
