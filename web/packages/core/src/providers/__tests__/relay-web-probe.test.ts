/**
 * Pure-computation part of the relay web probe.
 *
 * Source of truth: `shared/test-fixtures/relay/web-probe.v1.json`.
 * - EV / GW: one response (or no response) first goes through the same status classification as the capability test, and 2xx is then fed to the relay-orchestrator production parser to judge evidence.
 * - HASH: canonical JSON of the snippet and SHA-256.
 * - MERGE: merging records per connection x model x protocol.
 */
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  canonicalRelayWebFragmentJSON,
  judgeRelayWebProbeResponse,
  mergeRelayWebProbeRecord,
  relayWebFragmentHash,
  type RelayWebProbeRecord,
} from '../relay-web-probe';
import type { RelayWebTransport } from '@oriveo/shared/relay/web-fragments';

// __tests__ -> providers -> src -> core -> packages -> web -> <repo root>
const FIXTURE_PATH = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../../../../shared/test-fixtures/relay/web-probe.v1.json',
);

interface EvidenceCase {
  caseId: string;
  transport: RelayWebTransport;
  status: number | null;
  failure?: 'timeout' | 'network' | 'cancelled';
  sse?: string[];
  body?: unknown;
  expect: { result: string; evidenceUrls?: string[] };
}

interface WebProbeFixture {
  evidenceCases: EvidenceCase[];
  gatewayRecordings: Record<string, {
    response: { status: number; contentType: string; sse: string[] };
    expect: { transport: RelayWebTransport; result: string; evidenceUrls: string[] };
  }>;
  fragmentHash: { cases: Array<{ caseId: string; fragment: Record<string, unknown>; canonical: string; sha256: string }> };
  record: {
    mergeCases: Array<{
      caseId: string;
      existing: Omit<RelayWebProbeRecord, 'at'> | null;
      incoming: Omit<RelayWebProbeRecord, 'at'>;
      expect: Pick<RelayWebProbeRecord, 'result' | 'source'>;
    }>;
  };
}

const fixture = JSON.parse(readFileSync(FIXTURE_PATH, 'utf8')) as WebProbeFixture;

describe('relay web probe judgement (web-probe.v1.json)', () => {
  for (const c of fixture.evidenceCases) {
    it(`RL2-WEBPROBE-EV-${c.caseId}`, async () => {
      const verdict = await judgeRelayWebProbeResponse(
        c.transport,
        c.status === null
          ? { failure: c.failure ?? 'network' }
          : c.sse
            ? { status: c.status, contentType: 'text/event-stream', body: `${c.sse.join('\n')}\n` }
            : { status: c.status, contentType: 'application/json', body: JSON.stringify(c.body) },
      );
      expect(verdict.result).toBe(c.expect.result);
      if (c.expect.evidenceUrls) expect(verdict.evidenceUrls).toEqual(c.expect.evidenceUrls);
      if (c.expect.result !== 'searched') expect(verdict.evidenceUrls).toEqual([]);
    });
  }

  for (const [key, recording] of Object.entries(fixture.gatewayRecordings)) {
    it(`RL2-WEBPROBE-GW-${key}`, async () => {
      // The gateway's verbatim output has only data lines with no blank lines between them: each line becomes its own frame.
      const body = recording.response.sse.map((line) => `${line}\n\n`).join('');
      const verdict = await judgeRelayWebProbeResponse(recording.expect.transport, {
        status: recording.response.status,
        contentType: recording.response.contentType,
        body,
      });
      expect(verdict.result).toBe(recording.expect.result);
      expect(verdict.evidenceUrls).toEqual(recording.expect.evidenceUrls);
    });
  }
});

describe('relay web fragment hash', () => {
  for (const c of fixture.fragmentHash.cases) {
    it(`RL2-WEBPROBE-HASH-${c.caseId}`, () => {
      expect(canonicalRelayWebFragmentJSON(c.fragment)).toBe(c.canonical);
      expect(relayWebFragmentHash(c.fragment)).toBe(c.sha256);
    });
  }
});

describe('relay web probe record merge', () => {
  const AT = '2026-10-13T12:00:00.000Z';
  for (const c of fixture.record.mergeCases) {
    it(`RL2-WEBPROBE-MERGE-${c.caseId}`, () => {
      const merged = mergeRelayWebProbeRecord(
        c.existing ? { ...c.existing, at: '2026-10-12T12:00:00.000Z' } : null,
        { ...c.incoming, at: AT },
      );
      expect({ result: merged.result, source: merged.source }).toEqual(c.expect);
    });
  }
});
