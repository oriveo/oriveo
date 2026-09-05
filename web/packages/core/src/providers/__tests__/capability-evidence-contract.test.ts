import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  generationParameterEvidenceCandidates,
  isCapabilityEvidenceEditable,
  resolveCapabilityEvidence,
  type CapabilityEvidenceCandidate,
  type CapabilityEvidenceQuery,
} from '../capability-evidence-facade';
import { resolveGenerationProfile, type RuntimeMetadataResponse } from '../request-builders/runtime';

interface EvidenceContract {
  version: number;
  schema: { sourcePriority: string[] };
  cases: Array<{
    caseId: string;
    query: CapabilityEvidenceQuery;
    candidates: CapabilityEvidenceCandidate[];
    expect: Record<string, unknown>;
  }>;
}

describe('capability_evidence_contract.v1', () => {
  const contract = loadJSON<EvidenceContract>('shared/model-contracts/capability_evidence_contract.v1.json');

  it('freezes the contract version and source priority', () => {
    expect(contract.version).toBe(1);
    expect(contract.schema.sourcePriority).toEqual([
      'operator_override',
      'server_typed',
      'server_profile',
      'relay_verification',
      'relay_declaration',
      'legacy_metadata',
    ]);
  });

  for (const item of contract.cases) {
    it(item.caseId, () => {
      const key = String(item.expect.key);
      expect(resolveCapabilityEvidence(key, item.query, item.candidates)).toEqual(item.expect);
    });
  }

  it('fails closed when a connection-scoped candidate omits its partition identity', () => {
    // Failing closed governs **evidence consumption**: a declaration from another connection must
    // not be treated as fact for this one (support stays unknown and source stays none). It is not a
    // send gate: an intent the user expressed explicitly is still sent when there is no evidence, so
    // this pins omit through a non-explicit query, and explicit queries are covered separately by allow_explicit_unverified (the same rule as official.explicit.* in the contract).
    const query: CapabilityEvidenceQuery = {
      partitionId: 'u1',
      connectionInstanceId: 'relay-1',
      connectionGeneration: 'cg3',
      credentialEpoch: 'ce8',
      providerKind: 'relay',
      modelId: 'local-model',
      effectiveTransport: 'openai_chat_completions',
      metadataRevision: 'local-7',
      now: 1,
      hasExplicitValue: false,
    };
    const candidates: CapabilityEvidenceCandidate[] = [{
      key: 'generation_parameter/temperature',
      support: 'supported',
      source: 'relay_declaration',
      grade: 'declared',
      scope: 'connection_model_transport',
      providerKind: 'relay',
      modelId: 'local-model',
      transport: 'openai_chat_completions',
      connectionInstanceId: 'relay-1',
      connectionGeneration: 'cg3',
      credentialEpoch: 'ce8',
      metadataRevision: 'local-7',
    }];
    expect(resolveCapabilityEvidence('generation_parameter/temperature', query, candidates)).toMatchObject({
      support: 'unknown',
      source: 'none',
      requestPolicy: 'omit_unknown',
    });
    expect(resolveCapabilityEvidence('generation_parameter/temperature', {
      ...query,
      hasExplicitValue: true,
    }, candidates)).toMatchObject({
      support: 'unknown',
      source: 'none',
      requestPolicy: 'allow_explicit_unverified',
    });
  });

  it('fails closed when either side of a connection scope lacks the final endpoint fingerprint', () => {
    const query: CapabilityEvidenceQuery = {
      partitionId: 'u1', connectionInstanceId: 'relay-1', connectionGeneration: 'cg3', credentialEpoch: 'ce8',
      endpointFingerprint: 'ep-final', providerKind: 'relay', modelId: 'local-model',
      effectiveTransport: 'openai_chat_completions', now: 1, hasExplicitValue: true,
    };
    const candidate: CapabilityEvidenceCandidate = {
      key: 'tool_call', support: 'supported', source: 'relay_declaration', grade: 'declared',
      scope: 'connection_model_transport', partitionId: 'u1', connectionInstanceId: 'relay-1',
      connectionGeneration: 'cg3', credentialEpoch: 'ce8', providerKind: 'relay', modelId: 'local-model',
      transport: 'openai_chat_completions',
    };
    expect(resolveCapabilityEvidence('tool_call', query, [candidate]).support).toBe('unknown');
    expect(resolveCapabilityEvidence('tool_call', { ...query, endpointFingerprint: undefined }, [{
      ...candidate,
      endpointFingerprint: 'ep-final',
    }]).support).toBe('unknown');
  });

  it('rejects a candidate revision when the query has no matching revision', () => {
    expect(resolveCapabilityEvidence('tool_call', {
      partitionId: 'u1',
      connectionInstanceId: 'p1',
      connectionGeneration: 'cg1',
      credentialEpoch: 'ce1',
      providerKind: 'openAI',
      modelId: 'gpt-5.4',
      effectiveTransport: 'openai_chat_completions',
      now: 1,
      hasExplicitValue: false,
    }, [{
      key: 'tool_call',
      support: 'supported',
      source: 'server_typed',
      grade: 'machine_verified',
      scope: 'provider_model_transport',
      providerKind: 'openAI',
      modelId: 'gpt-5.4',
      transport: 'openai_chat_completions',
      metadataRevision: 'etag-1',
    }])).toMatchObject({
      support: 'unknown',
      source: 'none',
      requestPolicy: 'omit_unknown',
    });
  });

  it('never matches empty or literal unknown transports', () => {
    const query: CapabilityEvidenceQuery = {
      partitionId: '', connectionInstanceId: '', connectionGeneration: '', credentialEpoch: '',
      providerKind: 'openAI', modelId: 'gpt-5', effectiveTransport: 'unknown', now: 1, hasExplicitValue: false,
    };
    const candidate: CapabilityEvidenceCandidate = {
      key: 'web_search', support: 'supported', source: 'server_profile', grade: 'declared',
      scope: 'provider_model_transport', providerKind: 'openAI', modelId: 'gpt-5', transport: 'unknown',
    };
    expect(resolveCapabilityEvidence('web_search', query, [candidate]).support).toBe('unknown');
    expect(resolveCapabilityEvidence('web_search', { ...query, effectiveTransport: '' }, [{ ...candidate, transport: '' }]).support).toBe('unknown');
  });

  it('keeps a Relay raw unsupported generation declaration as an exact omission', () => {
    const candidates = generationParameterEvidenceCandidates({
      template: 'openai_chat_completions', wire: { temperature: 'temperature' },
      parameters: [{ id: 'temperature', support: 'unsupported', source: 'relay_declared' }],
    }, {
      partitionId: 'u1', providerKind: 'relay', modelId: 'local-model', effectiveTransport: 'openai_chat_completions',
      connectionInstanceId: 'relay-1', connectionGeneration: 'cg1', credentialEpoch: 'ce1', endpointFingerprint: 'ep1',
    });
    expect(candidates[0]).toMatchObject({
      support: 'unsupported', source: 'relay_declaration', scope: 'connection_model_transport',
    });
    expect(resolveCapabilityEvidence('generation_parameter/temperature', {
      partitionId: 'u1', connectionInstanceId: 'relay-1', connectionGeneration: 'cg1', credentialEpoch: 'ce1', endpointFingerprint: 'ep1',
      providerKind: 'relay', modelId: 'local-model', effectiveTransport: 'openai_chat_completions', now: 1, hasExplicitValue: true,
    }, candidates).requestPolicy).toBe('omit_unsupported');
  });

  it('shares panel editability without widening runtime request policy', () => {
    expect(isCapabilityEvidenceEditable({ support: 'supported', source: 'server_profile', grade: 'declared' })).toBe(true);
    expect(isCapabilityEvidenceEditable({ support: 'unknown', source: 'relay_declaration', grade: 'accepted_unverified' })).toBe(true);
    expect(isCapabilityEvidenceEditable({ support: 'unknown', source: 'server_profile', grade: 'declared' })).toBe(false);
  });

  it('passes the production generation parameter shape through production normalization before the facade', () => {
    const fixture = loadJSON<{
      sources: { generationProfile: { payload: { template: string; parameters: Array<Record<string, string>> } } };
    }>('shared/test-fixtures/provider-capability-evidence/production-shapes.v1.json');
    const raw = fixture.sources.generationProfile.payload;
    const metadata: RuntimeMetadataResponse = {
      version: 1,
      updatedAt: '2026-08-09T00:00:00Z',
      providers: {},
      profiles: {
        reasoning: {},
        webSearch: {},
        imageGen: {},
        generation: {
          templates: { [raw.template]: { wire: { temperature: 'temperature', top_p: 'top_p', min_p: 'min_p' } } },
          parameters: {},
        },
      },
    };
    const profile = resolveGenerationProfile(metadata, raw);
    expect(profile).toBeDefined();
    const candidates = generationParameterEvidenceCandidates(profile!, {
      partitionId: 'u1',
      providerKind: 'relay',
      modelId: 'local-model',
      effectiveTransport: 'openai_chat_completions',
      metadataRevision: 'local-7',
      connectionInstanceId: 'relay-1',
      connectionGeneration: 'cg3',
      credentialEpoch: 'ce8',
      endpointFingerprint: 'ep_fixture',
    });

    expect(candidates).toEqual(expect.arrayContaining([
      expect.objectContaining({
        key: 'generation_parameter/top_p',
        support: 'unknown',
        source: 'relay_declaration',
        grade: 'accepted_unverified',
      }),
    ]));
    expect(resolveCapabilityEvidence('generation_parameter/top_p', {
      partitionId: 'u1',
      providerKind: 'relay',
      modelId: 'local-model',
      effectiveTransport: 'openai_chat_completions',
      metadataRevision: 'local-7',
      connectionInstanceId: 'relay-1',
      connectionGeneration: 'cg3',
      credentialEpoch: 'ce8',
      endpointFingerprint: 'ep_fixture',
      now: 1,
      hasExplicitValue: true,
    }, candidates)).toMatchObject({
      support: 'unknown',
      source: 'relay_declaration',
      grade: 'accepted_unverified',
      requestPolicy: 'allow_explicit_unverified',
      reasonCode: 'user_accepted_unverified',
    });

    const acceptedRaw = {
      ...raw,
      parameters: raw.parameters.map((parameter) => parameter.id === 'top_p'
        ? { ...parameter, support: 'accepted' }
        : parameter),
    };
    const acceptedProfile = resolveGenerationProfile(metadata, acceptedRaw);
    const acceptedCandidate = generationParameterEvidenceCandidates(acceptedProfile!, {
      partitionId: 'u1',
      providerKind: 'relay',
      modelId: 'local-model',
      effectiveTransport: 'openai_chat_completions',
      metadataRevision: 'local-7',
      connectionInstanceId: 'relay-1',
      connectionGeneration: 'cg3',
      credentialEpoch: 'ce8',
      endpointFingerprint: 'ep_fixture',
    }).find((candidate) => candidate.key === 'generation_parameter/top_p');
    expect(acceptedCandidate).toMatchObject({
      support: 'unknown',
      source: 'relay_declaration',
      grade: 'accepted_unverified',
    });
  });

  it('preserves an opaque generation profile revision through runtime normalization', () => {
    const metadata: RuntimeMetadataResponse = {
      version: 1,
      updatedAt: '2026-08-09T00:00:00Z',
      providers: {},
      profiles: {
        reasoning: {}, webSearch: {}, imageGen: {},
        generation: {
          templates: { openai_chat_completions: { wire: { temperature: 'temperature' } } },
          parameters: { temperature: { valueSchema: 'number' } },
        },
      },
    };
    expect(resolveGenerationProfile(metadata, {
      template: 'openai_chat_completions', revision: 'generation-r17',
      parameters: [{ id: 'temperature', support: 'supported' }],
    })?.revision).toBe('generation-r17');
  });
});

function loadJSON<T>(relativePath: string): T {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, relativePath);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${relativePath} not found`);
    current = parent;
  }
}
