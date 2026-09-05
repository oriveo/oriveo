/**
 * Codex (ChatGPT subscription sign-in) adapter for the chat streaming route.
 *
 * Its shape is **completely different** from the Grok subscription path, so do not copy
 * that one: Grok only swaps the URL and headers of a request already built in API key
 * mode (still `/chat/completions`), whereas Codex uses `/responses` and its body carries
 * six hard constraints. The whole request is therefore **built here from scratch**,
 * without going through `buildProviderRequest`, which is keyed on models from the
 * metadata catalog (capability recipes, previous_response_id, 400 self-healing,
 * chat-completions fallback). Subscription models are not in the catalog, so forcing them
 * through it only drags in behavior unrelated to this path.
 *
 * It lives in its own file rather than in `route.ts` because a Next.js route module may
 * export only the conventional members, and one extra helper export fails the build.
 */
import {
  buildCodexResponsesBody,
  resolveOpenAISubscriptionAuth,
  type OpenAISubscriptionAuthConfig,
} from '@oriveo/core/providers/openai-subscription';
import { buildOpenAIResponsesInput } from '@oriveo/core/providers/request-builders/runtime';
import type { ProviderRequest, RequestParams } from '@oriveo/core/providers/request-builders/types';
import { getRuntimeMetadata } from './runtime';

/**
 * Subscription config comes only from `subscriptionAuth` in the server-side metadata,
 * including the https and host allowlist. When it cannot be read this returns null and
 * the caller responds 503; it **never falls back to the API key mode default endpoint**,
 * because pointing a subscription token at api.openai.com gives the user an error that
 * has nothing to do with the real cause.
 */
export async function resolveOpenAISubscriptionConfig(): Promise<OpenAISubscriptionAuthConfig | null> {
  const metadata = await getRuntimeMetadata();
  const raw = metadata?.providerConfigs?.find((config) => config.kind === 'openAI')
    ?.protocolFeatures?.subscriptionAuth;
  const availability = resolveOpenAISubscriptionAuth(raw, { platform: 'web' });
  return availability.state === 'available' ? availability.config : null;
}

/**
 * Builds one outbound Codex `/responses` request.
 *
 * The system prompt is **lifted out** of messages into `instructions`: one of Codex's
 * hard constraints is that system content travels only in instructions, and leaving it
 * in input both wastes a context slot and does not match the observed wire shape.
 */
export function buildCodexSubscriptionRequest(
  params: Pick<RequestParams, 'modelID' | 'messages' | 'apiKey' | 'options'>,
  config: OpenAISubscriptionAuthConfig,
): ProviderRequest {
  const systemPrompt = params.messages
    .filter((message) => message.role === 'system')
    .map((message) =>
      typeof message.content === 'string'
        ? message.content
        : message.content
          .map((part) => (part.type === 'text' ? part.text : ''))
          .filter(Boolean)
          .join('\n'),
    )
    .filter((text) => text.trim().length > 0)
    .join('\n\n');
  const conversation = params.messages.filter((message) => message.role !== 'system');

  const accountID = params.options?.openAISubscriptionAccountID?.trim() ?? '';

  const body = buildCodexResponsesBody({
    modelID: params.modelID,
    input: buildOpenAIResponsesInput(conversation),
    ...(systemPrompt ? { systemPrompt } : {}),
    // Web search = user intent AND upstream declaration, two independent conditions (see
    // `buildCodexResponsesBody`): `supportsWebSearch` is the user's intent for this turn,
    // and `openAISubscriptionWebSearchDeclared` is what the upstream `/models` declares
    // for this model. Collapsing them into one boolean loses the difference between
    // "the user did not turn it on" and "the upstream does not support it", which are two
    // very different things to tell the user.
    webSearchRequested: params.options?.supportsWebSearch === true,
    webSearchDeclared: params.options?.openAISubscriptionWebSearchDeclared === true,
    ...(params.options?.reasoning ? { reasoningMode: params.options.reasoning } : {}),
    ...(params.options?.upstreamReasoningLevels
      ? { declaredReasoningLevels: params.options.upstreamReasoningLevels }
      : {}),
  });

  return {
    url: config.responsesURL,
    headers: {
      Authorization: `Bearer ${params.apiKey}`,
      'Content-Type': 'application/json',
      Accept: 'text/event-stream',
      // Per-user identity, required on every outbound request. The client passes in the
      // value it parsed at authorization time; it is **not re-derived from the access
      // token** here, since the claim lives in the id_token and the access token is not guaranteed to carry it.
      ...(accountID ? { 'chatgpt-account-id': accountID } : {}),
      // originator / version / OpenAI-Beta: required headers; /responses may reject the request if one is missing.
      ...config.requiredHeaders,
    },
    body,
    // No fallback: the Codex backend only offers responses, and falling back to
    // chat/completions just yields another 404 with a more confusing message.
  };
}
