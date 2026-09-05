import { describe, expect, it } from 'vitest';

import { buildProviderRequest } from '../dispatch';
import {
  normalizeReasoningMode,
  resolveReasoningParams,
  resolveSupportedReasoningModes,
  type RuntimeMetadataResponse,
} from '../runtime';
import type { RequestParams } from '../types';

/**
 * The set of levels shown to the user must match the set that is actually injected.
 *
 * The failure mode: a model references a profile name that the profile table does not contain
 * (withdrawn server-side, or an old client snapshot). `resolveReasoningParams` then returns null
 * and injects nothing, so if the display side fails open to all 5 levels the user sees 5 choices
 * that all send an identical request with no parameters at all.
 *
 * The one place failing open is correct is relay: /api/metadata.providers has no relay key, so a
 * relay model never resolves a profile and its levels come from the local
 * buildRelayReasoningParams mapping instead.
 */

const metadata: RuntimeMetadataResponse = {
  version: 1,
  updatedAt: '2026-08-07T00:00:00Z',
  profiles: {
    reasoning: {
      // A narrowed level set in practice: gpt-5-pro only accepts effort=high, so levels keeps only deep.
      oai_responses_pro: {
        transport: 'responses_api',
        levels: ['deep'],
        params: { deep: { reasoning: { effort: 'high' } } },
      },
      oai_responses: {
        transport: 'responses_api',
        levels: ['fast', 'balanced', 'deep', 'max'],
        params: {
          fast: { reasoning: { effort: 'low' } },
          balanced: { reasoning: { effort: 'medium' } },
          deep: { reasoning: { effort: 'high' } },
          max: { reasoning: { effort: 'high' } },
        },
      },
      oai_chat: {
        transport: 'chat_completions',
        levels: ['fast', 'balanced', 'deep'],
        params: {
          fast: { reasoning_effort: 'low' },
          balanced: { reasoning_effort: 'medium' },
          deep: { reasoning_effort: 'high' },
        },
      },
    },
    webSearch: {},
    imageGen: {},
  },
  providers: {
    openAI: {
      transport: { baseUrl: 'https://api.openai.com/v1', endpoints: { chat: '/chat/completions', responses: '/responses' } },
      resolveMap: { 'gpt-5-pro': 'gpt-5-pro', 'ghost-model': 'ghost-model' },
      models: {
        'gpt-5-pro': { profiles: { reasoning: 'oai_responses_pro' } },
        // The profile name points at a profile that was withdrawn or is missing from the local snapshot.
        'ghost-model': { profiles: { reasoning: 'oai_responses_withdrawn' } },
      },
    },
  },
};

const aggregateMetadata: RuntimeMetadataResponse = {
  ...metadata,
  providers: {
    ...metadata.providers,
    groq: {
      resolveMap: {
        'openai/gpt-oss-120b': 'openai/gpt-oss-120b',
        'openai/future-reasoner-6': 'openai/future-reasoner-6',
      },
      models: {
        'openai/gpt-oss-120b': { profiles: { reasoning: 'oai_chat' } },
        // supported_parameters may still declare reasoning_effort while the server sends no profile.
        'openai/future-reasoner-6': { profiles: { reasoning: null } },
      },
    },
  },
};

describe('resolveSupportedReasoningModes', () => {
  it('hides every level when the profile name resolves to nothing', () => {
    expect(resolveSupportedReasoningModes(metadata, 'oai_responses_withdrawn')).toEqual(['automatic']);
  });

  it('hides every level when the profile declares no levels', () => {
    const noLevels: RuntimeMetadataResponse = {
      ...metadata,
      profiles: {
        ...metadata.profiles,
        reasoning: { bare: { params: { deep: { reasoning: { effort: 'high' } } } } },
      },
    };
    expect(resolveSupportedReasoningModes(noLevels, 'bare')).toEqual(['automatic']);
  });

  it('exposes exactly the narrowed levels the server declares', () => {
    expect(resolveSupportedReasoningModes(metadata, 'oai_responses_pro')).toEqual(['automatic', 'deep']);
  });

  it('keeps every level for relay, which never resolves a catalog profile', () => {
    // Relay is the exception: the missing-profileName branch must not narrow, or the local relay mapping gets clamped to automatic.
    expect(resolveSupportedReasoningModes(metadata, undefined)).toEqual([
      'automatic', 'fast', 'balanced', 'deep', 'max',
    ]);
  });

  it('clamps a requested level down to automatic when the profile is unknown', () => {
    expect(normalizeReasoningMode(metadata, 'oai_responses_withdrawn', 'deep')).toBe('automatic');
  });

  it('keeps the display face aligned with the zero-injection face', () => {
    // The same unknown profile: the display side keeps only automatic and injection returns null. Matching on both sides is what stops the levels from being decorative.
    expect(resolveReasoningParams(metadata, 'oai_responses_withdrawn', 'deep')).toBeNull();
  });
});

describe('reasoning levels through the production request builder', () => {
  it('relay still injects its local reasoning mapping', async () => {
    const request = await buildProviderRequest(
      {
        providerKind: 'relay',
        apiKey: 'test-key',
        modelID: 'gpt-5-pro',
        baseURL: 'https://relay.example/v1',
        messages: [{ role: 'user', content: 'hi' }],
        options: { reasoning: 'deep' },
      } satisfies RequestParams,
      async () => metadata,
    );

    expect(request.body).toMatchObject({ reasoning_effort: 'high' });
  });

  it('an official model with a withdrawn profile ships no reasoning parameter', async () => {
    const request = await buildProviderRequest(
      {
        providerKind: 'openAI',
        apiKey: 'test-key',
        modelID: 'ghost-model',
        messages: [{ role: 'user', content: 'hi' }],
        options: { reasoning: 'deep' },
      } satisfies RequestParams,
      async () => metadata,
    );

    expect(request.body).not.toHaveProperty('reasoning');
    expect(request.body).not.toHaveProperty('reasoning_effort');
  });

  it('an official provider injects nothing when the server delivered no capability runtime', async () => {
    // Automatic configuration for official providers comes only from the capabilityRuntime sent by
    // the server; with no runtime a client injects nothing rather than falling back to a legacy
    // profile (`emptyPlan()` marks the web, reasoning and generation owners as overridesLegacy).
    // Known gap, deliberately recorded rather than ignored: in this same state the display side
    // `resolveSupportedReasoningModes` still returns ['automatic','deep'] (see the case above), so
    // on the no-runtime path the display and injection sides do not agree. Production always sends
    // a runtime, which makes it unreachable; closing it properly means teaching the display side
    // about the runtime, not restoring legacy injection.
    const request = await buildProviderRequest(
      {
        providerKind: 'openAI',
        apiKey: 'test-key',
        modelID: 'gpt-5-pro',
        messages: [{ role: 'user', content: 'hi' }],
        options: { reasoning: 'deep' },
      } satisfies RequestParams,
      async () => metadata,
    );

    expect(request.capabilityExecution).toBeUndefined();
    expect(JSON.stringify(request.body)).not.toMatch(/reasoning/);
  });

  it('an unknown aggregate model ships no reasoning parameter even when the upstream declares it', async () => {
    const request = await buildProviderRequest(
      {
        providerKind: 'groq',
        apiKey: 'test-key',
        modelID: 'openai/future-reasoner-6',
        messages: [{ role: 'user', content: 'hi' }],
        options: { reasoning: 'deep' },
      } satisfies RequestParams,
      async () => aggregateMetadata,
    );

    expect(request.body).not.toHaveProperty('reasoning');
    expect(request.body).not.toHaveProperty('reasoning_effort');
  });

  it('an aggregate model also injects nothing without a capability runtime', async () => {
    // As above: groq is an official provider too, so no runtime means no automatic configuration.
    // The boundary with relay is exactly what this file protects: relay levels come from the local
    // mapping (the previous case still passes), while official provider levels can only come from
    // the server.
    const request = await buildProviderRequest(
      {
        providerKind: 'groq',
        apiKey: 'test-key',
        modelID: 'openai/gpt-oss-120b',
        messages: [{ role: 'user', content: 'hi' }],
        options: { reasoning: 'deep' },
      } satisfies RequestParams,
      async () => aggregateMetadata,
    );

    expect(request.capabilityExecution).toBeUndefined();
    expect(JSON.stringify(request.body)).not.toMatch(/reasoning_effort/);
  });
});
