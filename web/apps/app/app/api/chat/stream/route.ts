// Chat streaming API route: rate limit -> validate -> build the request for the providerKind -> execute -> adapt the upstream response.
import { NextRequest } from "next/server";
import { validateChatStreamRequest } from "./validate";
import { checkRateLimit, getClientIp, buildRateLimitHeaders } from "./rate-limit";
import { buildProviderRequest } from "./request-builders/dispatch";
import { applyToolCallWireAdapter } from '@oriveo/core/providers/request-builders/tool-call-wire-adapter';
import {
  executeProviderRequest,
  describeProviderRequestError,
} from "./request-builders/utils";
import { adaptOpenAIImagesResponse } from "./response-adapters/openai-images";
import { adaptSiliconFlowImagesResponse } from "./response-adapters/siliconflow-images";
import { adaptMiniMaxImagesResponse } from "./response-adapters/minimax-images";
import { adaptMiniMaxChatStream } from "./response-adapters/minimax-chat";
import { adaptQwenImagesResponse } from "./response-adapters/qwen-images";
import { adaptMoonshotToolLoopResponse } from "./response-adapters/moonshot-tool-loop";
import { adaptMoonshotFormulaFiberResponse, prepareMoonshotFormulaRequest } from './response-adapters/moonshot-formula-fiber-loop';
import { adaptGeminiInteractionsResponse } from './response-adapters/gemini-interactions';
import { getRuntimeMetadata } from "./runtime";
import {
  applyGrokSubscriptionTransport,
  resolveGrokSubscriptionConfig,
} from "./grok-subscription-transport";
import {
  buildCodexSubscriptionRequest,
  resolveOpenAISubscriptionConfig,
} from "./openai-subscription-transport";
import { assertUrlNotSsrf, SsrfBlockedError } from "../../_shared/ssrf-guard";
import {
  isImagePromptAllowed,
  isImageResponseAdapter,
  MODERATION_BLOCK_MESSAGE,
  MODERATION_ERROR_KIND,
} from "../../_shared/moderation";
import { extractLatestUserPrompt } from "./response-adapters/utils";
import { buildCapabilityResultContext, encodeCapabilityResultContext } from '../../../../lib/core/chat/capability-result-runtime';
// errorKind shares one constant with the client: a literal written on each side drifts silently the moment one is changed.
import { CUSTOM_FRAGMENT_ERROR_KIND } from '../../../../lib/core/chat/custom-fragment-rejection';
import { mergeExecutionResponse } from './execution-response';
import { capabilityRecoveryHeaders } from './capability-recovery-response';

export const runtime = "nodejs";

const JSON_HEADERS = {
  "Content-Type": "application/json",
  Accept: "application/json",
} as const;
const ERROR_SOURCE_HEADER = "X-Oriveo-Error-Source";
const CONTINUATION_KIND_HEADER = 'X-Oriveo-Continuation-Kind';
const CONTINUATION_PROTOCOL_HEADER = 'X-Oriveo-Continuation-Protocol';
const CONTINUATION_PARSER_HEADER = 'X-Oriveo-Continuation-Parser';
const CAPABILITY_RESULT_HEADER = 'X-Oriveo-Capability-Result';

export async function POST(request: NextRequest) {
  // Rate limit per IP (best-effort in-memory sliding window, see rate-limit.ts).
  const ip = getClientIp(request.headers);
  const outcome = checkRateLimit(ip);
  const rateLimitHeaders = buildRateLimitHeaders(outcome);
  if (!outcome.allowed) {
    return new Response(JSON.stringify({ error: "Rate limit exceeded" }), {
      status: 429,
      headers: {
        ...JSON_HEADERS,
        ...rateLimitHeaders,
        [ERROR_SOURCE_HEADER]: "oriveo",
        "Retry-After": String(Math.max(1, Math.ceil((outcome.resetAt - Date.now()) / 1000))),
      },
    });
  }

  let rawBody: unknown;
  try {
    rawBody = await request.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: { ...JSON_HEADERS, ...rateLimitHeaders, [ERROR_SOURCE_HEADER]: "oriveo" },
    });
  }

  const validation = validateChatStreamRequest(rawBody);
  if (!validation.ok) {
    return new Response(JSON.stringify({ error: validation.error }), {
      status: validation.status,
      headers: { ...JSON_HEADERS, ...rateLimitHeaders, [ERROR_SOURCE_HEADER]: "oriveo" },
    });
  }
  const { providerKind, apiKey, modelID, messages, baseURL, stream, options, continuation, tools, toolChoice, authMode } = validation.value;
  let dispatchedReq: Awaited<ReturnType<typeof buildProviderRequest>> | null = null;
  const usesGrokSubscription = providerKind === 'grok' && authMode === 'subscription';
  // The two subscription chains are dispatched by providerKind: `authMode` only says "a subscription
  // is in use", not which chain. Codex differs from Grok in endpoint, request body and failure
  // semantics, so a shared branch would be wrong for one of them.
  const usesOpenAISubscription = providerKind === 'openAI' && authMode === 'subscription';

  try {
    // Subscription endpoints are resolved from server-side metadata only - the browser cannot supply
    // them, and they are not mixed with `providers.grok.transport`: there baseUrl is api.x.ai and the
    // path already carries /v1, while the subscription resourceBaseURL carries /v1 itself, so mixing
    // the two yields .../v1/v1/chat/completions and a 404 upstream.
    const subscriptionConfig = usesGrokSubscription ? await resolveGrokSubscriptionConfig() : null;
    if (usesGrokSubscription && !subscriptionConfig) {
      return new Response(JSON.stringify({ error: 'grok_subscription_unavailable' }), {
        status: 503,
        headers: { ...JSON_HEADERS, ...rateLimitHeaders, [ERROR_SOURCE_HEADER]: 'oriveo' },
      });
    }
    const codexConfig = usesOpenAISubscription ? await resolveOpenAISubscriptionConfig() : null;
    if (usesOpenAISubscription && !codexConfig) {
      return new Response(JSON.stringify({ error: 'openai_subscription_unavailable' }), {
        status: 503,
        headers: { ...JSON_HEADERS, ...rateLimitHeaders, [ERROR_SOURCE_HEADER]: 'oriveo' },
      });
    }
    const providerRequest = codexConfig
      // Codex is built **entirely on its own**, bypassing buildProviderRequest: that path is keyed by
      // models in the metadata catalog (capability recipes, previous_response_id, 400 self-healing,
      // chat-completions fallback), and subscription models are not in the catalog. Forcing it would
      // drag in a pile of behavior unrelated to this chain.
      ? buildCodexSubscriptionRequest({ modelID, messages, apiKey, options }, codexConfig)
      : applyGrokSubscriptionTransport(
        await buildProviderRequest({
          providerKind,
          apiKey,
          modelID,
          messages,
          stream,
          baseURL,
          // Subscription transport is rebuilt below from the per-model upstream declaration.
          // Keep the catalog builder from injecting API-key-mode web profiles first.
          options: subscriptionConfig ? { ...options, supportsWebSearch: false } : options,
          continuation,
          tools,
          toolChoice,
        }),
        subscriptionConfig,
        // The level table travels with the request (the client pulls the upstream declaration from the subscription catalog); the server does not guess it.
        { ...(options?.reasoning ? { mode: options.reasoning } : {}),
          ...(options?.upstreamReasoningLevels ? { declaredLevels: options.upstreamReasoningLevels } : {}),
          ...(options?.upstreamDefaultReasoningLevel
            ? { defaultLevel: options.upstreamDefaultReasoningLevel } : {}),
          ...(options?.upstreamApiBackend ? { apiBackend: options.upstreamApiBackend } : {}),
          supportsWebSearch: options?.grokSubscriptionWebSearchDeclared === true,
          messages },
      );
    // Subscription adapters rebuild the entire request after core dispatch. Re-run the canonical
    // protocol adapter at this final boundary so Responses/Anthropic/Gemini retain local tools and
    // continuation messages instead of being rejected or silently losing them.
    const req = tools?.length
      ? applyToolCallWireAdapter(providerRequest, { messages, tools, toolChoice })
      : providerRequest;
    // Deliberately does not invoke the legacy broad unsupported-parameter
    // self-healer. This runtime revision contains no reviewed locator rules;
    // stripping a field after any generic 400 would violate the one-retry
    // contract and could silently remove a developer's custom request field.

    // Content moderation for checkout vendor compliance: image generation requests only. The prompt is
    // screened before going upstream and anything other than allow is blocked, fail-closed. Text chat
    // is not moderated (explicitly exempt). The verdict is delivered as a 200 SSE error event and the
    // client localizes it from errorKind.
    if (isImageResponseAdapter(req.responseAdapter)) {
      const prompt = extractLatestUserPrompt(messages);
      if (prompt && !(await isImagePromptAllowed(prompt, `${providerKind}:${modelID}`))) {
        const event = `data: ${JSON.stringify({
          type: "error",
          error: MODERATION_BLOCK_MESSAGE,
          errorKind: MODERATION_ERROR_KIND,
          source: "oriveo",
        })}\n\n`;
        return new Response(event, {
          status: 200,
          headers: {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            Connection: "keep-alive",
            ...rateLimitHeaders,
          },
        });
      }
    }

    // SSRF guard: the baseURL comes from the user, so the target of both the main request and the
    // fallback must be validated before fetching upstream. Private, reserved and cloud metadata
    // addresses are blocked; official public domains pass.
    try {
      await assertUrlNotSsrf(req.url);
      if (req.fallback) {
        await assertUrlNotSsrf(req.fallback.url);
      }
    } catch (ssrfError) {
      if (ssrfError instanceof SsrfBlockedError) {
        return new Response(JSON.stringify({ error: ssrfError.message }), {
          status: 403,
          headers: { ...JSON_HEADERS, ...rateLimitHeaders, [ERROR_SOURCE_HEADER]: "oriveo" },
        });
      }
      throw ssrfError;
    }

    // Formula tool declarations are an official GET that must finish before the first chat leg.
    // It occurs after the primary URL SSRF gate; Formula paths are recipe-validated and pinned to
    // that same origin in core, so a custom recipe cannot redirect the server to another host.
    const preparedReq = req.responseAdapter === 'moonshot_formula_fiber_loop'
      ? await prepareMoonshotFormulaRequest(req, request.signal)
      : req;
    let activeReq = preparedReq;
    dispatchedReq = activeReq;
    let upstream = await executeProviderRequest(activeReq, request.signal);
    // The endpoint fallback is a server-authored alternate route, not parameter
    // recovery. Keep it intact now that broad field stripping is retired.
    if (!upstream.ok && activeReq.fallback && (upstream.status === 404 || upstream.status === 405)) {
      activeReq = activeReq.fallback;
      dispatchedReq = activeReq;
      upstream = await executeProviderRequest(activeReq, request.signal);
    }
    if (!upstream.ok) {
      const errorText = await upstream.text().catch(() => "");
      return new Response(errorText, {
        status: upstream.status,
        headers: {
          "Content-Type": upstream.headers.get("Content-Type") || "text/plain; charset=utf-8",
          [ERROR_SOURCE_HEADER]: "provider",
          ...capabilityResultHeaders(activeReq),
          ...capabilityRecoveryHeaders(activeReq, upstream.status, errorText),
        },
      });
    }

    if (activeReq.responseAdapter === "openai_images_api") {
      return adaptOpenAIImagesResponse(upstream);
    }
    if (activeReq.responseAdapter === "minimax_images_api") {
      return adaptMiniMaxImagesResponse(upstream);
    }
    if (activeReq.responseAdapter === "minimax_chat_stream") {
      return withExecutionHeaders(await adaptMiniMaxChatStream(upstream), activeReq);
    }
    if (activeReq.responseAdapter === "qwen_images_api") {
      return adaptQwenImagesResponse(upstream);
    }
    if (activeReq.responseAdapter === "siliconflow_images_api") {
      return adaptSiliconFlowImagesResponse(upstream);
    }
    if (activeReq.responseAdapter === "moonshot_tool_loop") {
      return withExecutionHeaders(await adaptMoonshotToolLoopResponse(upstream, activeReq), activeReq);
    }
    if (activeReq.responseAdapter === 'moonshot_formula_fiber_loop') {
      return withExecutionHeaders(await adaptMoonshotFormulaFiberResponse(upstream, activeReq, request.signal), activeReq);
    }
    if (activeReq.responseAdapter === 'gemini_interactions') {
      return withExecutionHeaders(await adaptGeminiInteractionsResponse(upstream), activeReq);
    }

    return new Response(upstream.body, {
      headers: {
        "Content-Type":
          upstream.headers.get("Content-Type") || "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
        ...capabilityResultHeaders(activeReq),
        ...(activeReq.continuationCapture ? {
          [CONTINUATION_KIND_HEADER]: activeReq.continuationCapture.kind,
          [CONTINUATION_PROTOCOL_HEADER]: activeReq.continuationCapture.protocol,
          [CONTINUATION_PARSER_HEADER]: activeReq.continuationCapture.responseParserKind,
        } : {}),
      },
    });
  } catch (error) {
    // Fail-closed handling for a custom request fragment: **this is not a network fault** and not an
    // upstream rejection - the request never left the machine, the local JSON was rejected at compile
    // time. Letting it fall into the 502 branch below would show it as "provider failure, try again
    // later", where a hundred retries give the same result and the actual way out (edit that fragment)
    // is never mentioned. It gets a dedicated kind plus a safe reason enum (a closed vocabulary that
    // contains nothing the user wrote), which the client localizes.
    const customFragmentReason = safeCustomFragmentRejectionReason(error);
    if (customFragmentReason) {
      return new Response(
        JSON.stringify({
          error: CUSTOM_FRAGMENT_ERROR_KIND,
          errorKind: CUSTOM_FRAGMENT_ERROR_KIND,
          reason: customFragmentReason,
        }),
        { status: 400, headers: { ...JSON_HEADERS, ...rateLimitHeaders, [ERROR_SOURCE_HEADER]: "oriveo" } },
      );
    }
    if (
      error instanceof Error &&
      error.message.includes("Base URL is required")
    ) {
      return new Response(JSON.stringify({ error: error.message }), {
        status: 400,
        headers: { ...JSON_HEADERS, [ERROR_SOURCE_HEADER]: "oriveo" },
      });
    }
    return new Response(
      JSON.stringify({ error: describeProviderRequestError(error) }),
      { status: 502, headers: { ...JSON_HEADERS, [ERROR_SOURCE_HEADER]: "network", ...(dispatchedReq ? capabilityResultHeaders(dispatchedReq) : {}) } },
    );
  }
}

/**
 * The **safe reason enum** for a compiler rejection. The vocabulary is frozen by
 * `SafeCustomFragmentResult` and consists entirely of structured identifiers containing nothing the
 * user wrote into the fragment, so an error response can never echo private JSON into logs or the UI.
 * It is thrown from the only call sites of `compileSafeCustomFragment`: the shared dispatch preamble
 * and the relay orchestration layer.
 */
function safeCustomFragmentRejectionReason(error: unknown): string | null {
  if (!(error instanceof Error)) return null;
  const matched = /^Safe custom fragment rejected: ([a-z_]+)$/.exec(error.message);
  return matched?.[1] ?? null;
}

function withExecutionHeaders(response: Response, request: { capabilityExecution?: unknown; continuationCapture?: { kind: string; protocol: string; responseParserKind: string } }): Response {
  return mergeExecutionResponse(response, capabilityResultHeaders(request as Parameters<typeof capabilityResultHeaders>[0]), request.continuationCapture);
}

/**
 * Serializes the shared production execution-fact builder onto the proxy header.
 * The entry shape (and the three-end decision that `generation` never becomes an
 * execution fact) lives in `capability-result-runtime`, so the browser consumer and
 * this producer cannot drift apart.
 */
function capabilityResultHeaders(
  request: { capabilityExecution?: { recipeRefs: string[]; delta: Record<string, unknown>; wireAppliedOwners?: Partial<Record<'web' | 'reasoning' | 'generation', boolean>>; customOwners?: Array<'web' | 'reasoning' | 'generation'>; resultEnvelope?: unknown } },
): Record<string, string> {
  const context = buildCapabilityResultContext(request.capabilityExecution, request.capabilityExecution?.resultEnvelope);
  return context ? { [CAPABILITY_RESULT_HEADER]: encodeCapabilityResultContext(context) } : {};
}
