/** Gemini Interactions API builder.
 *
 * This is deliberately separate from generateContent: the route is selected only by a
 * server recipe with `route.protocol=gemini_interactions`, never by a local model-name
 * list. `input` accepts Gemini Content[] and therefore retains multimodal parts/roles.
 */
import { resolveProviderBaseURL } from '../url-utils';
import { buildGeminiRequestPayload } from './runtime';
import { credentialHeader } from './generation-parameters';
import { STREAM_HEADERS, JSON_HEADERS, type ProviderRequest, type RequestParams } from './types';
import type { EndpointRouteRecipe } from './capability-execution';

export function buildGeminiInteractionsRequest(
  params: RequestParams,
  route: EndpointRouteRecipe,
): ProviderRequest {
  const payload = buildGeminiRequestPayload(params.messages);
  const stream = params.stream !== false;
  const body: Record<string, unknown> = {
    model: params.modelID,
    input: payload.contents,
    stream,
  };
  const systemInstruction = payload.systemInstruction?.parts?.[0]?.text;
  if (typeof systemInstruction === 'string' && systemInstruction) body.system_instruction = systemInstruction;
  // The dispatcher owns continuation mapping because it has the selected full recipe;
  // this builder deliberately receives no opaque state or guessed field names.

  return {
    // Existing Gemini default base already carries /v1beta for generateContent; the
    // route recipe carries its own canonical versioned path, so remove it once.
    url: `${resolveProviderBaseURL(params.providerKind, params.baseURL).replace(/\/v1(?:beta)?$/i, '')}${route.path}`,
    headers: {
      ...(stream ? STREAM_HEADERS : JSON_HEADERS),
      ...credentialHeader('x-goog-api-key', params.apiKey),
    },
    body,
    responseAdapter: 'gemini_interactions',
  };
}
