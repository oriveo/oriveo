// @vitest-environment node
/**
 * Web BYOK full chain: browser client (runStudioByokRound) -> POST /api/studio/generate
 * -> real executor -> fake upstream answering a recorded golden response -> parse and
 * materialize -> persistStudioRoundImages on fake-indexeddb. Assertions read the bytes
 * back from the image store. Only DNS and the global fetch (upstream) are faked.
 */
import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// Hostnames below are resolved to a fixed public address so the real SSRF guard
// passes without network access.
const dnsMocks = vi.hoisted(() => ({
  resolve4: vi.fn(async () => ['203.0.113.10']),
  resolve6: vi.fn(async () => {
    throw Object.assign(new Error('ENODATA'), { code: 'ENODATA' });
  }),
  lookup: vi.fn(async () => [{ address: '203.0.113.10', family: 4 }]),
}));

vi.mock('node:dns/promises', () => ({
  default: dnsMocks,
  ...dnsMocks,
}));

import { __resetRateLimitForTests } from '../../chat/stream/rate-limit';
import { runStudioByokRound, STUDIO_GENERATE_PATH } from '../../../../lib/core/studio/byok-client';
import { persistStudioRoundImages } from '../../../../lib/core/studio/byok-persist';
import type { ImageProfile } from '../../../../lib/core/studio/image-profile';
import { decodeImageInfo } from '../../../../lib/core/studio/image-response';
import { loadImageData, resetImageDBConnection } from '../../../../lib/infra/storage/image-store';
import { resetDBConnection } from '../../../../lib/infra/storage/idb';
import { setActiveUID } from '../../../../lib/infra/storage/partition';
import { POST } from './route';

const ROOT = resolve(__dirname, '../../../../../../..');
// Shared contracts directory name, spelled by code point to keep this file ASCII.
const CONTRACTS = resolve(ROOT, 'shared', 'model-contracts');
const SAMPLES_DIR = resolve(CONTRACTS, 'image_response_samples.v1');
const UID = 'guest';

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, 'utf8')) as T;
}

const normalization = readJson<{ profiles: Record<string, ImageProfile> }>(
  resolve(CONTRACTS, 'image_param_normalization.v1.json'),
);
const decodeCases = readJson<{ decodeCases: Array<{ name: string; b64: string }> }>(
  resolve(SAMPLES_DIR, 'index.json'),
).decodeCases;

/** Real image from the shared decodeCases, standing in for a sample's base64 placeholder. */
function realImage(name: string): { b64: string; bytes: Uint8Array } {
  const found = decodeCases.find((c) => c.name === name);
  if (!found) throw new Error(`missing decode case ${name}`);
  return { b64: found.b64, bytes: Uint8Array.from(atob(found.b64), (c) => c.charCodeAt(0)) };
}

interface ChainCase {
  route: string;
  sampleFile: string;
  profileKey: string;
  providerKind: string;
  modelId: string;
  baseURL: string;
  imageCase: string;
  /** Puts the real base64 into the sample's image slot; returns the upstream body. */
  fill: (response: Record<string, any>, b64: string) => Record<string, any>;
}

const CASES: ChainCase[] = [
  {
    route: 'openai_images',
    sampleFile: 'openai_images.openai.gpt-image-2.generate.json',
    profileKey: 'openai_gpt_image',
    providerKind: 'openai',
    modelId: 'gpt-image-2',
    baseURL: 'https://api.openai.com/v1',
    imageCase: 'png_rgba_3x2',
    fill: (response, b64) => {
      response.data[0].b64_json = b64;
      return response;
    },
  },
  {
    route: 'gemini_generate_content',
    sampleFile: 'gemini_generate_content.gemini.gemini-3.1-flash-lite-image.generate.json',
    profileKey: 'gemini_flash_image',
    providerKind: 'gemini',
    modelId: 'gemini-3.1-flash-lite-image',
    baseURL: 'https://generativelanguage.googleapis.com/v1beta',
    imageCase: 'jpeg_baseline_5x3',
    fill: (response, b64) => {
      response.candidates[0].content.parts[0].inlineData.data = b64;
      return response;
    },
  },
];

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

describe('studio generate chain', () => {
  beforeEach(async () => {
    __resetRateLimitForTests();
    resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    await setActiveUID(UID);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
  });

  for (const c of CASES) {
    it(c.route, async () => {
      const sample = readJson<{ meta: { route: string }; response: Record<string, any> }>(
        resolve(SAMPLES_DIR, c.sampleFile),
      );
      expect(sample.meta.route).toBe(c.route);
      const image = realImage(c.imageCase);
      const upstreamBody = JSON.stringify(c.fill(structuredClone(sample.response), image.b64));

      const upstreamCalls: string[] = [];
      vi.stubGlobal(
        'fetch',
        vi.fn(async (input: RequestInfo | URL) => {
          const url = String(input instanceof Request ? input.url : input);
          upstreamCalls.push(url);
          if (!url.startsWith(c.baseURL)) throw new Error(`unexpected fetch ${url}`);
          return new Response(upstreamBody, { status: 200, headers: { 'Content-Type': 'application/json' } });
        }),
      );

      const clientFetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
        expect(String(input)).toBe(STUDIO_GENERATE_PATH);
        return POST(new Request(`http://localhost${STUDIO_GENERATE_PATH}`, init));
      }) as typeof fetch;

      const signal = new AbortController().signal;
      const round = await runStudioByokRound(
        {
          providerKind: c.providerKind,
          apiKey: 'test-key',
          baseURL: c.baseURL,
          modelId: c.modelId,
          profile: normalization.profiles[c.profileKey]!,
          operation: 'generate',
          prompt: { userPrompt: 'a red apple', references: [] },
          params: {},
          advanced: null,
          images: [],
        },
        { fetch: clientFetch, signal },
      );
      expect(round.status).toBe('completed');
      expect(upstreamCalls).toHaveLength(1);

      const persisted = await persistStudioRoundImages(round, { partitionUID: UID, signal });
      expect(persisted.status).toBe('completed');
      expect(persisted.images).toHaveLength(1);

      const info = decodeImageInfo(image.bytes);
      expect(info).not.toBeNull();
      const saved = persisted.images[0]!;
      expect({ mime: saved.mime, width: saved.width, height: saved.height }).toEqual({
        mime: info!.mime,
        width: info!.width,
        height: info!.height,
      });

      const blob = await loadImageData(saved.assetId, UID);
      expect(blob).not.toBeNull();
      expect(blob!.type).toBe(info!.mime);
      expect(new Uint8Array(await blob!.arrayBuffer())).toEqual(image.bytes);
    });
  }
});
