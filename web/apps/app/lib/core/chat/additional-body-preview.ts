/**
 * The "when sending" list and the "tidy" action of the additional request body editor.
 *
 * Only the merger decides: whether the body is accepted as a whole is up to `validateAdditionalBody`,
 * and protected fields come from the same `BUILDER_OWNED_ROOT_FIELDS` table. This module only adds the
 * two things the merger does not need: each leaf path and its line number in the original text.
 */
import {
  validateAdditionalBody,
  type AdditionalBodyRejection,
} from '@oriveo/core/providers/request-builders/additional-body';
import { BUILDER_OWNED_ROOT_FIELDS } from '@oriveo/core/providers/request-builders/generation-parameters';

export type AdditionalBodyProtectedReason =
  | 'conversation' | 'attachments' | 'systemPrompt' | 'tools' | 'model' | 'streaming' | 'other';

export type AdditionalBodyPreviewRow = {
  /** For display: segment names joined with ".". */
  path: string;
  segments: string[];
  /** The line this key is on in the original text (1-based). */
  line: number;
} & (
  | { status: 'included' }
  | { status: 'protected'; protectedReason: AdditionalBodyProtectedReason }
  | { status: 'invalidName' }
);

export interface AdditionalBodyPreview {
  rows: AdditionalBodyPreviewRow[];
  /** The whole body is rejected (null = it will be merged into the request as is). For protected / blocked segment names the line of that field is added. */
  rejection: AdditionalBodyRejection | null;
}

export function additionalBodyPreview(raw: string): AdditionalBodyPreview {
  const validation = validateAdditionalBody(raw);
  if (validation.accepted && !validation.value) return { rows: [], rejection: null };
  if (!validation.accepted && validation.rejection.reason !== 'protected_field' && validation.rejection.reason !== 'blocked_segment') {
    return { rows: [], rejection: validation.rejection };
  }
  const tree = parseTree(raw);
  if (!tree || tree.kind !== 'object') {
    return { rows: [], rejection: validation.accepted ? null : validation.rejection };
  }
  const rows: AdditionalBodyPreviewRow[] = [];
  for (const [key, entry] of tree.entries) {
    if (BUILDER_OWNED_ROOT_FIELDS.has(key)) {
      rows.push({ path: key, segments: [key], line: entry.line, status: 'protected', protectedReason: PROTECTED_REASONS[key] ?? 'other' });
      continue;
    }
    collectLeaves(key, entry, [], rows);
  }
  if (validation.accepted) return { rows, rejection: null };
  const { field } = validation.rejection;
  const status = validation.rejection.reason === 'protected_field' ? 'protected' : 'invalidName';
  const culprit = rows.find((row) => row.status === status && row.segments[row.segments.length - 1] === field)
    ?? rows.find((row) => row.status === status);
  return { rows, rejection: { ...validation.rejection, ...(culprit ? { line: culprit.line } : {}) } };
}

/** A valid JSON object -> re-laid out with two-space indentation (key order and number text unchanged); otherwise null. */
export function tidyAdditionalBody(raw: string): string | null {
  const tree = parseTree(raw);
  if (!tree || tree.kind !== 'object') return null;
  return serialize(tree, '');
}

/** The category only attaches a reason to "cannot be changed"; membership is still decided by `BUILDER_OWNED_ROOT_FIELDS` alone, and anything not in the table falls into other. */
const PROTECTED_REASONS: Readonly<Record<string, AdditionalBodyProtectedReason>> = {
  messages: 'conversation', input: 'conversation', contents: 'conversation', prompt: 'conversation',
  attachments: 'attachments',
  instructions: 'systemPrompt', system: 'systemPrompt',
  tools: 'tools', tool_choice: 'tools', plugins: 'tools',
  model: 'model',
  stream: 'streaming', stream_options: 'streaming',
};

/** The same blocked segment names as the merger (see BLOCKED_SEGMENTS in additional-body.ts). */
const BLOCKED_SEGMENTS = new Set(['__proto__', 'prototype', 'constructor']);

type Node =
  | { kind: 'object'; entries: Map<string, Entry> }
  | { kind: 'array'; items: Node[] }
  | { kind: 'scalar'; text: string };
type Entry = { line: number; node: Node };

/** Objects are descended level by level; arrays, scalars and empty objects are leaves (the merger replaces them as a whole). */
function collectLeaves(key: string, entry: Entry, prefix: string[], rows: AdditionalBodyPreviewRow[]): void {
  const segments = [...prefix, key];
  const base = { path: segments.join('.'), segments, line: entry.line };
  if (BLOCKED_SEGMENTS.has(key)) {
    rows.push({ ...base, status: 'invalidName' });
    return;
  }
  const { node } = entry;
  if (node.kind === 'object' && node.entries.size > 0) {
    for (const [childKey, child] of node.entries) collectLeaves(childKey, child, segments, rows);
    return;
  }
  rows.push({ ...base, status: containsBlockedSegment(node) ? 'invalidName' : 'included' });
}

function containsBlockedSegment(node: Node): boolean {
  if (node.kind === 'array') return node.items.some(containsBlockedSegment);
  if (node.kind === 'object') {
    for (const [key, entry] of node.entries) {
      if (BLOCKED_SEGMENTS.has(key) || containsBlockedSegment(entry.node)) return true;
    }
  }
  return false;
}

function serialize(node: Node, indent: string): string {
  const inner = `${indent}  `;
  if (node.kind === 'scalar') return node.text;
  if (node.kind === 'array') {
    if (node.items.length === 0) return '[]';
    return `[\n${node.items.map((item) => inner + serialize(item, inner)).join(',\n')}\n${indent}]`;
  }
  if (node.entries.size === 0) return '{}';
  const lines = [...node.entries].map(([key, entry]) => `${inner}${JSON.stringify(key)}: ${serialize(entry.node, inner)}`);
  return `{\n${lines.join(',\n')}\n${indent}}`;
}

/**
 * A JSON parser that preserves key order, the line of each key and the original text of scalars. Its
 * result is used only once JSON.parse has accepted the input (the merger reports line numbers for
 * syntax errors). Duplicate keys follow JSON.parse semantics: the position comes from the first
 * occurrence, while the value and line come from the last.
 */
function parseTree(text: string): Node | null {
  try {
    JSON.parse(text);
  } catch {
    return null;
  }
  let i = 0;
  let line = 1;
  const skipWhitespace = () => {
    while (i < text.length && (text[i] === ' ' || text[i] === '\t' || text[i] === '\n' || text[i] === '\r')) {
      if (text[i] === '\n') line += 1;
      i += 1;
    }
  };
  const readString = (): string => {
    const start = i;
    i += 1;
    while (text[i] !== '"') i += text[i] === '\\' ? 2 : 1;
    i += 1;
    return text.slice(start, i);
  };
  const readValue = (): Node => {
    skipWhitespace();
    const char = text[i];
    if (char === '{') {
      i += 1;
      const entries = new Map<string, Entry>();
      skipWhitespace();
      if (text[i] === '}') { i += 1; return { kind: 'object', entries }; }
      while (true) {
        skipWhitespace();
        const keyLine = line;
        const key = JSON.parse(readString()) as string;
        skipWhitespace();
        i += 1; // ':'
        const node = readValue();
        entries.set(key, { line: keyLine, node });
        skipWhitespace();
        if (text[i++] === '}') return { kind: 'object', entries };
      }
    }
    if (char === '[') {
      i += 1;
      const items: Node[] = [];
      skipWhitespace();
      if (text[i] === ']') { i += 1; return { kind: 'array', items }; }
      while (true) {
        items.push(readValue());
        skipWhitespace();
        if (text[i++] === ']') return { kind: 'array', items };
      }
    }
    if (char === '"') return { kind: 'scalar', text: readString() };
    const start = i;
    while (i < text.length && /[-+.0-9a-zA-Z]/.test(text[i]!)) i += 1;
    return { kind: 'scalar', text: text.slice(start, i) };
  };
  try {
    return readValue();
  } catch {
    // Extremely deep nesting overflows the stack: no list is produced
    return null;
  }
}
