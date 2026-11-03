// @vitest-environment node
/**
 * Chat image runner chain: runChatImageStudio -> POST /api/studio/generate -> real
 * executor -> fake upstream fetch. Wire cases come from chat_image_dispatch.v1.json;
 * stored images are read back from the image store on fake-indexeddb. Only DNS, the
 * global fetch (upstream) and the thumbnail generator are faked.
 */
import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import type { Attachment } from '@oriveo/shared';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

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

import { __resetRateLimitForTests } from '../../../../app/api/chat/stream/rate-limit';
import { POST } from '../../../../app/api/studio/generate/route';
import { isStudioCompiledIn } from '../availability';
import { STUDIO_GENERATE_PATH } from '../byok-client';
import { runChatImageStudio, type ChatImageStudioDeps, type ChatImageStudioInput } from '../chat-image-runner';
import type { ImageMetadataSlice } from '../image-profile';
import { loadImageData, resetImageDBConnection, saveImage } from '../../../infra/storage/image-store';
import { resetDBConnection } from '../../../infra/storage/idb';
import { setActiveUID } from '../../../infra/storage/partition';

const ROOT = resolve(__dirname, '../../../../../../../..');
// Shared contracts directory name, spelled by code point to keep this file ASCII.
const SHARED = resolve(ROOT, String.fromCharCode(0x5171, 0x4eab));
const FIXTURE = resolve(SHARED, 'studio-contracts/chat_image_dispatch.v1.json');
const SAMPLES_INDEX = resolve(SHARED, 'model-contracts/image_response_samples.v1/index.json');
const UID = 'guest';

interface WireCase {
  caseId: string;
  input: { providerKind: string; modelId: string; profileRef: string; prompt: string };
  expect: {
    method: string;
    pathSuffix: string;
    bodyIncludes: Record<string, unknown>;
    bodyExcludes: string[];
  };
}

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, 'utf8')) as T;
}

const fixture = readJson<{ profiles: Record<string, Record<string, unknown>>; wire: WireCase[] }>(FIXTURE);
const decodeCases = readJson<{ decodeCases: Array<{ name: string; b64: string }> }>(SAMPLES_INDEX).decodeCases;

function realImage(name: string): { b64: string; bytes: Uint8Array } {
  const found = decodeCases.find((c) => c.name === name);
  if (!found) throw new Error(`missing decode case ${name}`);
  return { b64: found.b64, bytes: Uint8Array.from(atob(found.b64), (c) => c.charCodeAt(0)) };
}

const BASE_URLS: Record<string, string> = {
  openAI: 'https://api.openai.com/v1',
  zhipu: 'https://open.bigmodel.cn/api/paas/v4',
  siliconFlow: 'https://api.siliconflow.cn/v1',
  togetherAI: 'https://api.together.xyz/v1',
  qwen: 'https://dashscope.aliyuncs.com/api/v1',
  miniMax: 'https://api.minimaxi.com/v1',
};

/** Wire-shape metadata slice carrying one model that points at a fixture profile. */
function sliceFor(providerKind: string, modelId: string, profileRef: string): ImageMetadataSlice {
  return {
    profiles: { image: fixture.profiles },
    providers: { [providerKind]: { models: { [modelId]: { imageProfile: profileRef } } } },
  };
}

const THUMB_BYTES = new Uint8Array([7, 8, 9, 10]);
const THUMB_B64 = btoa(String.fromCharCode(...THUMB_BYTES));
const fakeThumbnail = async () => new Blob([THUMB_BYTES], { type: 'image/jpeg' });

interface UpstreamCall {
  url: string;
  method: string;
  body: BodyInit | null | undefined;
}

/** Stubs the upstream fetch; every call is recorded and answered by respond. */
function stubUpstream(respond: () => Response): UpstreamCall[] {
  const calls: UpstreamCall[] = [];
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input instanceof Request ? input.url : input);
      calls.push({ url, method: init?.method ?? 'GET', body: init?.body });
      return respond();
    }),
  );
  return calls;
}

function openAIImageResponse(b64: string): Response {
  return new Response(
    JSON.stringify({
      created: 1,
      data: [{ b64_json: b64 }],
      usage: { input_tokens: 12, output_tokens: 34, total_tokens: 46 },
    }),
    {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    },
  );
}

/** Client fetch that hands the request straight to the route; seen records each form. */
function routeFetch(seen?: FormData[]): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    expect(String(input)).toBe(STUDIO_GENERATE_PATH);
    if (seen && init?.body instanceof FormData) seen.push(init.body);
    return POST(new Request(`http://localhost${STUDIO_GENERATE_PATH}`, init));
  }) as typeof fetch;
}

function readPath(body: Record<string, unknown>, path: string): unknown {
  let value: unknown = body;
  for (const key of path.split('.')) {
    if (value === null || typeof value !== 'object') return undefined;
    value = (value as Record<string, unknown>)[key];
  }
  return value;
}

function baseInput(overrides: Partial<ChatImageStudioInput>): ChatImageStudioInput {
  return {
    providerKind: 'openAI',
    model: 'gpt-image-1',
    apiKey: 'test-key',
    baseURL: BASE_URLS.openAI!,
    prompt: 'a red apple',
    attachments: [],
    signal: new AbortController().signal,
    ...overrides,
  };
}

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

describe('chat image runner', () => {
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

  it('wireMatchesLegacy', async () => {
    expect(fixture.wire.length).toBe(7);
    const image = realImage('png_rgba_3x2');
    for (const c of fixture.wire) {
      __resetRateLimitForTests();
      const calls = stubUpstream(() => openAIImageResponse(image.b64));
      const deps: ChatImageStudioDeps = {
        fetch: routeFetch(),
        metadata: sliceFor(c.input.providerKind, c.input.modelId, c.input.profileRef),
        thumbnail: fakeThumbnail,
        partitionUID: UID,
      };
      const result = await runChatImageStudio(
        baseInput({
          providerKind: c.input.providerKind,
          model: c.input.modelId,
          baseURL: BASE_URLS[c.input.providerKind]!,
          prompt: c.input.prompt,
        }),
        deps,
      );
      expect(result, c.caseId).not.toBeNull();
      expect(calls.length, c.caseId).toBeGreaterThanOrEqual(1);
      const call = calls[0]!;
      expect(call.method, c.caseId).toBe(c.expect.method);
      expect(new URL(call.url).pathname.endsWith(c.expect.pathSuffix), `${c.caseId} ${call.url}`).toBe(true);
      expect(typeof call.body, c.caseId).toBe('string');
      const body = JSON.parse(call.body as string) as Record<string, unknown>;
      for (const [path, value] of Object.entries(c.expect.bodyIncludes)) {
        expect(readPath(body, path), `${c.caseId} ${path}`).toEqual(value);
      }
      for (const key of c.expect.bodyExcludes) {
        expect(Object.hasOwn(body, key), `${c.caseId} excludes ${key}`).toBe(false);
      }
    }
  });

  it('editSendsAttachmentsInOrder', async () => {
    const first = realImage('png_rgba_3x2');
    const second = realImage('jpeg_baseline_5x3');
    const firstId = crypto.randomUUID();
    await saveImage(firstId, new Blob([first.bytes], { type: 'image/png' }), null, 'image/png', UID);
    const attachments: Attachment[] = [
      { id: 'att-1', kind: 'image', fileName: 'a.png', mimeType: 'image/png', localImageID: firstId },
      // No bytes on this device: skipped, does not take a slot.
      { id: 'att-2', kind: 'image', fileName: 'b.png', mimeType: 'image/png', localImageID: crypto.randomUUID() },
      { id: 'att-3', kind: 'file', fileName: 'notes.txt', mimeType: 'text/plain', base64Data: 'aGVsbG8=' },
      { id: 'att-4', kind: 'image', fileName: 'c.jpg', mimeType: 'image/jpeg', base64Data: second.b64 },
    ];
    const calls = stubUpstream(() => openAIImageResponse(first.b64));
    const forms: FormData[] = [];
    const result = await runChatImageStudio(
      baseInput({ model: 'gpt-image-2', attachments, prompt: 'make it blue' }),
      {
        fetch: routeFetch(forms),
        metadata: sliceFor('openAI', 'gpt-image-2', 'openai_gpt_image'),
        thumbnail: fakeThumbnail,
        partitionUID: UID,
      },
    );

    expect(forms).toHaveLength(1);
    const request = JSON.parse(String(forms[0]!.get('request'))) as {
      operation: string;
      prompt: { userPrompt: string };
      params: Record<string, unknown>;
      images: Array<{ slot: number; role: string; mime: string }>;
    };
    expect(request.operation).toBe('edit');
    expect(request.prompt.userPrompt).toBe('make it blue');
    expect(request.params).toEqual({ aspect: '1:1', resolution: '1K', quality: 'standard', n: 1 });
    expect(request.images).toEqual([
      { slot: 1, role: 'base', mime: 'image/png' },
      { slot: 2, role: 'element', mime: 'image/jpeg' },
    ]);
    const part1 = forms[0]!.get('image_1') as Blob;
    const part2 = forms[0]!.get('image_2') as Blob;
    expect(new Uint8Array(await part1.arrayBuffer())).toEqual(first.bytes);
    expect(new Uint8Array(await part2.arrayBuffer())).toEqual(second.bytes);
    expect(forms[0]!.get('image_3')).toBeNull();

    expect(calls).toHaveLength(1);
    expect(new URL(calls[0]!.url).pathname.endsWith('/images/edits')).toBe(true);
    expect(result).not.toBeNull();
    expect(result && 'attachments' in result ? result.attachments : null).toHaveLength(1);
  });

  it('failureMapsToChatError', async () => {
    const deps: ChatImageStudioDeps = {
      fetch: routeFetch(),
      metadata: sliceFor('openAI', 'gpt-image-1', 'openai_images_square'),
      thumbnail: fakeThumbnail,
      partitionUID: UID,
    };

    const authCalls = stubUpstream(
      () => new Response(JSON.stringify({ error: { message: 'Incorrect API key provided' } }), { status: 401 }),
    );
    const auth = await runChatImageStudio(baseInput({}), deps);
    expect(authCalls.length).toBeGreaterThanOrEqual(1);
    expect(auth).not.toBeNull();
    expect(auth && 'errorKind' in auth ? auth.errorKind : null).toBe('invalidKey');
    expect(auth && 'attachments' in auth).toBe(false);

    // A moderation refusal answered by the route maps onto the chat moderation kind, detail kept.
    const moderation = await runChatImageStudio(baseInput({}), {
      ...deps,
      fetch: (async () =>
        new Response(JSON.stringify({ errorKind: 'refused', message: 'moderation_blocked' }), {
          status: 400,
        })) as typeof fetch,
    });
    expect(moderation).toEqual({ errorKind: 'moderation', message: 'moderation_blocked' });

    // A cancelled round is not a chat error and carries no attachments.
    const controller = new AbortController();
    controller.abort();
    const cancelled = await runChatImageStudio(baseInput({ signal: controller.signal }), deps);
    expect(cancelled).toEqual({ cancelled: true });
  });

  it('worksWithStudioCompiledOut', async () => {
    vi.stubEnv('NEXT_PUBLIC_STUDIO_ENABLED', 'false');
    expect(isStudioCompiledIn()).toBe(false);
    const image = realImage('png_rgba_3x2');
    const calls = stubUpstream(() => openAIImageResponse(image.b64));

    const result = await runChatImageStudio(baseInput({}), {
      fetch: routeFetch(),
      metadata: sliceFor('openAI', 'gpt-image-1', 'openai_images_square'),
      thumbnail: fakeThumbnail,
      partitionUID: UID,
    });

    expect(calls).toHaveLength(1);
    expect(result).not.toBeNull();
    const attachments = result && 'attachments' in result ? result.attachments : [];
    expect(attachments).toHaveLength(1);
    expect(result && 'attachments' in result ? result.usage : null).toEqual({
      inputTokens: 12,
      outputTokens: 34,
      totalTokens: 46,
    });
    const attachment = attachments[0]!;
    expect(attachment).toMatchObject({ kind: 'image', mimeType: 'image/png', thumbnailBase64: THUMB_B64 });
    expect(attachment.id).toMatch(/^[0-9a-f-]{36}$/i);
    expect(attachment.fileName).toBeTruthy();
    expect(attachment.base64Data).toBeUndefined();
    const stored = await loadImageData(attachment.localImageID!, UID);
    expect(stored).not.toBeNull();
    expect(new Uint8Array(await stored!.arrayBuffer())).toEqual(image.bytes);
  });
});
