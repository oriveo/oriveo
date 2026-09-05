/**
 * Grok subscription chain adaptation for the chat streaming route.
 *
 * It lives in its own file rather than in `route.ts` because a Next.js route module may only export
 * the members of the route convention, and one extra helper export fails to compile.
 */
import {
  resolveGrokSubscriptionAuth,
  type GrokSubscriptionAuthConfig,
} from '@oriveo/core/providers/grok-subscription';
import { codexReasoningEffort } from '@oriveo/core/providers/openai-subscription';
import { buildOpenAIResponsesInput } from '@oriveo/core/providers/request-builders/runtime';
import type { RequestParams } from '@oriveo/core/providers/request-builders/types';
import { getRuntimeMetadata } from './runtime';

/**
 * The subscription config is read only from `subscriptionAuth` in the server-side metadata,
 * including the https and trustedAuthHosts allowlist. When it is unavailable this returns null and
 * the caller answers 503; it never falls back to the API-key mode default endpoint, because sending
 * a subscription token to api.x.ai gives the user an error unrelated to the real cause.
 */
export async function resolveGrokSubscriptionConfig(): Promise<GrokSubscriptionAuthConfig | null> {
  const metadata = await getRuntimeMetadata();
  const raw = metadata?.providerConfigs?.find((config) => config.kind === 'grok')
    ?.protocolFeatures?.subscriptionAuth;
  const availability = resolveGrokSubscriptionAuth(raw, { platform: 'web' });
  return availability.state === 'available' ? availability.config : null;
}

/**
 * Model-level `api_backend` wins, then the seed, and a missing value falls back to Responses; an
 * explicit chat declaration is preserved as is. On the Responses chain, a real `web_search` tool is
 * always attached when upstream declares `supports_backend_search`, so the proxy's agent harness
 * cannot invent fake `<web_search>` text when the tool is absent.
 */
export function resolveGrokSubscriptionTransport(
  config: GrokSubscriptionAuthConfig,
  modelBackend?: string,
): 'openai_responses' | 'openai_chat' {
  const decode = (value?: string) => {
    const normalized = value?.trim().toLowerCase();
    if (normalized === 'responses') return 'openai_responses' as const;
    if (normalized === 'chat' || normalized === 'chat_completions' || normalized === 'chat.completions') {
      return 'openai_chat' as const;
    }
    return undefined;
  };
  return decode(modelBackend) ?? decode(config.apiBackend) ?? 'openai_responses';
}

export function applyGrokSubscriptionTransport<T extends { url: string; headers: Record<string, string>; body: Record<string, unknown>; fallback?: unknown }>(
  request: T,
  config: GrokSubscriptionAuthConfig | null,
  context?: {
    mode?: string;
    declaredLevels?: readonly string[];
    defaultLevel?: string;
    apiBackend?: string;
    supportsWebSearch?: boolean;
    messages?: RequestParams['messages'];
  },
): T {
  if (!config) return request;
  const { fallback: _apiKeyModeFallback, ...rest } = request;
  const declared = context?.declaredLevels ?? [];
  const effort = context?.mode === 'automatic'
    ? (context.defaultLevel && declared.includes(context.defaultLevel) ? context.defaultLevel : undefined)
    : codexReasoningEffort(context?.mode, declared);
  if (resolveGrokSubscriptionTransport(config, context?.apiBackend) === 'openai_responses') {
    const messages = context?.messages ?? [];
    const systemPrompt = messages
      .filter((message) => message.role === 'system')
      .map((message) => typeof message.content === 'string' ? message.content : '')
      .filter(Boolean)
      .join('\n\n');
    const conversation = messages.filter((message) => message.role !== 'system');
    return {
      ...(rest as T),
      url: config.responsesURL,
      headers: { ...request.headers, ...config.requiredHeaders },
      body: {
        model: request.body.model,
        input: buildOpenAIResponsesInput(conversation),
        stream: request.body.stream !== false,
        store: false,
        ...(systemPrompt ? { instructions: systemPrompt } : {}),
        ...(context?.supportsWebSearch ? { tools: [{ type: 'web_search' }] } : {}),
        ...(effort ? { reasoning: { effort, summary: 'auto' } } : {}),
      },
    };
  }
  return {
    ...(rest as T),
    url: config.chatURL,
    headers: { ...request.headers, ...config.requiredHeaders },
    body: effort ? { ...request.body, reasoning_effort: effort } : request.body,
  };
}
