/**
 * Error card for a malformed web search / thinking custom field: section name, line number, list of
 * allowed fields, and safe code.
 *
 * The input comes from real rejections of the production compiler (`compileSafeCustomFragment` plus
 * the same `rejectSafeCustomFragment` the outbound path uses), not from a reason the test builds
 * itself. Key names and values written by the user must never appear in the body text or the safe code.
 */
import { describe, expect, it } from 'vitest';
import {
  compileSafeCustomFragment,
  rejectSafeCustomFragment,
} from '@oriveo/core/providers/request-builders/safe-custom-fragment';
import en from '../../../../messages/en.json';
import {
  CUSTOM_FRAGMENT_ERROR_KIND,
  customFragmentFailurePatch,
  customFragmentRejectionCode,
  type CustomFragmentOwner,
} from '../custom-fragment-rejection';

function te(key: string, values?: Record<string, string | number>): string {
  let node: unknown = en.errors;
  for (const part of key.split('.')) node = (node as Record<string, unknown>)?.[part];
  if (typeof node !== 'string') throw new Error(`missing errors.${key}`);
  return node.replace(/\{(\w+)\}/g, (_, name: string) => String(values?.[name] ?? `{${name}}`));
}

/** Same as the dispatch / relay orchestration layers: compile the trimmed content, throw an error carrying the owner and line number, then produce the safe code in the route's format. */
function productionCode(owner: CustomFragmentOwner, raw: string): string {
  const result = compileSafeCustomFragment(raw.trim(), owner, {}, {});
  if (result.accepted) throw new Error('expected rejection');
  const error = rejectSafeCustomFragment(owner, raw, result);
  expect(error.message).toBe(`Safe custom fragment rejected: ${result.reason}`);
  return customFragmentRejectionCode({ owner: error.owner, reason: error.reason, line: error.line });
}

function card(code: string, allowed: readonly string[] = []) {
  const patch = customFragmentFailurePatch({ kind: CUSTOM_FRAGMENT_ERROR_KIND, detail: code }, te, () => allowed);
  if (!patch) throw new Error('expected patch');
  return patch;
}

describe('error card for a malformed custom field', () => {
  it('truncated JSON: section name plus the line where parsing stopped (leading blank lines count)', () => {
    const code = productionCode('web', '\n{\n  "secret_web_key": true,\n  "other_secret": \n}');
    expect(code).toBe('custom_request_fields_rejected:web:invalid_json@5');
    const patch = card(code);
    expect(patch.errorDetail).toBe(`In the Web Search fields, line 5: ${en.errors.customRequestFieldsRejected.reasonSyntax}`);
    expect(patch.errorTechnicalDetail).toBe(code);
    for (const text of [patch.errorDetail, code]) {
      expect(text).not.toContain('secret_web_key');
      expect(text).not.toContain('other_secret');
    }
  });

  it('duplicate key: the line number points at the second occurrence', () => {
    const code = productionCode('reasoning', '{\n  "dup_secret": 1,\n  "dup_secret": 2\n}');
    expect(code).toBe('custom_request_fields_rejected:reasoning:duplicate_json_key@3');
    const patch = card(code);
    expect(patch.errorDetail).toBe(`In the Thinking Mode fields, line 3: ${en.errors.customRequestFieldsRejected.reasonSyntax}`);
    expect(patch.errorDetail).not.toContain('dup_secret');
  });

  it('a field this section does not accept: lists the allowed fields, gives no line number, and the safe code does not contain the list', () => {
    const code = productionCode('web', '{"my_private_field": "private value"}');
    expect(code).toBe('custom_request_fields_rejected:web:unknown_owned_path');
    const patch = card(code, ['/enable_search', '/search_options/forced_search']);
    expect(patch.errorDetail).toBe(
      'In the Web Search fields: This field isn’t allowed. Fields this model accepts: /enable_search · /search_options/forced_search',
    );
    for (const text of [patch.errorDetail, patch.errorTechnicalDetail ?? '']) {
      expect(text).not.toContain('my_private_field');
      expect(text).not.toContain('private value');
    }
    expect(patch.errorTechnicalDetail).not.toContain('enable_search');
  });

  it('other reasons give no line number and invent nothing; without an allowed set the conflict sentence is used', () => {
    const tooLarge = productionCode('web', JSON.stringify({ a: 'x'.repeat(70 * 1024) }));
    expect(tooLarge).toBe('custom_request_fields_rejected:web:too_large');
    expect(card(tooLarge).errorDetail).toBe(`In the Web Search fields: ${en.errors.customRequestFieldsRejected.reasonLimit}`);
    expect(card(productionCode('reasoning', '{"x":1}')).errorDetail)
      .toBe(`In the Thinking Mode fields: ${en.errors.customRequestFieldsRejected.reasonNotAllowed}`);
  });

  it('a legacy response with only a bare reason: the body is graded as before and nothing goes into the technical detail', () => {
    const patch = card('unknown_owned_path', ['/enable_search']);
    expect(patch.errorDetail).toBe(en.errors.customRequestFieldsRejected.reasonNotAllowed);
    expect(patch.errorTechnicalDetail).toBeUndefined();
  });
});
