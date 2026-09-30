import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 *
 * Tool-call evidence derived from models.dev arrives as source=server_typed, grade=declared.
 * The decoder must keep it: dropping it turns supported models into "unknown" and still sends
 * tools to models that are known not to accept them.
 *
 * The payload is the shared lean contract fixture with two extra models; every assertion reads
 * what the production decoder and resolveModelCapabilityEvidence actually produce.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import type { AIModel, Provider } from '@oriveo/shared';
import { pruneBlobs } from '../../../infra/storage/blob-cache';

const OBSERVED_AT = 1_777_000_000_000;
const EXPIRES_AT = OBSERVED_AT + 7 * 24 * 60 * 60 * 1000;
// Final transport as the catalog publishes it for OpenAI chat models.
const TRANSPORT = 'openai_chat';
const SUPPORTED_ID = 'gpt-declared-tools';
const UNSUPPORTED_ID = 'gpt-declared-no-tools';

function declaredToolCall(support: 'supported' | 'unsupported', grade = 'declared') {
  return {
    key: 'tool_call',
    support,
    source: 'server_typed',
    grade,
    observedAt: OBSERVED_AT,
    expiresAt: EXPIRES_AT,
  };
}

/** Lean contract fixture plus one declared-supported and one declared-unsupported model. */
function leanPayload(grade = 'declared') {
  const contract = JSON.parse(readFileSync(
    '../../../shared/model-contracts/metadata_lean_contract.v1.json',
    'utf8',
  ));
  const payload = structuredClone(contract.leanResponse);
  const openAI = payload.data.providers.openAI;
  for (const [id, support] of [
    [SUPPORTED_ID, 'supported'],
    [UNSUPPORTED_ID, 'unsupported'],
  ] as const) {
    openAI.models[id] = {
      canonicalModelId: id,
      displayName: id,
      capabilities: ['text'],
      transport: TRANSPORT,
      capabilityEvidenceView: { candidates: [declaredToolCall(support, grade)] },
    };
    openAI.resolveMap[id] = id;
  }
  return payload;
}

async function load(payload: unknown) {
  vi.resetModules();
  vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response(JSON.stringify(payload), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ETag: '"lean-declared"' },
  }));
  const metadata = await import('../metadata-client');
  metadata.__resetMetadataClientForTest();
  await metadata.refreshMetadata();
  const evidence = await import('../../chat/capability-evidence');
  return { metadata, evidence };
}

function toolCall(
  evidence: Awaited<ReturnType<typeof load>>['evidence'],
  modelId: string,
) {
  const provider = { id: 'openai-1', kind: 'openAI', apiKey: 'k', models: [] } as unknown as Provider;
  const model = {
    id: modelId,
    name: modelId,
    capabilities: ['text'],
    transport: TRANSPORT,
  } as unknown as AIModel;
  return evidence.resolveModelCapabilityEvidence({ key: 'tool_call', provider, model });
}

describe('server_typed tool-call evidence graded declared', () => {
  beforeEach(async () => {
    vi.restoreAllMocks();
    // Pin the clock inside the evidence lifetime so freshness does not depend on today's date.
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(OBSERVED_AT + (EXPIRES_AT - OBSERVED_AT) / 2);
    await pruneBlobs('oriveo:metadata:', []);
  });

  afterEach(async () => {
    vi.useRealTimers();
    await new Promise((resolve) => setTimeout(resolve, 20));
    await pruneBlobs('oriveo:metadata:', []);
  });

  it('keeps declared candidates through lean decoding and resolves supported and unsupported', async () => {
    const { metadata, evidence } = await load(leanPayload());

    expect(metadata.resolveCatalogModel(SUPPORTED_ID, 'openAI')?.capabilityEvidenceCandidates)
      .toEqual([expect.objectContaining({
        key: 'tool_call',
        source: 'server_typed',
        grade: 'declared',
        support: 'supported',
        providerKind: 'openAI',
        modelId: SUPPORTED_ID,
        transport: TRANSPORT,
      })]);
    expect(toolCall(evidence, SUPPORTED_ID)).toMatchObject({
      support: 'supported',
      source: 'server_typed',
      grade: 'declared',
      requestPolicy: 'allow',
    });
    expect(toolCall(evidence, UNSUPPORTED_ID)).toMatchObject({
      support: 'unsupported',
      source: 'server_typed',
      grade: 'declared',
      requestPolicy: 'omit_unsupported',
    });
  });

  it('still drops server_typed candidates with a grade outside the allowlist', async () => {
    const { metadata, evidence } = await load(leanPayload('observed'));

    expect(metadata.resolveCatalogModel(SUPPORTED_ID, 'openAI')?.capabilityEvidenceCandidates)
      .toEqual([]);
    expect(toolCall(evidence, SUPPORTED_ID)).toMatchObject({ support: 'unknown', grade: 'none' });
  });
});
