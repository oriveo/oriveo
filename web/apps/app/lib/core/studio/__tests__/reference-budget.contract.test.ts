// @vitest-environment node
/**
 * Shared fixture byok_reference_budget.v1.json: groups spec, encodedBytes and
 * fit run through the Web reference-budget pure functions and match the
 * fixture case by case.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  REFERENCE_BUDGET_SPEC,
  fitReferenceBudget,
  referenceEncodedBytes,
  referenceRouteLimits,
  type ReferenceRoute,
  type ReferenceRouteLimits,
} from '../reference-budget';

const ROOT = resolve(__dirname, '../../../../../../..');
const CONTRACTS = resolve(ROOT, 'shared/studio-contracts');
const FIXTURE_PATH = resolve(CONTRACTS, 'byok_reference_budget.v1.json');

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, 'utf8')) as T;
}

interface FixtureImage {
  slot: number;
  role: string;
  mime: string;
  byteCount: number;
  shrunk: { mime: string; byteCount: number } | null;
}

interface Fixture {
  spec: {
    overheadBytes: number;
    routes: Record<string, ReferenceRouteLimits | null>;
    shrink: { maxLongEdge: number; jpegQuality: number; mime: string };
    tooLargeErrorKind: string;
    statuses: string[];
  };
  encodedBytes: {
    caseId: string;
    input: { route: string; editTransport: string | null; mime: string; byteCount: number };
    expect: number;
  }[];
  fit: {
    caseId: string;
    input: { route: string; editTransport: string | null; prompt: string; images: FixtureImage[] };
    expect: {
      status: string;
      errorKind: string | null;
      requestBytes: number;
      images: { slot: number; mime: string; byteCount: number }[];
      shrinkCalls: number[];
    };
  }[];
}

const fixture = readJson<Fixture>(FIXTURE_PATH);

const ALL_ROUTES: ReferenceRoute[] = [
  'openai_images',
  'xai_images',
  'openrouter_images',
  'chat_modalities',
  'gemini_generate_content',
  'dashscope_multimodal',
  'minimax_image_generation',
];

describe('byok_reference_budget.v1.json', () => {
  describe('spec', () => {
    it('constants equal the fixture spec', () => {
      expect(REFERENCE_BUDGET_SPEC).toEqual(fixture.spec);
    });

    it('every route has a row', () => {
      expect(Object.keys(fixture.spec.routes).sort()).toEqual([...ALL_ROUTES].sort());
      for (const route of ALL_ROUTES) {
        expect(referenceRouteLimits(route), route).toEqual(fixture.spec.routes[route]);
      }
    });
  });

  describe('encodedBytes', () => {
    for (const c of fixture.encodedBytes) {
      it(c.caseId, () => {
        const { route, editTransport, mime, byteCount } = c.input;
        expect(
          referenceEncodedBytes(route as ReferenceRoute, editTransport, mime, byteCount),
        ).toBe(c.expect);
      });
    }
  });

  describe('fit', () => {
    for (const c of fixture.fit) {
      it(c.caseId, async () => {
        const shrinkCalls: number[] = [];
        const result = await fitReferenceBudget<FixtureImage>({
          route: c.input.route as ReferenceRoute,
          editTransport: c.input.editTransport,
          prompt: c.input.prompt,
          images: c.input.images,
          describe: (image) => ({
            slot: image.slot,
            role: image.role,
            mime: image.mime,
            byteCount: image.byteCount,
          }),
          shrink: async (image) => {
            shrinkCalls.push(image.slot);
            if (image.shrunk === null) return null;
            return { ...image, mime: image.shrunk.mime, byteCount: image.shrunk.byteCount, shrunk: null };
          },
        });
        expect(result.status).toBe(c.expect.status);
        expect(result.errorKind).toBe(c.expect.errorKind);
        expect(result.requestBytes).toBe(c.expect.requestBytes);
        expect(
          result.images.map((image) => ({
            slot: image.slot,
            mime: image.mime,
            byteCount: image.byteCount,
          })),
        ).toEqual(c.expect.images);
        expect(shrinkCalls).toEqual(c.expect.shrinkCalls);
      });
    }
  });
});
