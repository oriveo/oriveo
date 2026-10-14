import 'fake-indexeddb/auto';

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { RelayModelTransport } from '@oriveo/shared';
import { probeRelayEndpoint } from '../probe/probe-runner';
import {
  RELAY_CLIENT_GATE_PHRASES,
  isRelayClientGateRejection,
} from '@oriveo/core/providers/relay-client-gate';
import {
  isRelayRouteRejection,
  relayGenerationRouteCandidates,
  relayProbeCandidatesFromEndpointTypes,
  resolveRelayProbeCandidates,
} from '../relay-probe-candidates';
import {
  __resetMetadataClientForTest,
  lookupModelFamilyByModel,
} from '../../metadata/metadata-client';

type Short = 'chat' | 'responses' | 'messages' | 'gemini';

interface FamilyCase {
  caseId: string;
  modelId: string;
  supportedEndpointTypes?: string[];
  byModelUnavailable?: boolean;
  expect: Short[];
}

function fixturePath(name: string): string {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', name);
    if (existsSync(candidate)) return candidate;
    dir = path.dirname(dir);
  }
  throw new Error(`${name} not found`);
}

const orchestration = JSON.parse(readFileSync(fixturePath('probe-orchestration.v1.json'), 'utf8')) as {
  transports: Record<Short, RelayModelTransport>;
  byModelResponse: unknown;
  familyCases: FamilyCase[];
  generationRouteCases: { cases: Array<{ caseId: string; route: Short; modelId: string; expect: Short[] }> };
};
const gatewayModels = JSON.parse(readFileSync(fixturePath('gateway-models.v1.json'), 'utf8')) as {
  gateways: {
    new_api: {
      records: Array<{ response: { body: { data: Array<{ id: string; supported_endpoint_types?: string[] }> } } }>;
      expected: { candidates: Record<string, Short[]> };
    };
  };
};

const wire = (names: Short[]): RelayModelTransport[] => names.map((name) => orchestration.transports[name]);
const newApi = gatewayModels.gateways.new_api;
const catalogBody = newApi.records[0]!.response.body;

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

describe('RL2-PROBE-01 candidate order reads new-api supported_endpoint_types', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  for (const entry of catalogBody.data) {
    it(`RL2-PROBE-01 endpoint types of ${entry.id} map to the fixture candidates`, () => {
      expect(relayProbeCandidatesFromEndpointTypes(entry.supported_endpoint_types))
        .toEqual(wire(newApi.expected.candidates[entry.id]!));
    });
  }

  it('RL2-PROBE-01 production catalog parsing keeps each model\'s supported_endpoint_types, and candidates match the fixture', async () => {
    const lookupFamily = vi.fn(async () => undefined);
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input);
      if (url === 'https://relay.local/v1/models' && init?.method === 'GET') return jsonResponse(catalogBody);
      throw new Error(`unexpected request: ${init?.method} ${url}`);
    });

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local',
      apiKey: 'sk-relay',
      modelHint: 'gpt-4o-mini',
      deferModelVerification: true,
      retryBackoffMs: [],
    });

    const endpointTypes = result.detection?.catalogEndpointTypes ?? {};
    for (const [modelID, expected] of Object.entries(newApi.expected.candidates)) {
      const candidates = await resolveRelayProbeCandidates({
        modelID,
        supportedEndpointTypes: endpointTypes[modelID],
        lookupFamily,
      });
      expect(candidates, modelID).toEqual(wire(expected));
    }
    // Every model has a mappable endpoint type, so the family path must never be taken.
    expect(lookupFamily).not.toHaveBeenCalled();
  });
});

describe('RL2-PROBE-02 family path: Server by-model view', () => {
  beforeEach(() => {
    __resetMetadataClientForTest();
    vi.restoreAllMocks();
  });

  afterEach(() => {
    __resetMetadataClientForTest();
    vi.restoreAllMocks();
  });

  for (const item of orchestration.familyCases) {
    it(`RL2-PROBE-02 ${item.caseId}`, async () => {
      const requested: string[] = [];
      vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
        const url = String(input);
        requested.push(url);
        if (url.endsWith('/api/metadata/model-facts?view=by-model')) {
          return item.byModelUnavailable
            ? jsonResponse({ code: 404 }, 404)
            : jsonResponse(orchestration.byModelResponse);
        }
        throw new Error(`unexpected request: ${url}`);
      });

      const candidates = await resolveRelayProbeCandidates({
        modelID: item.modelId,
        supportedEndpointTypes: item.supportedEndpointTypes,
        lookupFamily: lookupModelFamilyByModel,
      });

      expect(candidates).toEqual(wire(item.expect));
      const mapsToSomething = relayProbeCandidatesFromEndpointTypes(item.supportedEndpointTypes).length > 0;
      expect(requested.length).toBe(mapsToSomething ? 0 : 1);
    });
  }

  it('RL2-PROBE-02 the by-model view is fetched only once (in-memory cache); offline, the family is unknown', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(jsonResponse(orchestration.byModelResponse));
    expect(await lookupModelFamilyByModel('gpt-5')).toBe('openai');
    expect(await lookupModelFamilyByModel('claude-sonnet-4-5-20250929')).toBe('anthropic');
    expect(fetchMock).toHaveBeenCalledTimes(1);

    __resetMetadataClientForTest();
    fetchMock.mockRejectedValue(new TypeError('offline'));
    expect(await lookupModelFamilyByModel('gpt-5')).toBeUndefined();
  });
});

describe('RD2-ROUTE with only generation-route discovery: the probed transport comes first, then the candidate rules, de-duplicated, at most 2', () => {
  beforeEach(() => {
    __resetMetadataClientForTest();
    vi.restoreAllMocks();
  });

  afterEach(() => {
    __resetMetadataClientForTest();
    vi.restoreAllMocks();
  });

  for (const item of orchestration.generationRouteCases.cases) {
    it(`RD2-ROUTE-${item.caseId}`, async () => {
      vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
        const url = String(input);
        if (url.endsWith('/api/metadata/model-facts?view=by-model')) return jsonResponse(orchestration.byModelResponse);
        throw new Error(`unexpected request: ${url}`);
      });
      const rules = await resolveRelayProbeCandidates({ modelID: item.modelId, lookupFamily: lookupModelFamilyByModel });
      expect(relayGenerationRouteCandidates(orchestration.transports[item.route], rules)).toEqual(wire(item.expect));
    });
  }
});

/* ── official CLI gating and escaped slashes ─────────────── */

const negativeCache = JSON.parse(readFileSync(fixturePath('negative-cache.v1.json'), 'utf8')) as {
  clientGateRules: { statuses: number[]; phrases: string[] };
  clientGateCases: Array<{ caseId: string; status: number; body: string; expect: 'client_gated' | 'none' }>;
};

describe('RL2-CLIGATE official CLI gate classification (fixture clientGateCases)', () => {
  it('RL2-CLIGATE-rules phrases match the fixture clientGateRules verbatim', () => {
    expect(negativeCache.clientGateRules.statuses).toEqual([403]);
    expect([...RELAY_CLIENT_GATE_PHRASES]).toEqual(negativeCache.clientGateRules.phrases);
  });

  it.each(negativeCache.clientGateCases)('RL2-CLIGATE-$caseId', (item) => {
    expect(isRelayClientGateRejection(item.status, item.body)).toBe(item.expect === 'client_gated');
    // The gate is not a route-level rejection: it never switches transport.
    if (item.expect === 'client_gated') expect(isRelayRouteRejection({ status: item.status, body: item.body })).toBe(false);
  });

  it('RL2-CLIGATE route phrase JSON-escaped as \\/ is also recognized', () => {
    expect(isRelayRouteRejection({
      status: 403,
      body: '{"error":{"message":"This group does not allow \\/v1\\/messages dispatch"}}',
    })).toBe(true);
  });
});
