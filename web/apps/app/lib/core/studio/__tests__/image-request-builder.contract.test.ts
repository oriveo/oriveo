/**
 * Shared fixture request_shape_contract.v2.json imageRequests: the
 * vendor cases of the built routes plus every clientCase. Each case
 * shallow-merges profileOverride over its image_param_normalization.v1 profile,
 * must pass checkImageProfile and normalizeImageParams, merges the string-valued
 * wireOverride (own keys, "__proto__" included) over the normalized wire, then
 * runs through the Web
 * buildImageRequest; the built request is compared with expect.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { checkImageProfile } from '../image-profile';
import { normalizeImageParams, type ImageParamRequest } from '../image-param-normalization';
import {
  buildImageRequest,
  type ImageRequestAdvanced,
  type ImageRequestFile,
} from '../image-request-builder';
import { repoRoot } from '../../../../../../test-support/repo-root';

const ROOT = repoRoot();
const CONTRACTS = resolve(ROOT, 'shared/model-contracts');
const BUILDER_ROUTES = [
  'openai_images',
  'xai_images',
  'openrouter_images',
  'minimax_image_generation',
  'gemini_generate_content',
  'chat_modalities',
  'dashscope_multimodal',
];
const EXPECTED_CASE_COUNT = 113;
const FALLBACK_BASE_URL = 'https://api.example.com/v1';
const ASCII_EDGE_WHITESPACE = /^[ \t\n\x0B\f\r]+|[ \t\n\x0B\f\r]+$/g;

interface FixtureImage {
  slot: number;
  role: string;
  mime: string;
  data?: string;
}

interface RequestCase {
  caseId: string;
  intent: {
    route: string;
    operation: string;
    profileRef: string;
    modelId: string;
    prompt: string;
    params: ImageParamRequest;
    images: FixtureImage[];
    editTransport?: string;
    baseUrl?: string;
    apiKey?: string;
    advanced?: ImageRequestAdvanced;
  };
  profileOverride?: Record<string, unknown>;
  wireOverride?: Record<string, unknown>;
  expect: {
    error?: string;
    method?: string;
    baseUrlExample?: string;
    endpointPath?: string;
    url?: string;
    contentType?: string;
    auth?: string | null;
    queryExcludes?: string[];
    bodyIncludes?: Record<string, unknown>;
    bodyExcludes?: string[];
    multipartParts?: {
      fields: Record<string, unknown>;
      fieldOrder?: string[];
      files: { name: string; order: number; mime: string; filename?: string; data?: string }[];
      excludes?: string[];
    };
  };
}

function readJson<T>(name: string): T {
  return JSON.parse(readFileSync(resolve(CONTRACTS, name), 'utf8')) as T;
}

const shapes = readJson<{
  imageRequests: { cases: RequestCase[]; clientCases: RequestCase[] };
}>('request_shape_contract.v2.json');
const normalization = readJson<{
  defaultAspect: string;
  profiles: Record<string, Record<string, unknown>>;
}>('image_param_normalization.v1.json');

const selectedCases: RequestCase[] = [
  ...shapes.imageRequests.cases.filter((entry) => BUILDER_ROUTES.includes(entry.intent.route)),
  ...shapes.imageRequests.clientCases,
];

const ABSENT = Symbol('absent');
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const DATA_URI_PATTERN = /^(data:[^;]+;base64,)\*$/;

function readPath(root: unknown, path: string): unknown {
  let current: unknown = root;
  for (const segment of path.split('.')) {
    if (Array.isArray(current) && /^\d+$/.test(segment)) {
      const index = Number(segment);
      if (index >= current.length) return ABSENT;
      current = current[index];
    } else if (current !== null && typeof current === 'object' && !Array.isArray(current)) {
      if (!Object.prototype.hasOwnProperty.call(current, segment)) return ABSENT;
      current = (current as Record<string, unknown>)[segment];
    } else {
      return ABSENT;
    }
  }
  return current;
}

/** "*" means present and non-empty: null, "", [] and {} are all empty. */
function isEmptyValue(value: unknown): boolean {
  if (value === null || value === undefined || value === '') return true;
  if (Array.isArray(value)) return value.length === 0;
  if (typeof value === 'object') return Object.keys(value).length === 0;
  return false;
}

function expectMatch(actual: unknown, expected: unknown, label: string): void {
  expect(actual, `${label} present`).not.toBe(ABSENT);
  if (expected === '*') {
    expect(isEmptyValue(actual), `${label} non-empty`).toBe(false);
    return;
  }
  const pattern = typeof expected === 'string' ? DATA_URI_PATTERN.exec(expected) : null;
  if (pattern) {
    const prefix = pattern[1]!;
    expect(typeof actual, `${label} type`).toBe('string');
    const text = actual as string;
    expect(text.startsWith(prefix), `${label} prefix ${prefix}`).toBe(true);
    const payload = text.slice(prefix.length);
    expect(
      payload.length > 0 && payload.length % 4 === 0 && BASE64.test(payload),
      `${label} base64 payload`,
    ).toBe(true);
    return;
  }
  expect(actual, label).toStrictEqual(expected);
}

/** Merges wireOverride as own data properties; non-string values or an empty override are fixture errors. */
function mergeWire(
  caseId: string,
  wire: Readonly<Record<string, string | number>>,
  override: Record<string, unknown> | undefined,
): Record<string, string | number> {
  const merged: Record<string, string | number> = { ...wire };
  if (override === undefined) return merged;
  const keys = Object.keys(override);
  if (keys.length === 0) throw new Error(`${caseId}: wireOverride has no own keys`);
  for (const key of keys) {
    const value = override[key];
    if (typeof value !== 'string') throw new Error(`${caseId}: wireOverride.${key} is not a string`);
    Object.defineProperty(merged, key, { value, enumerable: true, writable: true, configurable: true });
  }
  return merged;
}

function fileText(file: ImageRequestFile): string {
  return new TextDecoder().decode(file.data);
}

let ranCases = 0;

describe('request_shape_contract.v2 imageRequests', () => {
  it.each(selectedCases.map((entry) => [entry.caseId, entry] as const))('IMAGE-REQUEST-%s', (caseId, entry) => {
    const base = normalization.profiles[entry.intent.profileRef];
    expect(base, `${caseId}.profileRef exists`).toBeDefined();
    const checked = checkImageProfile({ ...base, ...(entry.profileOverride ?? {}) });
    expect(checked.reason, `${caseId}.checkImageProfile reason`).toBeNull();
    const profile = checked.profile;
    if (!profile) throw new Error(`${caseId}: profile rejected`);
    expect(profile.route, `${caseId}.route`).toBe(entry.intent.route);
    if (entry.intent.editTransport !== undefined) {
      expect(profile.editTransport, `${caseId}.editTransport`).toBe(entry.intent.editTransport);
    }
    const normalized = normalizeImageParams(profile, entry.intent.params, normalization.defaultAspect);
    if ('error' in normalized) throw new Error(`${caseId}: normalization failed ${normalized.error}`);

    const encoder = new TextEncoder();
    const apiKey = entry.intent.apiKey ?? 'test-key';
    const baseUrlExample = entry.expect.baseUrlExample ?? '';
    const built = buildImageRequest(profile, {
      operation: entry.intent.operation,
      modelId: entry.intent.modelId,
      prompt: entry.intent.prompt,
      wire: mergeWire(caseId, normalized.wire, entry.wireOverride),
      images: entry.intent.images.map((image) => ({
        slot: image.slot,
        role: image.role,
        mime: image.mime,
        data: encoder.encode(image.data ?? `image-${image.slot}`),
      })),
      advanced: entry.intent.advanced ?? {},
      // Cases without a baseUrlExample (error cases) get a valid fallback so they test their own rule.
      baseUrl: entry.intent.baseUrl ?? entry.expect.baseUrlExample ?? FALLBACK_BASE_URL,
      apiKey,
    });
    ranCases += 1;

    if (entry.expect.error !== undefined) {
      expect(built, caseId).toStrictEqual({ error: entry.expect.error });
      return;
    }
    if ('error' in built) throw new Error(`${caseId}: unexpected error ${built.error}`);

    expect(built.method, `${caseId}.method`).toBe(entry.expect.method);
    const expectedUrl =
      entry.expect.url ?? `${baseUrlExample.replace(/\/+$/, '')}${entry.expect.endpointPath ?? ''}`;
    expect(built.url, `${caseId}.url`).toBe(expectedUrl);
    expect(built.headers['Content-Type'], `${caseId}.Content-Type`).toBe(entry.expect.contentType);
    const headerNames = Object.keys(built.headers);
    const trimmedKey = apiKey.replace(ASCII_EDGE_WHITESPACE, '');
    if (entry.expect.auth === null) {
      expect(headerNames, `${caseId}.no Authorization`).not.toContain('Authorization');
      expect(headerNames, `${caseId}.no x-goog-api-key`).not.toContain('x-goog-api-key');
    } else if (entry.expect.auth === 'Authorization: Bearer') {
      expect(built.headers.Authorization, `${caseId}.Authorization`).toBe(`Bearer ${trimmedKey}`);
      expect(headerNames, `${caseId}.no x-goog-api-key`).not.toContain('x-goog-api-key');
    } else if (entry.expect.auth === 'x-goog-api-key') {
      expect(built.headers['x-goog-api-key'], `${caseId}.x-goog-api-key`).toBe(trimmedKey);
      expect(headerNames, `${caseId}.no Authorization`).not.toContain('Authorization');
    } else if (entry.expect.auth !== undefined) {
      throw new Error(`${caseId}: unknown expect.auth ${String(entry.expect.auth)}`);
    }
    const query = new URL(built.url).searchParams;
    for (const key of entry.expect.queryExcludes ?? []) {
      expect(query.has(key), `${caseId}.query excludes ${key}`).toBe(false);
    }

    const multipart = entry.expect.multipartParts;
    if (multipart) {
      if (built.body.kind !== 'multipart') throw new Error(`${caseId}: expected a multipart body`);
      const fieldNames = built.body.fields.map(([name]) => name);
      expect(new Set(fieldNames).size, `${caseId}.unique field names ${fieldNames.join(',')}`).toBe(
        fieldNames.length,
      );
      if (multipart.fieldOrder !== undefined) {
        expect(fieldNames, `${caseId}.field order`).toStrictEqual(multipart.fieldOrder);
      }
      const fields = Object.fromEntries(built.body.fields);
      for (const [path, expected] of Object.entries(multipart.fields)) {
        expectMatch(readPath(fields, path), expected, `${caseId}.field ${path}`);
      }
      const files = built.body.files;
      expect(files.length, `${caseId}.file count`).toBe(multipart.files.length);
      multipart.files.forEach((expected, index) => {
        const file = files[index]!;
        expect(file.name, `${caseId}.file ${index} name`).toBe(expected.name);
        expect(file.mime, `${caseId}.file ${index} mime`).toBe(expected.mime);
        if (expected.filename !== undefined) {
          expect(file.filename, `${caseId}.file ${index} filename`).toBe(expected.filename);
        }
        if (expected.data !== undefined) {
          expect(fileText(file), `${caseId}.file ${index} data`).toBe(expected.data);
        }
      });
      const fileNames = files.map((file) => file.name);
      for (const name of multipart.excludes ?? []) {
        expect(fieldNames, `${caseId}.excluded field ${name}`).not.toContain(name);
        expect(fileNames, `${caseId}.excluded file ${name}`).not.toContain(name);
      }
      return;
    }

    if (built.body.kind !== 'json') throw new Error(`${caseId}: expected a JSON body`);
    const json = built.body.json;
    for (const [path, expected] of Object.entries(entry.expect.bodyIncludes ?? {})) {
      expectMatch(readPath(json, path), expected, `${caseId}.body ${path}`);
    }
    for (const path of entry.expect.bodyExcludes ?? []) {
      expect(readPath(json, path), `${caseId}.body excludes ${path}`).toBe(ABSENT);
    }
  });

  it('runs every selected case', () => {
    expect(selectedCases.length).toBe(EXPECTED_CASE_COUNT);
    expect(ranCases).toBe(EXPECTED_CASE_COUNT);
  });
});
