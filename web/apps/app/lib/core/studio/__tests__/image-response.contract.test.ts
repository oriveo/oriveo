// @vitest-environment node
/**
 * Shared fixture image_response_samples.v1: every real sample response and every
 * synthetic parser case runs through the Web parseImageResponse (shapes, deduped,
 * images, usage, declaredSize); decodeCases through decodeImageInfo and
 * materializeImage; metaCases through parseImageResponse (usage, declaredSize);
 * materializeCases through materializeImage; assembleCases through assembleImageOutcomes.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import {
  assembleImageOutcomes,
  decodeImageInfo,
  materializeImage,
  parseImageResponse,
  type ImageMaterializeOutcome,
  type ImageOutcomeKind,
  type ParsedImage,
} from '../image-response';

const ROOT = resolve(__dirname, '../../../../../../..');
const CONTRACTS = resolve(ROOT, 'shared/model-contracts');
const SAMPLES_DIR = resolve(CONTRACTS, 'image_response_samples.v1');

function readJson<T>(name: string): T {
  return JSON.parse(readFileSync(resolve(SAMPLES_DIR, name), 'utf8')) as T;
}

interface ExpectedImage {
  kind: string;
  mime: string | null;
  value?: string;
  revisedPrompt?: string | null;
}

interface ShapeExpect {
  shapes: string[];
  deduped: string[];
  images: ExpectedImage[];
}

interface Fixture {
  contractId: string;
  shapes: string[];
  samples: Array<{ file: string; nRequested: number; expect: ShapeExpect & { result: string } }>;
  parserCases: Array<{ name: string; body: unknown; expect: ShapeExpect }>;
  metaExpect: Array<{
    file: string;
    usage: { inputTokens: number | null; outputTokens: number | null; totalTokens: number | null } | null;
    declaredSize: { width: number; height: number } | null;
  }>;
  decodeCases: Array<{
    name: string;
    b64: string;
    expect: { mime: string; width: number; height: number } | null;
  }>;
  assembleCases: Array<{
    name: string;
    nRequested: number;
    outcomes: ImageOutcomeKind[];
    expect: { result: string | null; delivered: number; failures: string[] };
  }>;
  metaCases: Array<{
    name: string;
    body: unknown;
    usage: { inputTokens: number | null; outputTokens: number | null; totalTokens: number | null } | null;
    declaredSize: { width: number; height: number } | null;
  }>;
  materializeCases: Array<{
    name: string;
    image: { kind: ParsedImage['kind']; value: string; mime?: string | null };
    expect: { ok: true; mime: string; width: number; height: number } | { ok: false; failure: string };
  }>;
}

const fixture = readJson<Fixture>('index.json');

function sampleResponse(file: string): unknown {
  return readJson<{ response: unknown }>(file).response;
}

function bytesOf(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

function noFetch(): Promise<ImageMaterializeOutcome> {
  throw new Error('fetcher must not be called for inline images');
}

describe('image_response_samples.v1', () => {
  it('reads the fixture with the expected contractId', () => {
    expect(fixture.contractId).toBe('image_response_samples.v1');
    expect(fixture.samples.length).toBeGreaterThan(0);
  });

  describe('realSamples', () => {
    for (const sample of fixture.samples) {
      it(sample.file, () => {
        const parsed = parseImageResponse(sampleResponse(sample.file));
        expect(parsed.shapes).toEqual(sample.expect.shapes);
        expect(parsed.deduped).toEqual(sample.expect.deduped);
        expect(parsed.images.map(({ kind, mime }) => ({ kind, mime }))).toEqual(sample.expect.images);
        for (const shape of parsed.shapes) expect(fixture.shapes).toContain(shape);

        const assembled = assembleImageOutcomes(
          sample.nRequested,
          parsed.images.map(() => 'ok' as const),
        );
        expect(assembled.result).toBe(sample.expect.result === 'ok' ? 'ok' : null);
      });
    }
  });

  describe('parserCases', () => {
    for (const c of fixture.parserCases) {
      it(c.name, () => {
        const parsed = parseImageResponse(c.body);
        expect(parsed.shapes).toEqual(c.expect.shapes);
        expect(parsed.deduped).toEqual(c.expect.deduped);
        expect(parsed.images).toEqual(c.expect.images);
      });
    }
  });

  describe('metaExpect', () => {
    it('covers every real sample', () => {
      expect(fixture.metaExpect.map((m) => m.file).sort()).toEqual(
        fixture.samples.map((s) => s.file).sort(),
      );
    });
    for (const m of fixture.metaExpect) {
      it(m.file, () => {
        const parsed = parseImageResponse(sampleResponse(m.file));
        expect(parsed.usage).toEqual(m.usage);
        expect(parsed.declaredSize).toEqual(m.declaredSize);
      });
    }
  });

  describe('metaCases', () => {
    it('is not empty', () => {
      expect(fixture.metaCases.length).toBeGreaterThan(0);
    });
    for (const c of fixture.metaCases) {
      it(c.name, () => {
        const parsed = parseImageResponse(c.body);
        expect(parsed.usage).toEqual(c.usage);
        expect(parsed.declaredSize).toEqual(c.declaredSize);
      });
    }
  });

  describe('materializeCases', () => {
    it('is not empty', () => {
      expect(fixture.materializeCases.length).toBeGreaterThan(0);
    });
    for (const c of fixture.materializeCases) {
      it(c.name, async () => {
        const image: ParsedImage = {
          kind: c.image.kind,
          mime: c.image.mime ?? null,
          value: c.image.value,
          revisedPrompt: null,
        };
        const outcome = await materializeImage(image, noFetch);
        if (c.expect.ok) {
          expect(outcome.ok).toBe(true);
          if (!outcome.ok) return;
          expect({ mime: outcome.mime, width: outcome.width, height: outcome.height }).toEqual({
            mime: c.expect.mime,
            width: c.expect.width,
            height: c.expect.height,
          });
          expect(decodeImageInfo(outcome.bytes)).toEqual({
            mime: c.expect.mime,
            width: c.expect.width,
            height: c.expect.height,
          });
        } else {
          expect(outcome).toEqual({ ok: false, failure: c.expect.failure });
        }
      });
    }
  });

  describe('decodeCases', () => {
    for (const c of fixture.decodeCases) {
      it(c.name, async () => {
        const bytes = bytesOf(c.b64);
        expect(decodeImageInfo(bytes)).toEqual(c.expect);

        const asB64: ParsedImage = { kind: 'b64', mime: null, value: c.b64, revisedPrompt: null };
        const asDataUrl: ParsedImage = {
          kind: 'data_url',
          mime: 'application/octet-stream',
          value: `data:application/octet-stream;base64,${c.b64}`,
          revisedPrompt: null,
        };
        const expected: ImageMaterializeOutcome = c.expect
          ? { ok: true, bytes, ...c.expect }
          : { ok: false, failure: 'decode_failed' };
        expect(await materializeImage(asB64, noFetch)).toEqual(expected);
        expect(await materializeImage(asDataUrl, noFetch)).toEqual(expected);
      });
    }

    it('materializeImage rejects malformed inline payloads as decode_failed', async () => {
      const png = fixture.decodeCases.find((c) => c.name === 'png_rgba_3x2')!.b64;
      const bad: ParsedImage[] = [
        { kind: 'b64', mime: null, value: '@@not base64@@', revisedPrompt: null },
        { kind: 'data_url', mime: 'image/png', value: `data:image/png,${png}`, revisedPrompt: null },
      ];
      for (const image of bad) {
        expect(await materializeImage(image, noFetch)).toEqual({ ok: false, failure: 'decode_failed' });
      }
    });

    it('materializeImage hands URL images to the fetcher', async () => {
      const outcome: ImageMaterializeOutcome = { ok: false, failure: 'timeout' };
      const fetcher = vi.fn(async () => outcome);
      const image: ParsedImage = {
        kind: 'url',
        mime: null,
        value: 'https://cdn.example/a.png',
        revisedPrompt: null,
      };
      expect(await materializeImage(image, fetcher)).toBe(outcome);
      expect(fetcher).toHaveBeenCalledWith('https://cdn.example/a.png');
    });
  });

  describe('assembleCases', () => {
    for (const c of fixture.assembleCases) {
      it(c.name, () => {
        expect(assembleImageOutcomes(c.nRequested, c.outcomes)).toEqual(c.expect);
      });
    }
  });
});
