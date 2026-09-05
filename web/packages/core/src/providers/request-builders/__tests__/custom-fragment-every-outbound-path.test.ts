/**
 * Compiling custom request fields is a precondition of every outbound path, not a local step in
 * the chat branch.
 *
 * The exposure: `images_api` returns before `applyRecipes`, so the custom fields a user
 * configured are silently dropped for image generation models. The request still goes out, while
 * the edit page states in red that messages using that control will fail to send. A fail-closed
 * rule that only holds for some protocols is not fail-closed, it is a promise that applies at
 * random.
 */
import { describe, expect, it } from 'vitest';
import { buildProviderRequest } from '../dispatch';
import type { RuntimeMetadataResponse } from '../runtime';
import type { RequestParams } from '../types';

const MODEL_ID = 'gpt-image-custom';
const DEFINITION_REF = 'oai_images_quality_v1';

describe('the images_api path also runs the custom field compiler', () => {
  it('writes a declared leaf into the outbound body', async () => {
    const request = await buildProviderRequest(
      imageParams({ customFragments: { generation: { raw: '{"quality":"high"}' } } }),
      async () => imageMetadata(),
    );

    expect(request.url.endsWith('/images/generations'), request.url).toBe(true);
    expect((request.body as Record<string, unknown>).quality).toBe('high');
    // The facts layer has to record this customization as well, or the message metadata gives no
    // sign that the request was rewritten.
    expect(request.capabilityExecution?.customOwners).toEqual(['generation']);
    expect(request.capabilityExecution?.customAppliedPointers).toEqual({ generation: ['/quality'] });
  });

  it('fails closed on an undeclared path: the request is not sent rather than downgraded', async () => {
    await expect(buildProviderRequest(
      imageParams({ customFragments: { generation: { raw: '{"not_declared":1}' } } }),
      async () => imageMetadata(),
    )).rejects.toThrow('Safe custom fragment rejected: unknown_owned_path');
  });

  it('fails closed when a custom field is selected but empty, the same as the chat branch', async () => {
    await expect(buildProviderRequest(
      imageParams({ customFragments: { generation: { raw: '   ' } } }),
      async () => imageMetadata(),
    )).rejects.toThrow(/Safe custom fragment rejected/);
  });

  it('leaves the path byte-identical when there are no custom fields, without attaching capabilityExecution', async () => {
    const request = await buildProviderRequest(imageParams({}), async () => imageMetadata());
    expect(request.capabilityExecution).toBeUndefined();
    expect((request.body as Record<string, unknown>).quality).toBeUndefined();
  });
});

function imageParams(options: Record<string, unknown>): RequestParams {
  return {
    providerKind: 'openAI',
    apiKey: 'test-key',
    modelID: MODEL_ID,
    messages: [{ role: 'user', content: 'draw a cube' }],
    options: { supportsImageGen: true, ...options },
  } satisfies RequestParams;
}

function imageMetadata(): RuntimeMetadataResponse {
  return {
    version: 1001,
    updatedAt: '2026-08-16T00:00:00Z',
    profiles: {
      reasoning: {},
      webSearch: {},
      imageGen: { oai_images: { route: 'images_api', requestDefaults: { size: '512x512' } } },
    },
    capabilityRuntime: {
      schemaVersion: 2,
      revision: 'fixture-images',
      generatedAt: '2026-08-16T00:00:00Z',
      recipes: {},
      controlDefinitions: {
        [DEFINITION_REF]: {
          id: DEFINITION_REF,
          owner: 'generation',
          targetPointer: '/quality',
          sourceRefs: ['oai_images_doc'],
        },
      },
      sourceIndex: {
        oai_images_doc: {
          kind: 'official_doc',
          url: 'https://platform.openai.com/docs/api-reference/images',
          reviewedAt: '2026-08-16',
          officialUpdatedAt: null,
        },
      },
    },
    providers: {
      openAI: {
        resolveMap: { [MODEL_ID]: MODEL_ID },
        models: {
          [MODEL_ID]: {
            canonicalModelId: MODEL_ID,
            capabilities: ['imageGeneration'],
            profiles: { imageGen: 'oai_images' },
            capabilityControls: {
              generation: { state: 'auto_available', customControlRefs: [DEFINITION_REF] },
            },
          },
        },
      },
    },
  } as unknown as RuntimeMetadataResponse;
}
