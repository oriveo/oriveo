import 'fake-indexeddb/auto';
/**
 * Web probe decides as soon as evidence is seen (fixture shared/test-fixtures/relay/web-probe.v1.json earlyStopCases):
 * through the default send of the production probe entry runRelayWebProbe (global fetch), with a streaming 2xx injected event by event (stall = never closes),
 * and a virtual clock that only takes over setTimeout (total limit = request.timeoutSeconds). Asserts the verdict, the reason, whether the request was cancelled, and after which event at the latest it was decided.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, RelayModelTransport } from '@oriveo/shared';
import { createAppStore } from '../store/app-store';

vi.mock('../sync', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../sync')>()),
  getSyncAdapter: () => null,
}));

import { runRelayWebProbe, type RelayWebProbeRunResult } from '../relay-web-probe-ops';

interface EarlyStopCase {
  caseId: string;
  transport: RelayModelTransport;
  events: string[];
  then: 'close' | 'stall';
  expect: {
    result: string;
    reason: string;
    cancelled: boolean;
    decidedAfterEventAtMost: number | null;
    urlsInclude: string[];
  };
}

const fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'web-probe.v1.json');
    if (existsSync(candidate)) {
      return JSON.parse(readFileSync(candidate, 'utf8')) as {
        request: { timeoutSeconds: number };
        earlyStopCases: { cases: EarlyStopCase[] };
      };
    }
    dir = path.dirname(dir);
  }
  throw new Error('web-probe.v1.json not found');
})();

const PROVIDER_ID = 'relay-early';
const MODEL_ID = 'probe-model';

function storeFor(transport: RelayModelTransport) {
  const model: AIModel = {
    id: MODEL_ID, name: MODEL_ID, capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
  };
  const provider: Provider = {
    id: PROVIDER_ID, kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [{ ...model, isDefault: false }],
    apiKey: 'sk-test', apiKeyPreview: 'sk-...test', baseURLText: 'https://relay.example.com', relayKind: 'openai_compatible',
    relayRequested: { transport, authMode: 'auto' },
  } as Provider;
  const store = createAppStore();
  store.getState().addProvider(provider);
  return store;
}

/** Lets the async steps of the stream, fetch and parsing finish (without advancing the virtual clock). */
async function settle(): Promise<void> {
  for (let round = 0; round < 20; round += 1) {
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
}

/** A fake relay: the response headers arrive immediately and the test pushes the body event by event; records whether the request was cancelled. */
/** On the wire each Messages frame carries an `event:` line (same shape as the evidenceCases recordings); other protocols have only data lines. */
function frame(transport: RelayModelTransport, event: string): string {
  if (transport !== 'anthropic_messages') return `data: ${event}\n\n`;
  return `event: ${(JSON.parse(event) as { type: string }).type}\ndata: ${event}\n\n`;
}

function installStreamingRelay(transport: RelayModelTransport) {
  const encoder = new TextEncoder();
  const state = { cancelled: false, controller: undefined as ReadableStreamDefaultController<Uint8Array> | undefined };
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (_input, init) => {
    init?.signal?.addEventListener('abort', () => { state.cancelled = true; }, { once: true });
    const body = new ReadableStream<Uint8Array>({
      start: (controller) => { state.controller = controller; },
      cancel: () => { state.cancelled = true; },
    });
    return new Response(body, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
  });
  return {
    state,
    push: (event: string) => state.controller!.enqueue(encoder.encode(frame(transport, event))),
    close: () => state.controller!.close(),
  };
}

beforeEach(() => {
  localStorage.clear();
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe('RL2-WEBPROBE-EARLY decides as soon as evidence is seen', () => {
  for (const item of fixture.earlyStopCases.cases) {
    it(`RL2-WEBPROBE-EARLY-${item.caseId}`, async () => {
      const relay = installStreamingRelay(item.transport);
      let result: RelayWebProbeRunResult | undefined;
      const probe = runRelayWebProbe(storeFor(item.transport), PROVIDER_ID, MODEL_ID).then((value) => { result = value; });
      await settle();
      expect(relay.state.controller, item.caseId).toBeDefined();

      let decidedAfter: number | null = null;
      for (const [index, event] of item.events.entries()) {
        if (result) break;
        relay.push(event);
        await settle();
        if (result) decidedAfter = index + 1;
      }
      if (!result) {
        if (item.then === 'close') relay.close();
        else await vi.advanceTimersByTimeAsync(fixture.request.timeoutSeconds * 1000);
        await settle();
      }
      await probe;

      expect(result?.outcome, item.caseId).toBe('completed');
      expect({ result: result?.result, reason: result?.reason }, item.caseId).toEqual({ result: item.expect.result, reason: item.expect.reason });
      expect(relay.state.cancelled, `${item.caseId} cancelled`).toBe(item.expect.cancelled);
      if (item.expect.decidedAfterEventAtMost === null) expect(decidedAfter, item.caseId).toBeNull();
      else expect(decidedAfter ?? Infinity, item.caseId).toBeLessThanOrEqual(item.expect.decidedAfterEventAtMost);
      for (const url of item.expect.urlsInclude) expect(result?.evidenceUrls, item.caseId).toContain(url);
    });
  }
});
