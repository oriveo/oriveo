import 'fake-indexeddb/auto';
// @vitest-environment jsdom
//
// Regression for the relay unsupported-parameter path: how many outbound legs one message
// produces, and whether a rejected user setting survives.
//
// The contract is that one message sends exactly one leg. A rejected user setting stays in the
// body verbatim and the 400 surfaces as a user-visible error. Recovery goes through the explicit
// resend descriptor in `capability-recovery-runtime` (a structured locator plus user
// confirmation) and never infers a parameter name from the response body. Two rules in the
// production code say so directly:
//   - `packages/core/src/providers/unsupported-param.ts`
//     "never pre-strip a user setting from a prior opaque/body-text inference."
//   - `packages/core/src/providers/relay-stream.ts`
//     "a rejected reasoning setting is user-visible recovery state. Never silently
//      rewrite xhigh to high and dispatch a second request."
// Accordingly `markUnsupportedParamDropped` / `stripKnownUnsupportedParams` have no call sites on
// the production path, and no request path writes the negative cache.
//
// The test drives the whole production chain instead of hand-building StreamOptions or scopes:
//   the production identity store, beginCapabilityEvidenceIdentityIfAbsent
//     -> the production metadata client (with ETag = metadataRevision)
//     -> production assembly, buildStreamOptionsFromIntent -> buildProviderStreamOptions, which
//        is where identity is injected
//     -> the production relay sender, sendRelayStream, where core fills in the transport and
//        endpoint fingerprint from the real request
//   Assertions look only at the final body captured by the transport and at the events the
//   production stream actually emits.

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { sendRelayStream, type RelayOrchestratorDeps } from '@oriveo/core/providers/relay-orchestrator';
import type { StreamEvent } from '@oriveo/core/providers/types';
import { resetUnsupportedParamCacheForTesting } from '@oriveo/core/providers/unsupported-param';
import { locateCapabilityRecovery } from '../capability-recovery-runtime';
import {
  __seedMetadataCacheForTest,
  __resetMetadataClientForTest,
  initMetadata,
} from '../../metadata/metadata-client';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../stream-options';

const METADATA_FIXTURE = {
  version: 1,
  contractVersion: 1,
  updatedAt: '2026-08-10T00:00:00Z',
  profiles: {
    reasoning: {},
    webSearch: {},
    imageGen: {},
    generation: {
      parameters: {
        temperature: { group: 'sampling', valueSchema: 'number', portability: 'portable' },
      },
      templates: {
        openai_chat_completions: {
          transport: 'openai_chat_completions',
          wire: { temperature: 'temperature' },
        },
      },
    },
  },
  providers: {},
  providerConfigs: [],
};

const PROVIDER = {
  id: 'relay-h5',
  kind: 'relay',
  status: { kind: 'connected' },
  models: [],
  catalogModels: [],
  apiKey: 'sk-relay',
  apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
} as Provider;

const MODEL = {
  id: 'my-private-model',
  name: 'my-private-model',
  capabilities: ['text'],
  reasoningModeAvailable: false,
  isAvailable: true,
  isDefault: false,
  priceTier: '',
} as AIModel;

/** Upstream: the first request answers 400 "temperature not supported", everything after that is 200. */
function rejectTemperatureOnce(bodies: Record<string, unknown>[]): RelayOrchestratorDeps {
  return {
    transport: {
      fetch: async (_url, init) => {
        bodies.push(JSON.parse(String(init.body)) as Record<string, unknown>);
        return bodies.length === 1
          ? new Response('does not support parameter temperature', { status: 400 })
          : new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), { status: 200 });
      },
    },
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
}

/** Production StreamOptions, identity injection included, feeding the production relay send path. */
function productionStreamOptions() {
  return buildProviderStreamOptions(
    PROVIDER,
    buildStreamOptionsFromIntent(MODEL, 'automatic', false, {
      temperature: { state: 'value', value: 0.25 },
    }),
    MODEL,
  );
}

/** Drain the production stream and return the events it really emitted; whether the 400 is user-visible can only be seen here. */
async function sendOnce(
  deps: RelayOrchestratorDeps,
  options: ReturnType<typeof buildProviderStreamOptions>,
): Promise<StreamEvent[]> {
  const handle = sendRelayStream(
    PROVIDER.apiKey,
    MODEL.id,
    [{ role: 'user', content: 'hello' }],
    PROVIDER.baseURLText,
    { ...options, relayStream: false },
    deps,
  );
  const events: StreamEvent[] = [];
  const reader = handle.stream.getReader();
  for (;;) {
    const next = await reader.read();
    if (next.done) break;
    events.push(next.value);
  }
  return events;
}

async function primeMetadata(etag: string | null): Promise<void> {
  __resetMetadataClientForTest();
  // The ETag lives in the same blob as the snapshot (see MetadataBlob in metadata-client) rather than under its own storage key
  await __seedMetadataCacheForTest({ data: METADATA_FIXTURE, timestamp: Date.now(), etag });
  await initMetadata();
}

describe('relay unsupported-param recovery: observations carry across requests only with a complete connection identity', () => {
  beforeEach(async () => {
    localStorage.clear();
    resetUnsupportedParamCacheForTesting();
    resetCapabilityEvidenceIdentitiesForTesting();
    await primeMetadata('W/"metadata-h5"');
  });

  afterEach(() => {
    __resetMetadataClientForTest();
    resetUnsupportedParamCacheForTesting();
    resetCapabilityEvidenceIdentitiesForTesting();
    localStorage.clear();
  });

  it('buildProviderStreamOptions injects the full connection identity (all 6 fields non-empty)', () => {
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), PROVIDER.id);

    const identity = productionStreamOptions()?.capabilityIdentity;

    expect(identity).toBeDefined();
    expect(Object.entries(identity ?? {}).filter(([, value]) => !value)).toEqual([]);
    expect(identity).toMatchObject({
      partitionId: getActiveUIDSync(),
      connectionInstanceId: PROVIDER.id,
      metadataRevision: 'W/"metadata-h5"',
    });
    // generationRevision falls back to the metadata ETag; a relay local template profile has no revision of its own.
    expect(identity?.generationRevision).toBe('W/"metadata-h5"');
    expect(identity?.connectionGeneration).not.toBe(identity?.credentialEpoch);
  });

  // A complete identity does not add a "silently strip and resend" leg: the rejected user setting
  // stays in the body, the 400 surfaces as-is, and recovery happens only when the user confirms
  // an explicit resend descriptor.
  it('sends a single leg even with a complete identity: a rejected user setting is not silently stripped and resent', async () => {
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), PROVIDER.id);
    const bodies: Record<string, unknown>[] = [];
    const deps = rejectTemperatureOnce(bodies);
    const options = productionStreamOptions();

    expect(options?.capabilityIdentity).toBeDefined();
    const first = await sendOnce(deps, options);
    const second = await sendOnce(deps, options);

    // Two messages, two legs. There is no intermediate leg retrying without temperature.
    expect(bodies).toHaveLength(2);
    // A temperature the user set explicitly is neither pre-stripped nor rewritten by a retry (see unsupported-param.ts).
    expect(bodies.map((body) => body.temperature)).toEqual([0.25, 0.25]);
    // The rejection is user-visible recovery state: the 400 comes through as the only error event, not swallowed by a silent retry.
    expect(first.filter((event) => event.type === 'error')).toEqual([
      expect.objectContaining({ type: 'error', status: 400 }),
    ]);
    expect(second.some((event) => event.type === 'error')).toBe(false);
  });

  it('does not scan the error body for parameter names: a prose-only 400 yields no explicit resend descriptor', () => {
    // An explicit resend only accepts a structured locator (custom via /error/param, recipe via
    // errorRecovery locatorRules). The upstream sentence "does not support parameter temperature"
    // is a body-text inference, exactly the kind of signal that must not drive parameter
    // stripping, so the only outcome is surface_error.
    expect(locateCapabilityRecovery({
      status: 400,
      preToken: true,
      streamStarted: false,
      sideEffects: false,
      automaticRetryCount: 0,
      source: 'custom',
      structuredError: { error: { message: 'does not support parameter temperature' } },
      customAppliedPointers: { generation: ['/temperature'] },
    }, {})).toBeNull();
  });

  it('outbound is unchanged without a local identity entry: still one leg per message, parameters untouched', async () => {
    const bodies: Record<string, unknown>[] = [];
    const deps = rejectTemperatureOnce(bodies);
    const options = productionStreamOptions();

    expect(options?.capabilityIdentity).toBeUndefined();
    await sendOnce(deps, options);
    await sendOnce(deps, options);

    // The legacy negative cache has no production call sites, so whether the identity is complete
    // does not change the outbound leg count or the parameters - the expectation is identical to
    // the complete-identity case above.
    expect(bodies).toHaveLength(2);
    expect(bodies.map((body) => body.temperature)).toEqual([0.25, 0.25]);
  });

  it('outbound is unchanged when metadata carries no ETag, so the revision is unobservable', async () => {
    await primeMetadata(null);
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), PROVIDER.id);
    const bodies: Record<string, unknown>[] = [];
    const deps = rejectTemperatureOnce(bodies);
    const options = productionStreamOptions();

    expect(options?.capabilityIdentity).toBeUndefined();
    await sendOnce(deps, options);
    await sendOnce(deps, options);

    expect(bodies).toHaveLength(2);
    expect(bodies.map((body) => body.temperature)).toEqual([0.25, 0.25]);
  });
});
