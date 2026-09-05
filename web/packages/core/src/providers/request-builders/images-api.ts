// The single request builder for the standard OpenAI Images API.
import type { ProviderKind } from '@oriveo/shared/pure-types';

import { resolveProviderBaseURL } from '../url-utils';
import type { RuntimeImageGenProfile } from './runtime';
import { extractLatestUserPrompt } from './response-utils';
import { JSON_HEADERS, type ProviderRequest, type RequestParams } from './types';

const PASSTHROUGH_IMAGE_URL_PROVIDERS = new Set<ProviderKind>([
  'openAI',
  'grok',
  'zhipu',
]);

/**
 * The request wire for `route=images_api` is identical across every official provider.
 * requestDefaults is the only source of parameters; size, n and response_format are never added here.
 */
export function buildOpenAIImagesRequest(
  params: RequestParams,
  imageGenProfile: RuntimeImageGenProfile,
): ProviderRequest {
  const prompt = extractLatestUserPrompt(params.messages);
  if (!prompt) {
    throw new Error('Image generation requires a text prompt');
  }

  return {
    url: `${resolveProviderBaseURL(params.providerKind, params.baseURL)}/images/generations`,
    headers: {
      ...JSON_HEADERS,
      Authorization: `Bearer ${params.apiKey}`,
    },
    body: {
      ...imageGenProfile.requestDefaults,
      model: params.modelID,
      prompt,
    },
    // OpenAI/Grok/Zhipu allow the upstream URL to pass through unchanged, while signed URLs from
    // Together/SiliconFlow expire and have to be downloaded first. A provider not listed here
    // defaults to the safer download strategy.
    responseAdapter: PASSTHROUGH_IMAGE_URL_PROVIDERS.has(params.providerKind)
      ? 'openai_images_api'
      : 'siliconflow_images_api',
  };
}
