/**
 * Shared contract for the additional request body: additionalBodyRules + additionalBodyCases.
 * Cases are read one by one from the shared file instead of duplicating expectations here.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { additionalBodyRejectionCode, mergeAdditionalBody } from '../additional-body';

interface AdditionalBodyCase {
  caseId: string;
  raw: string;
  body: Record<string, unknown>;
  expect: { accepted: boolean; body: Record<string, unknown>; reason?: string; field?: string };
}

const cases = loadJSON<{ additionalBodyCases: AdditionalBodyCase[] }>('generation_parameter_contract.v1.cases.json').additionalBodyCases;

describe('additionalBodyCases (shared cases, one by one)', () => {
  it('runs all 21 cases with none skipped', () => {
    expect(cases).toHaveLength(21);
  });

  for (const testCase of cases) {
    it(testCase.caseId, () => {
      const input = structuredClone(testCase.body);
      const result = mergeAdditionalBody(input, testCase.raw);
      expect(result.accepted).toBe(testCase.expect.accepted);
      expect(result.body).toEqual(testCase.expect.body);
      // The input body is never rewritten in place: on rejection it is left untouched for the caller
      expect(input).toEqual(testCase.body);
      if (!result.accepted) {
        expect(result.rejection.reason).toBe(testCase.expect.reason);
        expect(result.rejection.field).toBe(testCase.expect.field);
        // Only syntax errors report a line number; other reasons never invent one
        if (result.rejection.reason === 'invalid_json') expect(result.rejection.line).toBe(1);
        else expect(result.rejection.line).toBeUndefined();
      }
    });
  }
});

describe('additional body decision details', () => {
  const base = { model: 'm', messages: [] as unknown[] };

  it('treats blank content as not enabled and returns the body unchanged', () => {
    expect(mergeAdditionalBody(base, '  \n\t')).toEqual({ accepted: true, body: base });
  });

  it('reports the line of a syntax error, taken from where parsing stopped', () => {
    const result = mergeAdditionalBody(base, '{\n  "a": 1,\n  "b": \n}');
    expect(result.accepted).toBe(false);
    if (result.accepted) return;
    expect(result.rejection).toEqual({ reason: 'invalid_json', line: 4 });
    expect(additionalBodyRejectionCode(result.rejection)).toBe('additional_body_rejected:invalid_json@4');
  });

  it('checks size before syntax: truncated JSON over 64 KiB reports too_large', () => {
    const raw = `{"a": "${'x'.repeat(65_536)}`;
    const result = mergeAdditionalBody(base, raw);
    expect(!result.accepted && result.rejection).toEqual({ reason: 'too_large' });
  });

  it('counts 64 KiB in UTF-8 bytes', () => {
    const raw = `{"a": "${'\u4e2d'.repeat(22_000)}"}`;
    expect(raw.length).toBeLessThan(65_536);
    const result = mergeAdditionalBody(base, raw);
    expect(!result.accepted && result.rejection.reason).toBe('too_large');
  });

  it('depth: the root object counts as 1, arrays count as a level, 32 levels pass and 33 are rejected', () => {
    const nest = (depth: number) => {
      let raw = '1';
      for (let level = 1; level < depth; level += 1) raw = level % 2 ? `[${raw}]` : `{"k":${raw}}`;
      return `{"k":${raw}}`;
    };
    expect(mergeAdditionalBody(base, nest(32)).accepted).toBe(true);
    const deep = mergeAdditionalBody(base, nest(33));
    expect(!deep.accepted && deep.rejection).toEqual({ reason: 'too_deep' });
  });

  it('checks depth before blocked segment names and protected fields', () => {
    let raw = '{"__proto__":1}';
    for (let level = 0; level < 32; level += 1) raw = `{"model":${raw}}`;
    const result = mergeAdditionalBody(base, raw);
    expect(!result.accepted && result.rejection.reason).toBe('too_deep');
  });

  it('checks blocked segment names before protected fields, including objects inside arrays', () => {
    const result = mergeAdditionalBody(base, '{"model":"x","a":[{"constructor":1}]}');
    expect(!result.accepted && result.rejection).toEqual({ reason: 'blocked_segment', field: 'constructor' });
    expect(!result.accepted && additionalBodyRejectionCode(result.rejection))
      .toBe('additional_body_rejected:blocked_segment:constructor');
  });

  it('reports the protected field that sorts first by code point when several are present', () => {
    const result = mergeAdditionalBody(base, '{"tools":1,"stream":true,"messages":[]}');
    expect(!result.accepted && result.rejection).toEqual({ reason: 'protected_field', field: 'messages' });
  });

  it('does not reject same-named keys in nested levels', () => {
    const result = mergeAdditionalBody(base, '{"metadata":{"system":"x","model":"y"}}');
    expect(result).toEqual({ accepted: true, body: { ...base, metadata: { system: 'x', model: 'y' } } });
  });

  it('handles duplicate keys the way the parser resolves them (last wins) without rejecting', () => {
    const result = mergeAdditionalBody(base, '{"top_k":1,"top_k":2}');
    expect(result).toEqual({ accepted: true, body: { ...base, top_k: 2 } });
  });

  it('replaces the whole value when an object in the additional body shares a name with a scalar in the request body', () => {
    const result = mergeAdditionalBody({ ...base, reasoning: 'low' }, '{"reasoning":{"effort":"high"}}');
    expect(result.accepted && result.body.reasoning).toEqual({ effort: 'high' });
  });

  it('does not share references between the merged result and the additional body', () => {
    const result = mergeAdditionalBody(base, '{"extra":{"a":[1]}}');
    expect(result.accepted).toBe(true);
    if (!result.accepted) return;
    (result.body.extra as { a: number[] }).a.push(2);
    expect(mergeAdditionalBody(base, '{"extra":{"a":[1]}}').body.extra).toEqual({ a: [1] });
  });

  it('uses the same list for protected fields and wireHardening.builderOwnedRootFields', () => {
    const rules = loadJSON<{
      additionalBodyRules: { protectedRootFields: string[] };
      wireHardening: { builderOwnedRootFields: string[] };
    }>('generation_parameter_contract.v1.json');
    for (const field of rules.wireHardening.builderOwnedRootFields) {
      const result = mergeAdditionalBody(base, JSON.stringify({ [field]: 1 }));
      expect(!result.accepted && result.rejection, field).toEqual({ reason: 'protected_field', field });
    }
    expect(rules.additionalBodyRules.protectedRootFields).toEqual(rules.wireHardening.builderOwnedRootFields);
  });
});

function loadJSON<T>(fileName: string): T {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', fileName);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${fileName} not found`);
    current = parent;
  }
}
