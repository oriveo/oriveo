/** MiniMax official Server-side Tools Beta alternate route.
 *
 * The selected server recipe owns every route/security field. This builder never infers support
 * from a MiniMax model id; without the exact decoded route the dispatcher keeps the normal
 * OpenAI-compatible MiniMax request.
 */
import { resolveAnthropicMaxTokens } from '../protocol-implementations';
import { resolveProviderBaseURL } from '../url-utils';
import { credentialHeader } from './generation-parameters';
import { buildAnthropicRequestPayload } from './runtime';
import { attachmentTransportProfile } from '../attachment-transport';
import type { MiniMaxAnthropicMessagesRoute } from './capability-execution';
import type { ProviderRequest, RequestParams } from './types';

export function buildMiniMaxAnthropicMessagesRequest(
  params: RequestParams,
  route: MiniMaxAnthropicMessagesRoute,
  maxOutputTokens?: number,
): ProviderRequest {
  // Images go out as Anthropic Messages image blocks; when the model does not accept images the outbound sanitizer has already replaced them with a placeholder line.
  const payload = buildAnthropicRequestPayload(
    params.messages,
    attachmentTransportProfile('minimax_anthropic_messages').videoPlaceholderText,
  );
  const body: Record<string, unknown> = {
    model: params.modelID,
    // Explicit value > the model maxOutputTokens (dispatch synthesizes one input); only if neither exists is the protocol default used.
    max_tokens: resolveAnthropicMaxTokens(maxOutputTokens),
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
