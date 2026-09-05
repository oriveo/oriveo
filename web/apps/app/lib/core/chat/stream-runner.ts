/**
 * Shared streaming pipeline, used by both sendMessage and continueAnswering.
 *
 * Responsibilities:
 *   1. Call sendStream to obtain the stream plus its abort handle
 *   2. Wrap readStream, flushing partial text and recording reasoning duration along the way
 *   3. Run the post-abort guard, bailing out when the message was already marked interrupted or failed
 *
 * Not handled here:
 *   - Building chatHistory (each transaction does its own)
 *   - Writing the finished message back (the first turn overwrites, a continuation prepends)
 *   - The catch block, which depends on each caller's closure: sendStartedAt, prevMessages, interruptedMsg
 */
import type { StoreApi } from 'zustand';
import type { Attachment, Citation, AIModel, Provider } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import type { ContentPart, StreamEvent, StreamOptions, StreamUsage } from '../providers/types';
import { sendStream } from '../providers/service';
import { readStream } from '../../utils/chat-stream-utils';
import { createPartialFlushScheduler } from './partial-flush';
import { batchAppendStreamingReasoning } from './stream-batcher';
import { applyCitationsToMessage } from './cost-fields';
import type { ContinuationIntent } from '@oriveo/core/providers/request-preference/continuation';
import type { CompletedToolCall } from '@oriveo/core/providers/tool-call-accumulator';
import { collectCapabilityResults, requestedCapabilityResults, type CapabilityResultContext, type CapabilityResultRecord } from './capability-result-runtime';
import {
  grokSubscriptionErrorKindToProviderErrorKind,
  prepareGrokSubscriptionRequest,
  refreshMetadataOnClientVersionRejected,
} from '../providers/grok-subscription';
import {
  openAISubscriptionErrorKindToProviderErrorKind,
  prepareOpenAISubscriptionRequest,
  refreshMetadataOnCodexClientVersionRejected,
} from '../providers/openai-subscription';
import { persistGrokSubscriptionCredential, persistOpenAISubscriptionCredential } from '../provider-ops';
import type { GrokSubscriptionErrorKind } from '@oriveo/core/providers/grok-subscription';
import type { OpenAISubscriptionErrorKind } from '@oriveo/core/providers/openai-subscription';
import {
  grokSubscriptionProviderError,
  openAISubscriptionProviderError,
} from '@oriveo/core/providers/errors';
import {
  ensureModelFacts,
  subscriptionDeclaredReasoningLevels,
} from '../metadata/metadata-client';

/**
 * Synthetic stream for a subscription credential that fails before anything goes out.
 *
 * It runs through the same `StreamEvent` pipeline instead of throwing: the failure title, body and
 * recovery card are all translated from `errorKind` at render time, so bypassing the pipeline
 * would mean reimplementing localization and the recovery actions.
 */
function grokSubscriptionFailureHandle(kind: GrokSubscriptionErrorKind): {
  stream: ReadableStream<StreamEvent>;
  abort: () => void;
} {
  const errorKind = grokSubscriptionErrorKindToProviderErrorKind(kind);
  // Exactly the copy used when the upstream really answers 426/403/401/429; two copies would drift.
  const upstreamCopy = grokSubscriptionProviderError(GROK_SUBSCRIPTION_ERROR_STATUS[kind] ?? 0);
  return {
    stream: new ReadableStream<StreamEvent>({
      start(controller) {
        controller.enqueue({
          type: 'error',
          error: upstreamCopy?.message ?? 'Grok subscription sign-in is unavailable right now.',
          errorKind,
          source: 'oriveo',
        });
        controller.close();
      },
    }),
    abort: () => {},
  };
}

/** Local failure kind -> equivalent upstream status, purely so the same copy can be reused. */
const GROK_SUBSCRIPTION_ERROR_STATUS: Partial<Record<GrokSubscriptionErrorKind, number>> = {
  clientVersionRejected: 426,
  configurationUnavailable: 426,
  subscriptionNotEligible: 403,
  unauthorized: 401,
  quotaExhausted: 429,
};

/**
 * Synthetic stream for a Codex credential that fails before anything goes out. Same shape as the
 * Grok variant, with its own copy.
 */
function openAISubscriptionFailureHandle(kind: OpenAISubscriptionErrorKind): {
  stream: ReadableStream<StreamEvent>;
  abort: () => void;
} {
  const errorKind = openAISubscriptionErrorKindToProviderErrorKind(kind);
  const upstreamCopy = openAISubscriptionProviderError(OPENAI_SUBSCRIPTION_ERROR_STATUS[kind] ?? 0);
  return {
    stream: new ReadableStream<StreamEvent>({
      start(controller) {
        controller.enqueue({
          type: 'error',
          error: upstreamCopy?.message ?? 'ChatGPT subscription sign-in is unavailable right now.',
          errorKind,
          source: 'oriveo',
        });
        controller.close();
      },
    }),
    abort: () => {},
  };
}

const OPENAI_SUBSCRIPTION_ERROR_STATUS: Partial<Record<OpenAISubscriptionErrorKind, number>> = {
  clientVersionRejected: 426,
  configurationUnavailable: 426,
  subscriptionNotEligible: 403,
  unauthorized: 401,
  quotaExhausted: 429,
};

export type StreamPipelineOutcome = 'completed' | 'guarded';

export interface StreamPipelineParams {
  store: StoreApi<AppStore>;
  appendChunk: (chunk: string) => void;
  /** Conversation the stream is bound to; the key for streamingTexts / streamingReasoningTexts. */
  conversationId: string;
  /** Assistant message id the stream is bound to; target of partial flushes and the guard check. */
  messageId: string;
  provider: Provider;
  model: AIModel;
  /** Fully built chat history, with the system prompt and any continuation marker already injected. */
  chatHistory: { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[];
  /** Initial text for readStream: '' on the first turn, the existing text when continuing. */
  initialText: string;
  relayStreamOptions: StreamOptions | undefined;
  /** Called back with the abort function so the transaction can return it as SendHandle.abort. */
  setAbortFn: (fn: (() => void) | null) => void;
  /** Direct Library context persists only its document-identity citations. */
  suppressStreamCitations?: boolean;
  /** P3c local-only replay captured from the authoritative proxy stream. */
  continuation?: ContinuationIntent;
  onContinuation?: (continuation: ContinuationIntent) => void;
}

export interface StreamPipelineResult {
  /**
   * - `completed`: the stream ended on its own, including an abort where readStream returned
   *   normally and the guard did not fire
   * - `guarded`: the guard fired because the message was already marked interrupted or failed, and
   *   the caller should return early
   *
   * On `guarded` the runner has already called {@link applyCitationsToMessage} to write the final
   * citations back to the store. fullText/reasoningText are still returned, but the caller must
   * not overwrite the message's final state.
   */
  outcome: StreamPipelineOutcome;
  fullText: string;
  reasoningText: string;
  reasoningDurationMs?: number;
  citations: Citation[] | undefined;
  usage: StreamUsage | undefined;
  servedModelID?: string;
  imageAttachments: Attachment[];
  capabilityResults: CapabilityResultRecord[];
  unhandledToolCalls: CompletedToolCall[];
}

export async function runStreamPipeline(
  params: StreamPipelineParams,
): Promise<StreamPipelineResult> {
  const {
    store,
    appendChunk,
    conversationId,
    messageId,
    provider,
    model,
    chatHistory,
    initialText,
    relayStreamOptions,
    setAbortFn,
    suppressStreamCitations = false,
    continuation,
    onContinuation,
  } = params;

  // Grok subscription mode: fetch an access token right before going out, auto-renewed five
  // minutes before expiry.
  //
  // The single source of truth is `provider.grokSubscription`, not `provider.apiKey`, which stays
  // empty in subscription mode. Keeping the token in two places would eventually raise the
  // question of which copy is current, since renewal only updates one.
  const subscription = provider.kind === 'grok' && provider.authMode === 'subscription'
    ? await prepareGrokSubscriptionRequest(provider)
    : null;
  if (subscription?.ok && subscription.value.refreshed) {
    await persistGrokSubscriptionCredential(store, provider.id, subscription.value.refreshed);
  }
  if (subscription && !subscription.ok) {
    // Stop here. Without subscription context the request would go out to the default API-key-mode
    // endpoint, and the user would get an error unrelated to the real cause.
    refreshMetadataOnClientVersionRejected(subscription.error);
  }
  // Codex subscription mode sits alongside the Grok branch rather than sharing it: `authMode`
  // alone cannot say which path is in play, and matching on it would serve an OpenAI instance
  // using Grok's credential fields.
  const codexSubscription = provider.kind === 'openAI' && provider.authMode === 'subscription'
    ? await prepareOpenAISubscriptionRequest(provider)
    : null;
  if (codexSubscription?.ok && codexSubscription.value.refreshed) {
    await persistOpenAISubscriptionCredential(store, provider.id, codexSubscription.value.refreshed);
  }
  if (codexSubscription && !codexSubscription.ok) {
    refreshMetadataOnCodexClientVersionRejected(codexSubscription.error);
  }
  const baseStreamOptions = continuation
    ? { ...relayStreamOptions, continuation }
    : relayStreamOptions;
  // Subscription models can live outside the public catalog. Resolve their
  // models.dev declaration from the independently cached sidecar before the
  // decisive outbound gate; a cold cache must not silently erase supported
  // reasoning levels for this request.
  if (provider.authMode === 'subscription') {
    await ensureModelFacts();
  }
  const subscriptionReasoningLevels = provider.authMode === 'subscription'
    ? subscriptionDeclaredReasoningLevels(provider.kind, model)
    : [];
  const streamOptions = subscription?.ok
    ? {
      ...baseStreamOptions,
      grokSubscriptionAuth: true,
      grokSubscriptionWebSearchDeclared: model.capabilities.includes('web'),
      ...(model.upstreamDefaultReasoningLevel
        ? { upstreamDefaultReasoningLevel: model.upstreamDefaultReasoningLevel }
        : {}),
      ...(model.upstreamApiBackend ? { upstreamApiBackend: model.upstreamApiBackend } : {}),
      // As with Codex: a subscription model has no server profile, so tier admission can only come from the upstream declaration.
      ...(subscriptionReasoningLevels.length
        ? { upstreamReasoningLevels: subscriptionReasoningLevels }
        : {}),
    }
    : codexSubscription?.ok
      ? {
        ...baseStreamOptions,
        openAISubscriptionAuth: true,
        openAISubscriptionAccountID: codexSubscription.value.accountID,
        // Upstream declares web search for this model - the second half of "user intent AND
        // upstream declaration", passed separately from `supportsWebSearch`, which is the first
        // half. The capability bit is built straight from the `/models` declaration (see
        // `buildOpenAISubscriptionModels`), so it is that declaration itself.
        openAISubscriptionWebSearchDeclared: model.capabilities.includes('web'),
        // The tier table follows the upstream declaration for this specific model. It lives only
        // inside this one request (never stored, never synced) and is used at send time to validate
        // the product tier the user chose into a value the upstream actually accepts.
        ...(subscriptionReasoningLevels.length
          ? { upstreamReasoningLevels: subscriptionReasoningLevels }
          : {}),
      }
      : baseStreamOptions;
  const streamHandle = subscription && !subscription.ok
    ? grokSubscriptionFailureHandle(subscription.error)
    : codexSubscription && !codexSubscription.ok
      ? openAISubscriptionFailureHandle(codexSubscription.error)
      : sendStream(
        provider.kind,
        subscription?.ok
          ? subscription.value.accessToken
          : codexSubscription?.ok
            ? codexSubscription.value.accessToken
            : provider.apiKey,
        // For inline relay image generation the main model may be swapped for a chat driver:
        // gpt-image-* is not a chat model, and putting it in body.model gets ignored upstream while
        // polluting the context. The original model has moved to relayImageToolModelID.
        relayStreamOptions?.relayDriverModelID ?? model.id,
        chatHistory,
        provider.baseURLText,
        streamOptions,
      );
  const { stream, abort } = streamHandle;
  setAbortFn(abort);

  const flushScheduler = createPartialFlushScheduler(store, conversationId, messageId);
  const onChunk = (chunk: string) => {
    appendChunk(chunk);
    flushScheduler.onChunk(chunk);
  };

  // Reasoning duration: the first reasoning chunk sets startedAt, the first text chunk sets
  // endedAt. If no text chunk ever arrives, the done timestamp is used as the end.
  let reasoningStartedAt: number | null = null;
  let reasoningEndedAt: number | null = null;
  const onReasoningChunk = (chunk: string) => {
    if (reasoningStartedAt === null) {
      reasoningStartedAt = Date.now();
      // "Reasoning has started" is an explicit boolean rather than "text is non-empty": during
      // long reasoning the upstream sends empty-string heartbeats only (the first non-empty
      // reasoning chunk has been measured at 279s), so the text stays '' and this flag is the only
      // thing that can light up "Thinking...". It is set on the first event only, so minutes of
      // heartbeats cost a single store set.
      store.getState().markStreamingReasoningStarted(conversationId);
    }
    // Empty strings never enter the text pipeline: appending one is still empty and only burns a rAF frame and a store set.
    if (!chunk) return;
    // Reasoning shares the rAF batcher with the body text: an expanded reasoning block is rendered
    // as markdown, so writing straight to the store would tie parse frequency to the provider's
    // chunk rate, which can exceed 100/s. The flush and discard exits are shared, and the stop and
    // pagehide paths already cover reasoning, so no tail is lost.
    batchAppendStreamingReasoning(conversationId, chunk);
  };
  const onTextChunkForReasoningEnd = (chunk: string) => {
    if (reasoningStartedAt !== null && reasoningEndedAt === null) {
      reasoningEndedAt = Date.now();
    }
    onChunk(chunk);
  };

  let streamResult;
  let latestCitations: Citation[] | undefined;
  const normalizedEvents: StreamEvent[] = [];
  let requestedWritten = false;
  // `sendStream` exposes this context only after the proxy has completed its
  // final dispatch and returned headers. Show requested immediately: an empty
  // successful stream has no parser event but is still a real sent request.
  const writeRequested = () => {
    if (requestedWritten) return;
    const requested = requestedCapabilityResults(capabilityResultContextOf(streamHandle));
    if (requested.length === 0) return;
    requestedWritten = true;
    const conversation = store.getState().conversations.find((candidate) => candidate.id === conversationId);
    if (!conversation) return;
    store.getState().updateConversation(conversationId, {
      messages: conversation.messages.map((message) => message.id === messageId
        ? { ...message, capabilityResults: requested } : message),
    });
  };
  writeRequested();
  const contextReady = (streamHandle as { capabilityResultContextReady?: unknown }).capabilityResultContextReady;
  if (contextReady && typeof (contextReady as Promise<unknown>).then === 'function') {
    void (contextReady as Promise<unknown>).then(() => writeRequested());
  }
  try {
    streamResult = await readStream(
      stream,
      initialText,
      onTextChunkForReasoningEnd,
      (next) => {
        latestCitations = next;
      },
      onReasoningChunk,
      undefined,
      onContinuation,
      (event) => {
        normalizedEvents.push(event);
        writeRequested();
      },
    );
  } catch (error) {
    const capabilityContext = capabilityResultContextOf(streamHandle);
    if (error && typeof error === 'object') {
      // The current revision has zero reviewed locatorRules. Therefore a generic
      // provider/network/stream error cannot identify an automatic owner and
      // must never be persisted as rejected (nor enter a rejection cache).
      // Keep the final wire fact as `requested`; the failed message's normal
      // error card can offer a custom-only retry without claiming rejection.
      Object.assign(error, {
        capabilityResults: requestedCapabilityResults(capabilityContext),
        capabilityCustomRetryEligible: capabilityCustomRetryEligibleOf(streamHandle),
        capabilityRecovery: capabilityRecoveryDescriptorOf(streamHandle),
      });
    }
    throw error;
  } finally {
    flushScheduler.dispose();
  }

  const { fullText, reasoningText, usage, imageAttachments, servedModelID, toolCalls } = streamResult;
  const citations = streamResult.citations ?? latestCitations;
  const capabilityContext = capabilityResultContextOf(streamHandle);
  const capabilityResults = collectCapabilityResults(capabilityContext, normalizedEvents);

  // Reasoning was running and no text arrived before done -> close it out at the done timestamp.
  if (reasoningStartedAt !== null && reasoningEndedAt === null) {
    reasoningEndedAt = Date.now();
  }
  // reasoningText must also be non-empty: empty-string heartbeats set reasoningStartedAt as well,
  // which is what it is for. If the upstream never emitted a word of reasoning, recording
  // "Thought for 4m" with nothing to expand is ghost data - ReasoningBlock renders nothing for
  // empty text, so it would only be synced to other clients as noise.
  const reasoningDurationMs =
    reasoningText.trim() !== '' && reasoningStartedAt !== null && reasoningEndedAt !== null
      ? Math.max(0, reasoningEndedAt - reasoningStartedAt)
      : undefined;

  // Guard: after an abort, readStream returns normally through ctrl.close() rather than throwing,
  // but the message may already have been put into a final state elsewhere (entry guard, stop,
  // sign-out). Overwriting it as delivered would make the UI pretend the stream finished normally,
  // hiding the recovery card and the continue button.
  const guardConv = store.getState().conversations.find((c) => c.id === conversationId);
  const guardMsg = guardConv?.messages.find((m) => m.id === messageId);
  if (guardMsg && (guardMsg.state === 'interrupted' || guardMsg.state === 'failed')) {
    if (!suppressStreamCitations) {
      applyCitationsToMessage(store, conversationId, messageId, citations);
    }
    return {
      outcome: 'guarded',
      fullText,
      reasoningText,
      reasoningDurationMs,
      citations,
      usage,
      servedModelID,
      imageAttachments,
      capabilityResults,
      unhandledToolCalls: toolCalls,
    };
  }

  return {
    outcome: 'completed',
    fullText,
    reasoningText,
    reasoningDurationMs,
    citations,
    usage,
    servedModelID,
    imageAttachments,
    capabilityResults,
    unhandledToolCalls: toolCalls,
  };
}

function capabilityResultContextOf(handle: unknown): CapabilityResultContext | null | undefined {
  if (typeof handle !== 'object' || handle === null || !('getCapabilityResultContext' in handle)) return null;
  const getter = (handle as { getCapabilityResultContext?: unknown }).getCapabilityResultContext;
  return typeof getter === 'function' ? getter() as CapabilityResultContext | null | undefined : null;
}

function capabilityCustomRetryEligibleOf(handle: unknown): boolean {
  if (typeof handle !== 'object' || handle === null || !('getCapabilityCustomRetryEligible' in handle)) return false;
  const getter = (handle as { getCapabilityCustomRetryEligible?: unknown }).getCapabilityCustomRetryEligible;
  return typeof getter === 'function' && getter() === true;
}

function capabilityRecoveryDescriptorOf(handle: unknown): unknown {
  if (typeof handle !== 'object' || handle === null || !('getCapabilityRecoveryDescriptor' in handle)) return undefined;
  const getter = (handle as { getCapabilityRecoveryDescriptor?: unknown }).getCapabilityRecoveryDescriptor;
  return typeof getter === 'function' ? getter() : undefined;
}
