/**
 * Citation parsing for the four relay chat protocols.
 *
 * Source of truth: the shared `test-fixtures/relay/web-probe.v1.json`. The searched / silent streaming replies in evidenceCases,
 * and the gateway's verbatim output of gatewayRecordings.new_api_chat_to_claude, are fed into the production path
 * `sendRelayStream` (the inline parse closure in relay-orchestrator), asserting that the urls in the produced citations events
 * equal expect.evidenceUrls; silent cases produce no citations.
 */
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { sendRelayStream, type RelayOrchestratorDeps } from '../relay-orchestrator';
import type { StreamEvent, StreamOptions } from '../types';
import type { UpstreamTransport } from '../../ports';

// __tests__ -> providers -> src -> core -> packages -> web -> <repo root>
const FIXTURE_PATH = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../../../../shared/test-fixtures/relay/web-probe.v1.json',
);

interface EvidenceCase {
  caseId: string;
  transport: RelayTransport;
  status: number | null;
  sse?: string[];
  expect: { result: string; evidenceUrls?: string[] };
}

interface WebProbeFixture {
  evidenceCases: EvidenceCase[];
  gatewayRecordings: {
    new_api_chat_to_claude: {
      response: { sse: string[] };
      expect?: { evidenceUrls?: string[] };
    };
  };
}

type RelayTransport = NonNullable<StreamOptions['relayTransport']>;

const fixture = JSON.parse(readFileSync(FIXTURE_PATH, 'utf8')) as WebProbeFixture;

function relayDeps(body: string): RelayOrchestratorDeps {
  const transport: UpstreamTransport = {
    fetch: async () =>
      new Response(body, { status: 200, headers: { 'Content-Type': 'text/event-stream' } }),
  };
  return {
    transport,
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
}

async function citedUrls(transport: RelayTransport, body: string): Promise<string[]> {
  const handle = sendRelayStream(
    'sk-test',
    'relay-model',
    [{ role: 'user', content: 'top news today' }],
    'https://relay.example/v1',
    { relayTransport: transport, relayAuthMode: 'bearer' },
    relayDeps(body),
  );
  const events: StreamEvent[] = [];
  const reader = handle.stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    events.push(value);
  }
  const errors = events.filter((e) => e.type === 'error');
  expect(errors).toEqual([]);
  const citationEvents = events.filter(
    (e): e is Extract<StreamEvent, { type: 'citations' }> => e.type === 'citations',
  );
  const last = citationEvents[citationEvents.length - 1];
  return last ? last.citations.map((c) => c.url) : [];
}

const streamCases = fixture.evidenceCases.filter(
  (c) => c.status === 200 && Array.isArray(c.sse) && (c.expect.result === 'searched' || c.expect.result === 'silent'),
);

describe('relay orchestrator citations (web-probe evidence)', () => {
  it('fixture carries searched and silent stream cases', () => {
    expect(streamCases.filter((c) => c.expect.result === 'searched').length).toBeGreaterThanOrEqual(4);
    expect(streamCases.filter((c) => c.expect.result === 'silent').length).toBeGreaterThanOrEqual(4);
  });

  for (const c of streamCases) {
    it(`RL2-WEBPROBE-CITE-${c.caseId}`, async () => {
      const body = `${(c.sse ?? []).join('\n')}\n`;
      const urls = await citedUrls(c.transport, body);
      expect(urls).toEqual(c.expect.result === 'silent' ? [] : c.expect.evidenceUrls ?? []);
    });
  }

  it('RL2-WEBPROBE-CITE-new_api_chat_to_claude', async () => {
    const recording = fixture.gatewayRecordings.new_api_chat_to_claude;
    // The gateway's verbatim output has only data lines with no blank lines between them: each line becomes its own frame.
    const body = recording.response.sse.map((line) => `${line}\n\n`).join('');
    const urls = await citedUrls('openai_chat_completions', body);
    expect(urls).toEqual(recording.expect?.evidenceUrls ?? ['https://news.example.com/top']);
  });
});
