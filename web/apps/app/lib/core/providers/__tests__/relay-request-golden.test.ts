// @vitest-environment node
//
// RL2-MIGRATE-01: golden of existing outbound requests (method / url / headers / body raw bytes),
// the baseline for "byte-for-byte unchanged" when the throat is replaced. Input comes only from the shared manifest cases.v1.json.
//
// Placed in apps/app rather than packages/core: the relay transport derivation
// (relayRequested.transport -> relayResolvedTransport -> StreamOptions.relayTransport)
// lives in buildProviderStreamOptions of apps/app `stream-options.ts`, which the packages layer cannot reproduce.
//
// Production paths:
// - official: shell `request-builders/dispatch.ts` buildProviderRequest used by route.ts
//   → `request-builders/utils.ts` executeProviderRequest (global fetch). Metadata fetching fails here
//   (fetch throws on /api/metadata), i.e. the providerDefaults shape when "metadata is unreachable".
// - relay: buildProviderStreamOptions → service.sendStream('relay') → registry → adapters/relay
//   → core relay-orchestrator. In the node environment the Web adapter takes the direct branch, so what is captured is the request sent to the relay.
//
// With ORIVEO_GOLDEN_RECORD=1, writes web.v1.json; otherwise compares case by case, and a missing file or mismatch fails.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, ProviderKind } from '@oriveo/shared';
import { buildProviderRequest } from '../../../../app/api/chat/stream/request-builders/dispatch';
import { executeProviderRequest } from '../../../../app/api/chat/stream/request-builders/utils';
import { __resetRuntimeMetadataCache } from '../../../../app/api/chat/stream/runtime';
import { __resetMetadataClientForTest } from '../../metadata/metadata-client';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../chat/stream-options';
import { sendStream } from '../service';

// The OpenRouter attribution referer follows the deployment origin (brand.appUrl, read at import time).
// Pin it to the community repository URL that the shared golden fixture records for every client.
vi.hoisted(() => {
  process.env.NEXT_PUBLIC_APP_URL = 'https://github.com/oriveo/oriveo';
});

interface Manifest {
  version: number;
  apiKey: string;
  conversation: { role: 'system' | 'user' | 'assistant'; content: string }[];
  official: { caseId: string; providerKind: ProviderKind; model: string }[];
  relay: { caseId: string; baseURL: string; relayRequested: Provider['relayRequested'] }[];
  relayModel: string;
}

type GoldenRecord =
  | { caseId: string; method: string; url: string; headers: Record<string, string>; body: string }
  | { caseId: string; unsupported: string };

interface GoldenFile {
  $comment: string;
  version: number;
  end: 'web';
  cases: GoldenRecord[];
}

const RECORD = process.env.ORIVEO_GOLDEN_RECORD === '1';

/**
 * The only golden difference allowed after the throat replacement: for connections with a bare host and no probed root address,
 * Chat / auto / Responses now append `/v1` per C3 section 2 (aligned with iOS and the fixture resolveCases).
 * Only the URL may change from before to after; method / headers / body stay byte-for-byte unchanged. When re-recording, check each one;
 * all other cases must be identical before and after re-recording; re-recording must not wash other drift into the baseline.
 */
const D33_ALLOWED_URL_CHANGE: Record<string, { before: string; after: string }> = {
  relay_chat_bare_host: {
    before: 'https://relay.example.com/chat/completions',
    after: 'https://relay.example.com/v1/chat/completions',
  },
  relay_auto_bare_host: {
    before: 'https://relay.example.com/chat/completions',
    after: 'https://relay.example.com/v1/chat/completions',
  },
  relay_responses_bare_host: {
    before: 'https://relay.example.com/responses',
    after: 'https://relay.example.com/v1/responses',
  },
};
/**
 * The only golden differences allowed after the Codex identity change: Relay Responses request bodies with a Codex identity gain a trailing
 * `prompt_cache_key`, and the User-Agent version is updated. Only these two may change from before to after; everything else stays byte-for-byte.
 */
const CODEX_IDENTITY_ALLOWED_CHANGE: Record<string, {
  userAgent: { before: string; after: string };
  promptCacheKey: string;
}> = {
  relay_responses_bare_host: {
    userAgent: {
      before: 'codex_cli_rs/0.50.0 (Oriveo Web; Node.js)',
      after: 'codex_cli_rs/0.162.1 (Oriveo Web; Node.js)',
    },
    promptCacheKey: '2290bbc6e2bae08a11ede516e419f3c6',
  },
};

/** Lift the old baseline to the new convention before comparing: one already on the new convention is returned as is, so re-recording is repeatable. */
function withCodexIdentityChange<T extends GoldenRecord>(
  record: T,
  change: (typeof CODEX_IDENTITY_ALLOWED_CHANGE)[string],
): T {
  if (!('body' in record)) return record;
  const body = JSON.parse(record.body) as Record<string, unknown>;
  if (!('prompt_cache_key' in body)) body.prompt_cache_key = change.promptCacheKey;
  const headers = { ...record.headers };
  if (headers['user-agent'] === change.userAgent.before) headers['user-agent'] = change.userAgent.after;
  return { ...record, headers, body: JSON.stringify(body) };
}

// openai_responses direct generates a session_id; fix the source so golden does not delete fields.
const FIXED_UUID = '00000000-0000-4000-8000-000000000000';

function findFixtureDir(): string {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'request-golden');
    if (existsSync(path.join(candidate, 'cases.v1.json'))) return candidate;
    dir = path.dirname(dir);
  }
  throw new Error('request-golden/cases.v1.json not found');
}

const FIXTURE_DIR = findFixtureDir();
const GOLDEN_PATH = path.join(FIXTURE_DIR, 'web.v1.json');
const manifest = JSON.parse(readFileSync(path.join(FIXTURE_DIR, 'cases.v1.json'), 'utf8')) as Manifest;

function normalizeHeaders(raw: HeadersInit | undefined): Record<string, string> {
  const entries: [string, string][] = raw instanceof Headers
    ? [...raw.entries()]
    : Array.isArray(raw)
      ? raw.map(([k, v]) => [k, v] as [string, string])
      : Object.entries(raw ?? {}).map(([k, v]) => [k, String(v)] as [string, string]);
  const out: Record<string, string> = {};
  for (const [k, v] of entries.map(([k, v]) => [k.toLowerCase(), v] as [string, string]).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
    out[k] = v;
  }
  return out;
}

interface Captured { method: string; url: string; headers: Record<string, string>; body: string }

/** Stub global fetch: /api/metadata throws (metadata unreachable), the rest only record the first one. */
function installFetchStub(): { first: () => Captured | undefined; count: () => number } {
  const calls: Captured[] = [];
  vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    if (url.includes('/api/metadata')) throw new Error('metadata unavailable in golden test');
    calls.push({
      method: init?.method ?? 'GET',
      url,
      headers: normalizeHeaders(init?.headers),
      body: typeof init?.body === 'string' ? init.body : String(init?.body),
    });
    return new Response('data: [DONE]\n\n', { status: 200, headers: { 'content-type': 'text/event-stream' } });
  });
  return { first: () => calls[0], count: () => calls.length };
}

function relayModel(): AIModel {
  return {
    id: manifest.relayModel,
    name: manifest.relayModel,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: '',
  } as AIModel;
}

function relayProvider(item: Manifest['relay'][number], model: AIModel): Provider {
  return {
    id: `relay-golden-${item.caseId}`,
    kind: 'relay',
    status: { kind: 'connected' },
    models: [model],
    catalogModels: [],
    apiKey: manifest.apiKey,
    apiKeyPreview: '••',
    baseURLText: item.baseURL,
    relayRequested: item.relayRequested,
  } as Provider;
}

async function captureOfficial(item: Manifest['official'][number]): Promise<Captured> {
  const stub = installFetchStub();
  const req = await buildProviderRequest({
    providerKind: item.providerKind,
    apiKey: manifest.apiKey,
    modelID: item.model,
    messages: manifest.conversation,
    stream: true,
  });
  await executeProviderRequest(req);
  const captured = stub.first();
  if (!captured) throw new Error('official builder sent no request');
  return captured;
}

async function captureRelay(provider: Provider, model: AIModel): Promise<Captured> {
  const stub = installFetchStub();
  const raw = buildStreamOptionsFromIntent(model, undefined, false);
  const options = buildProviderStreamOptions(provider, raw, model);
  const handle = sendStream('relay', provider.apiKey, model.id, manifest.conversation, provider.baseURLText, options);
  const reader = handle.stream.getReader();
  for (let i = 0; i < 20 && stub.count() === 0; i += 1) {
    const { done } = await reader.read();
    if (done) break;
  }
  await reader.cancel().catch(() => undefined);
  const captured = stub.first();
  if (!captured) throw new Error('relay orchestrator sent no request');
  return captured;
}

const recorded: GoldenRecord[] = [];
let golden: GoldenFile | null = null;

function check(record: GoldenRecord) {
  const allowed = D33_ALLOWED_URL_CHANGE[record.caseId];
  if (allowed) {
    expect('url' in record ? record.url : undefined, `${record.caseId} D-33 URL`).toBe(allowed.after);
  }
  const codexChange = CODEX_IDENTITY_ALLOWED_CHANGE[record.caseId];
  if (codexChange) {
    expect('headers' in record ? record.headers['user-agent'] : undefined, `${record.caseId} User-Agent`)
      .toBe(codexChange.userAgent.after);
    expect(
      'body' in record ? (JSON.parse(record.body) as Record<string, unknown>).prompt_cache_key : undefined,
      `${record.caseId} prompt_cache_key`,
    ).toBe(codexChange.promptCacheKey);
  }
  if (RECORD) {
    // Re-record guard: when a baseline exists, nothing may change except the URLs of those three cases and the one Codex identity case.
    const stored = golden?.cases.find((entry) => entry.caseId === record.caseId);
    const previous = stored && codexChange ? withCodexIdentityChange(stored, codexChange) : stored;
    if (previous) {
      if (allowed && 'url' in previous && 'url' in record) {
        expect([allowed.before, allowed.after], `${record.caseId} previous URL`).toContain(previous.url);
        expect({ ...record, url: allowed.after }).toStrictEqual({ ...previous, url: allowed.after });
      } else {
        expect(record).toStrictEqual(previous);
      }
    }
    recorded.push(record);
    return;
  }
  expect(golden, `missing ${GOLDEN_PATH}; record with ORIVEO_GOLDEN_RECORD=1`).not.toBeNull();
  const expected = golden!.cases.find((entry) => entry.caseId === record.caseId);
  expect(expected, `case ${record.caseId} missing from web.v1.json`).toBeDefined();
  expect(record).toStrictEqual(expected);
}

async function recordOrUnsupported(caseId: string, build: () => Promise<Captured>): Promise<GoldenRecord> {
  try {
    return { caseId, ...(await build()) };
  } catch (error) {
    return { caseId, unsupported: error instanceof Error ? error.message : String(error) };
  }
}

describe('RL2-MIGRATE-01 golden of existing outbound requests (Web)', () => {
  beforeAll(() => {
    // Re-record mode also reads the old baseline: used to verify no other drift beyond the three URL cases.
    golden = existsSync(GOLDEN_PATH)
      ? (JSON.parse(readFileSync(GOLDEN_PATH, 'utf8')) as GoldenFile)
      : null;
  });

  beforeEach(() => {
    __resetRuntimeMetadataCache();
    __resetMetadataClientForTest();
    vi.spyOn(globalThis.crypto, 'randomUUID').mockReturnValue(FIXED_UUID);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  afterAll(() => {
    if (!RECORD) return;
    const order = [...manifest.official, ...manifest.relay].map((entry) => entry.caseId);
    const file: GoldenFile = {
      $comment: 'RL2-MIGRATE-01 Web baseline, generated by apps/app/lib/core/providers/__tests__/relay-request-golden.test.ts with ORIVEO_GOLDEN_RECORD=1. Do not hand-edit.',
      version: manifest.version,
      end: 'web',
      cases: order.map((caseId) => recorded.find((entry) => entry.caseId === caseId)!).filter(Boolean),
    };
    writeFileSync(GOLDEN_PATH, `${JSON.stringify(file, null, 2)}\n`);
  });

  for (const item of manifest.official) {
    it(`RL2-MIGRATE-01 ${item.caseId}`, async () => {
      check(await recordOrUnsupported(item.caseId, () => captureOfficial(item)));
    });
  }

  for (const item of manifest.relay) {
    it(`RL2-MIGRATE-01 ${item.caseId}`, async () => {
      const model = relayModel();
      const provider = relayProvider(item, model);
      check(await recordOrUnsupported(item.caseId, () => captureRelay(provider, model)));
    });
  }

  it('RL2-MIGRATE-01 relay build does not rewrite provider.relayRequested or the model object', async () => {
    for (const item of manifest.relay) {
      const model = relayModel();
      const provider = relayProvider(item, model);
      const requestedRef = provider.relayRequested;
      const requestedBefore = structuredClone(provider.relayRequested);
      const modelBefore = structuredClone(model);
      await captureRelay(provider, model);
      vi.unstubAllGlobals();
      expect(provider.relayRequested, item.caseId).toBe(requestedRef);
      expect(provider.relayRequested, item.caseId).toStrictEqual(requestedBefore);
      expect(provider.relayRequested, item.caseId).toStrictEqual(item.relayRequested);
      expect(model, item.caseId).toStrictEqual(modelBefore);
      expect(provider.models[0], item.caseId).toBe(model);
      expect('relayTransport' in model, item.caseId).toBe(false);
    }
  });
});
