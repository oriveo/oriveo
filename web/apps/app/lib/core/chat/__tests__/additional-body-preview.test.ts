/**
 * The "at send time" list and the "tidy up" action: the list must match the real merge result of the production merger.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { mergeAdditionalBody } from '@oriveo/core/providers/request-builders/additional-body';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import type { RuntimeMetadataResponse } from '@oriveo/core/providers/request-builders/runtime';
import { additionalBodyPreview, tidyAdditionalBody } from '../additional-body-preview';

const metadata = async () => loadJSON<{ metadata: RuntimeMetadataResponse }>('request_shape_contract.v1.json').metadata;

async function productionBody(): Promise<Record<string, unknown>> {
  const request = await buildProviderRequest({
    providerKind: 'anthropic', apiKey: 'k', modelID: 'claude-sonnet-4-6', baseURL: 'https://contract.invalid/v1',
    messages: [{ role: 'user', content: 'hi' }],
  }, metadata);
  return request.body;
}

/** Leaf paths in the merge result that were written by the additional body (value differs from the original body or was absent). */
function writtenPaths(base: Record<string, unknown>, merged: Record<string, unknown>, prefix: string[] = []): string[] {
  const out: string[] = [];
  for (const [key, value] of Object.entries(merged)) {
    const segments = [...prefix, key];
    const before = base[key];
    if (isRecord(value) && Object.keys(value).length > 0) {
      out.push(...writtenPaths(isRecord(before) ? before : {}, value, segments));
    } else if (JSON.stringify(before) !== JSON.stringify(value)) {
      out.push(segments.join('.'));
    }
  }
  return out;
}

const SAMPLE = '{\n  "chat_template_kwargs": {\n    "enable_thinking": false\n  },\n  "cache_prompt": true,\n  "messages": []\n}';

describe('additionalBodyPreview', () => {
  it('valid content: the included leaf path set equals the path set the production merger really wrote into the request body', async () => {
    const base = await productionBody();
    const raw = '{\n "top_k": 3,\n "metadata": {"user_id": "u", "tags": ["a"]},\n "chat_template_kwargs": {"enable_thinking": false}\n}';
    const preview = additionalBodyPreview(raw);
    expect(preview.rejection).toBeNull();
    const merged = mergeAdditionalBody(base, raw);
    expect(merged.accepted).toBe(true);
    const included = preview.rows.filter((row) => row.status === 'included').map((row) => row.path);
    expect(new Set(included)).toEqual(new Set(writtenPaths(base, merged.body)));
    expect(included).toEqual(['top_k', 'metadata.user_id', 'metadata.tags', 'chat_template_kwargs.enable_thinking']);
  });

  it('protected fields: the list marks them as not changeable with a reason and line number; the merger really rejects them; after removal, included is exactly what gets merged', async () => {
    const base = await productionBody();
    const preview = additionalBodyPreview(SAMPLE);
    expect(preview.rows.map((row) => [row.path, row.line, row.status])).toEqual([
      ['chat_template_kwargs.enable_thinking', 3, 'included'],
      ['cache_prompt', 5, 'included'],
      ['messages', 6, 'protected'],
    ]);
    expect(preview.rows[2]).toMatchObject({ protectedReason: 'conversation' });
    expect(preview.rejection).toEqual({ reason: 'protected_field', field: 'messages', line: 6 });
    const merged = mergeAdditionalBody(base, SAMPLE);
    expect(merged.accepted).toBe(false);
    if (!merged.accepted) expect(merged.rejection.field).toBe('messages');

    const fixed = '{"chat_template_kwargs": {"enable_thinking": false}, "cache_prompt": true}';
    const fixedMerge = mergeAdditionalBody(base, fixed);
    expect(fixedMerge.accepted).toBe(true);
    const included = preview.rows.filter((row) => row.status === 'included').map((row) => row.path);
    expect(new Set(writtenPaths(base, fixedMerge.body))).toEqual(new Set(included));
  });

  it('the protected-field classification covers every entry in the merger table', () => {
    const cases: Array<[string, string]> = [
      ['model', 'model'], ['messages', 'conversation'], ['input', 'conversation'], ['contents', 'conversation'],
      ['prompt', 'conversation'], ['attachments', 'attachments'], ['instructions', 'systemPrompt'], ['system', 'systemPrompt'],
      ['stream', 'streaming'], ['stream_options', 'streaming'], ['tools', 'tools'], ['tool_choice', 'tools'], ['plugins', 'tools'],
    ];
    for (const [field, reason] of cases) {
      const preview = additionalBodyPreview(`{"${field}": 1}`);
      expect(preview.rows[0]).toMatchObject({ status: 'protected', protectedReason: reason });
      expect(mergeAdditionalBody({}, `{"${field}": 1}`).accepted).toBe(false);
    }
  });

  it('forbidden segment names: flagged as unusable field names, and the whole body is rejected with a line number', () => {
    const raw = '{\n "a": 1,\n "b": {\n  "__proto__": {"x": 1}\n }\n}';
    const preview = additionalBodyPreview(raw);
    expect(preview.rows.map((row) => [row.path, row.line, row.status])).toEqual([
      ['a', 2, 'included'],
      ['b.__proto__', 4, 'invalidName'],
    ]);
    expect(preview.rejection).toEqual({ reason: 'blocked_segment', field: '__proto__', line: 4 });
    expect(mergeAdditionalBody({}, raw).accepted).toBe(false);
  });

  it('syntax error: no list, and the line where parsing stopped is reported; blank input has no list and is not rejected', () => {
    expect(additionalBodyPreview('{\n "a": 1,\n "b": ,\n}')).toEqual({ rows: [], rejection: { reason: 'invalid_json', line: 3 } });
    expect(additionalBodyPreview('[1]')).toEqual({ rows: [], rejection: { reason: 'not_object' } });
    expect(additionalBodyPreview('  ')).toEqual({ rows: [], rejection: null });
  });

  it('a duplicate key takes the last value per JSON.parse semantics and is listed only once', () => {
    const preview = additionalBodyPreview('{\n"a": {"x": 1},\n"a": 2\n}');
    expect(preview.rows.map((row) => [row.path, row.line])).toEqual([['a', 3]]);
  });
});

describe('tidyAdditionalBody', () => {
  it('two-space indent, with key order and number literals unchanged (including integer-looking keys)', () => {
    expect(tidyAdditionalBody('{"b":1.0,"2":{"z":[1,{"y":true}],"a":null},"s":"x\\n"}')).toBe(
      '{\n  "b": 1.0,\n  "2": {\n    "z": [\n      1,\n      {\n        "y": true\n      }\n    ],\n    "a": null\n  },\n  "s": "x\\n"\n}',
    );
    expect(tidyAdditionalBody('{"a":{},"b":[]}')).toBe('{\n  "a": {},\n  "b": []\n}');
  });

  it('invalid or not an object -> null', () => {
    expect(tidyAdditionalBody('{"a":')).toBeNull();
    expect(tidyAdditionalBody('[1]')).toBeNull();
    expect(tidyAdditionalBody('')).toBeNull();
  });
});

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

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
