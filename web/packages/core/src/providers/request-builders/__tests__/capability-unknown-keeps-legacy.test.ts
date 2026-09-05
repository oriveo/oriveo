/** R3: exact Server recipe is the sole source of automatic request fields. */
import { describe, expect, it } from 'vitest';

import { buildProviderRequest } from '../dispatch';
import type { RuntimeMetadataResponse } from '../runtime';

type ControlState = 'auto_available' | 'unavailable' | 'unknown';

function metadataWithControlState(state: ControlState | 'absent'): RuntimeMetadataResponse {
  const control = state === 'unknown'
    ? { state: 'unknown', reasonCode: 'official_source_insufficient', sourceRefs: ['src.official'] }
    : state === 'unavailable'
      ? { state: 'unavailable', reasonCode: 'model_capability_absent', sourceRefs: ['src.official'] }
      : { state: 'auto_available', recipeRef: 'fixture.web.v1' };
  return {
    version: 2,
    updatedAt: '2026-08-13T00:00:00Z',
    profiles: {
      reasoning: {
        legacy_reasoning: { levels: ['deep'], params: { deep: { reasoning_effort: 'high' } } },
      },
      webSearch: {
        legacy_web: { mergeParams: { tools: [{ type: 'web_search_preview' }] } },
      },
      imageGen: {},
    },
    capabilityRuntime: {
      schemaVersion: 2,
      revision: 'fixture-revision',
      generatedAt: '2026-08-13T00:00:00Z',
      recipes: {
        'fixture.web.v1': {
          id: 'fixture.web.v1',
          providerKind: 'qwen',
          transport: { protocol: 'openai_chat_completions' },
          capability: 'web',
          executionKind: 'request_overlay',
          requestOps: [{ op: 'set', pointer: '/enable_search', value: true }],
        },
      },
      controlDefinitions: {},
      sourceIndex: { 'src.official': { url: 'https://example.invalid/doc' } },
    },
    providers: {
      qwen: {
        resolveMap: { 'qwen3-max': 'qwen3-max' },
        models: {
          'qwen3-max': {
            transport: 'openai_chat_completions',
            profiles: { webSearch: 'legacy_web', reasoning: 'legacy_reasoning' },
            ...(state === 'absent' ? {} : { capabilityControls: { web: control, reasoning: control } }),
          },
        },
      },
    },
  } as unknown as RuntimeMetadataResponse;
}

async function requestWith(state: ControlState | 'absent') {
  return buildProviderRequest({
    providerKind: 'qwen',
    apiKey: 'fixture-api-key',
    modelID: 'qwen3-max',
    messages: [{ role: 'user', content: 'hello' }],
    // Same shape as production: buildStreamOptionsFromIntent carries both the typed intent and supportsWebSearch.
    options: {
      capabilityPreferences: { web: 'automatic', reasoningIntent: 'deep' },
      reasoning: 'deep',
      supportsWebSearch: true,
    },
  }, async () => metadataWithControlState(state));
}

describe('R3 - unknown/missing controls never revive legacy profiles', () => {
  it('unknown: emits no automatic web or reasoning fields and keeps plain chat valid', async () => {
    const request = await requestWith('unknown');
    expect(request.body.tools).toBeUndefined();
    expect(request.body.reasoning_effort).toBeUndefined();
    expect(request.body).toMatchObject({ model: 'qwen3-max', messages: [{ role: 'user', content: 'hello' }] });
  });

  it('missing control: emits no automatic fields and keeps plain chat valid', async () => {
    const request = await requestWith('absent');
    expect(request.body.tools).toBeUndefined();
    expect(request.body.reasoning_effort).toBeUndefined();
    expect(request.body).toMatchObject({ model: 'qwen3-max', messages: [{ role: 'user', content: 'hello' }] });
  });

  it('unavailable: an explicit server verdict or kill switch, where not one legacy field may come back', async () => {
    const request = await requestWith('unavailable');
    expect(request.body.tools).toBeUndefined();
    expect(request.body.reasoning_effort).toBeUndefined();
  });

  it('auto_available: follows the v2 recipe with no legacy fields layered on top', async () => {
    const request = await requestWith('auto_available');
    expect(request.body.enable_search).toBe(true);
    expect(request.body.tools).toBeUndefined();
    expect(request.body.reasoning_effort).toBeUndefined();
  });
});
