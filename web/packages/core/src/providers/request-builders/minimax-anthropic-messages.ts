/** MiniMax official Server-side Tools Beta alternate route.
 *
 * The selected server recipe owns every route/security field. This builder never infers support
 * from a MiniMax model id; without the exact decoded route the dispatcher keeps the normal
 * OpenAI-compatible MiniMax request.
 */
import { resolveProviderBaseURL } from '../url-utils';
import { credentialHeader } from './generation-parameters';
import { buildAnthropicRequestPayload } from './runtime';
import type { MiniMaxAnthropicMessagesRoute } from './capability-execution';
import type { ProviderRequest, RequestParams } from './types';

export function buildMiniMaxAnthropicMessagesRequest(
  params: RequestParams,
  route: MiniMaxAnthropicMessagesRoute,
  maxOutputTokens?: number,
): ProviderRequest {
  const payload = buildAnthropicRequestPayload(params.messages);
  const body: Record<string, unknown> = {
    model: params.modelID,
    max_tokens: typeof maxOutputTokens === 'number'
      && Number.isFinite(maxOutputTokens)
      && maxOutputTokens > 0
      ? maxOutputTokens
      : 8192,
    stream: params.stream !== false,
    messages: payload.messages,
  };
  if (payload.systemText) body.system = payload.systemText;

  const baseURL = resolveProviderBaseURL(params.providerKind, params.baseURL);
  return {
    url: new URL(route.path, `${baseURL.replace(/\/+$/, '')}/`).toString(),
    headers: {
      ...route.headers,
      ...credentialHeader(route.authHeader, params.apiKey),
    },
    body,
  };
}
