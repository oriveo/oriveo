import { validateAdditionalBody } from '@oriveo/core/providers/request-builders/additional-body';
import {
  resolveEffectiveAdditionalBody,
  saveAdditionalBody,
  type AdditionalBodyRecord,
  type AdditionalBodyScope,
} from './additional-body-settings';

/**
 * The "thinking" switch for custom / local connections: it lives in the additional request body as
 * `chat_template_kwargs.enable_thinking`.
 *
 * It has no storage of its own: it is just one field of the additional body, so what the user sees
 * in the editor must always match the switch. A rewrite changes only this one value; the user's
 * other fields, their order and their formatting are preserved byte for byte.
 */

const KWARGS = 'chat_template_kwargs';
const ENABLE = 'enable_thinking';

export type ChatTemplateThinkingState = 'off' | 'on' | 'blocked' | 'notSending';

type BodyRecord = Pick<AdditionalBodyRecord, 'raw' | 'enabled'>;

/**
 * Only the OpenAI Chat Completions transport has chat template parameters; an undecided transport does not count.
 * Both spellings are accepted: Relay stores `openai_chat_completions`, while `capabilityRuntimeIdentity` normalizes to `openai_chat`.
 */
export function chatTemplateThinkingApplies(transport: string | undefined): boolean {
  return transport === 'openai_chat_completions' || transport === 'openai_chat';
}

export function chatTemplateThinkingState(record: BodyRecord | null): ChatTemplateThinkingState {
  if (!record || !record.raw.trim()) return 'off';
  const validation = validateAdditionalBody(record.raw);
  if (!validation.accepted || !validation.value) return 'blocked';
  const root = validation.value;
  const kwargs = root[KWARGS];
  if (kwargs !== undefined && !isPlainObject(kwargs)) return 'blocked';
  if (!record.enabled) {
    const hasOtherFields = Object.keys(root).some((key) => key !== KWARGS)
      || (kwargs !== undefined && Object.keys(kwargs).some((key) => key !== ENABLE));
    return hasOtherFields ? 'notSending' : 'off';
  }
  return kwargs !== undefined && kwargs[ENABLE] === true ? 'on' : 'off';
}

/**
 * Changes only the `enable_thinking` value; off writes false and does not delete the key.
 * After an in-place rewrite the result must deep-equal "only this one value changed" when
 * re-parsed, otherwise the whole body is re-laid out (two-space indentation, sorted keys).
 * If the original is not a JSON object, or kwargs is not an object, it is returned unchanged;
 * callers should not write in those cases anyway (see `applyChatTemplateThinking`).
 */
export function setChatTemplateThinking(isOn: boolean, raw: string): string {
  if (!raw.trim()) return JSON.stringify({ [KWARGS]: { [ENABLE]: isOn } }, null, 2);
  let parsed: unknown;
  try { parsed = JSON.parse(raw); } catch { return raw; }
  if (!isPlainObject(parsed)) return raw;
  const kwargs = parsed[KWARGS];
  if (kwargs !== undefined && !isPlainObject(kwargs)) return raw;
  const expected = { ...parsed, [KWARGS]: { ...(kwargs ?? {}), [ENABLE]: isOn } };
  try {
    const rewritten = rewriteInPlace(raw, isOn);
    if (canonicalJSON(JSON.parse(rewritten)) === canonicalJSON(expected)) return rewritten;
  } catch {
    // Fall through to the full re-layout.
  }
  return JSON.stringify(sortKeys(expected), null, 2);
}

/** Returns null for blocked / notSending, and the caller must not write; otherwise rewrites the content and turns "send with request" on. */
export function applyChatTemplateThinking(isOn: boolean, record: BodyRecord | null): { raw: string; enabled: boolean } | null {
  const state = chatTemplateThinkingState(record);
  if (state === 'blocked' || state === 'notSending') return null;
  return { raw: setChatTemplateThinking(isOn, record?.raw ?? ''), enabled: true };
}

/** Builds on the record in effect right now and writes to the layer of the scope (the conversation layer if there is a conversation, otherwise the model default). Returns whether anything was written. */
export function writeChatTemplateThinking(isOn: boolean, scope: AdditionalBodyScope): boolean {
  const next = applyChatTemplateThinking(isOn, resolveEffectiveAdditionalBody(scope));
  if (!next) return false;
  saveAdditionalBody(scope, next);
  return true;
}

// MARK: - In-place rewriting

type Member = { key: string; leadStart: number; keyStart: number; keyEnd: number; valueStart: number; valueEnd: number };
type ScannedObject = { open: number; close: number; members: Member[] };

function rewriteInPlace(raw: string, isOn: boolean): string {
  const value = String(isOn);
  const root = scanObject(raw, skipWhitespace(raw, 0));
  const kwargsMember = lastMember(root, KWARGS);
  if (!kwargsMember) return appendMember(raw, root, KWARGS, (lead, colon) => nestedObject(lead, colon, value));
  const kwargs = scanObject(raw, kwargsMember.valueStart);
  const enable = lastMember(kwargs, ENABLE);
  if (enable) return raw.slice(0, enable.valueStart) + value + raw.slice(enable.valueEnd);
  return appendMember(raw, kwargs, ENABLE, () => value);
}

/** Appends at the end of the object: leading whitespace and colon style are taken from the last member; an empty object uses the compact style. */
function appendMember(raw: string, object: ScannedObject, key: string, render: (lead: string, colon: string) => string): string {
  const last = object.members[object.members.length - 1];
  if (!last) {
    const member = `${JSON.stringify(key)}: ${render('', ': ')}`;
    return raw.slice(0, object.open + 1) + member + raw.slice(object.close);
  }
  const lead = raw.slice(last.leadStart, last.keyStart);
  const colon = raw.slice(last.keyEnd, last.valueStart);
  const member = `,${lead}${JSON.stringify(key)}${colon}${render(lead, colon)}`;
  return raw.slice(0, last.valueEnd) + member + raw.slice(last.valueEnd);
}

/** A newly created kwargs object follows the outer layout: one extra indent level when multi-line (the indent unit is the outer line's leading whitespace), or the outer leading whitespace when single-line. */
function nestedObject(lead: string, colon: string, value: string): string {
  const newline = lead.lastIndexOf('\n');
  const inner = newline >= 0 ? lead + lead.slice(newline + 1) : lead;
  return `{${inner}${JSON.stringify(ENABLE)}${colon}${value}${lead}}`;
}

function lastMember(object: ScannedObject, key: string): Member | undefined {
  // JSON.parse keeps the last duplicate key, so the rewrite may only touch the last one too.
  return [...object.members].reverse().find((member) => member.key === key);
}

function scanObject(raw: string, open: number): ScannedObject {
  if (raw[open] !== '{') throw new Error('expected object');
  const members: Member[] = [];
  let leadStart = open + 1;
  let index = skipWhitespace(raw, leadStart);
  if (raw[index] === '}') return { open, close: index, members };
  for (;;) {
    const keyStart = index;
    const keyEnd = scanString(raw, keyStart);
    const key = JSON.parse(raw.slice(keyStart, keyEnd)) as string;
    index = skipWhitespace(raw, keyEnd);
    if (raw[index] !== ':') throw new Error('expected colon');
    const valueStart = skipWhitespace(raw, index + 1);
    const valueEnd = scanValue(raw, valueStart);
    members.push({ key, leadStart, keyStart, keyEnd, valueStart, valueEnd });
    index = skipWhitespace(raw, valueEnd);
    if (raw[index] === '}') return { open, close: index, members };
    if (raw[index] !== ',') throw new Error('expected comma');
    leadStart = index + 1;
    index = skipWhitespace(raw, leadStart);
  }
}

function skipWhitespace(raw: string, index: number): number {
  while (index < raw.length && (raw[index] === ' ' || raw[index] === '\n' || raw[index] === '\r' || raw[index] === '\t')) index++;
  return index;
}

function scanString(raw: string, start: number): number {
  if (raw[start] !== '"') throw new Error('expected string');
  let index = start + 1;
  while (index < raw.length) {
    if (raw[index] === '\\') index += 2;
    else if (raw[index] === '"') return index + 1;
    else index++;
  }
  throw new Error('unterminated string');
}

function scanValue(raw: string, start: number): number {
  const first = raw[start];
  if (first === '"') return scanString(raw, start);
  if (first === '{' || first === '[') {
    let depth = 0;
    let index = start;
    while (index < raw.length) {
      const char = raw[index];
      if (char === '"') { index = scanString(raw, index); continue; }
      if (char === '{' || char === '[') depth++;
      else if (char === '}' || char === ']') {
        depth--;
        if (depth === 0) return index + 1;
      }
      index++;
    }
    throw new Error('unterminated container');
  }
  let index = start;
  while (index < raw.length && !',}] \n\r\t'.includes(raw[index])) index++;
  return index;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (!isPlainObject(value)) return value;
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortKeys(value[key])]));
}

function canonicalJSON(value: unknown): string {
  return JSON.stringify(sortKeys(value));
}
