/**
 * continueAnswering - continue an interrupted or already delivered assistant message.
 *
 * Key points:
 *   - reasoning text is the previous text plus this round's new chunks (see operations-send for
 *     the first-round overwrite rule)
 *   - cache tokens and reasoningDurationMs accumulate on top of this round
 *   - citations go through mergeCitationsWithExisting for deduplicated merging
 */
import type { ChatMessage, Conversation, AIModel, Provider, ReasoningMode } from '@oriveo/shared';
import { PROVIDER_REQUEST_FAILED_TITLE } from '../providers/error-i18n';
import type { GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { mapErrorKindKey } from '../../utils/chat-stream-utils';
import { processImageAttachments, backfillStorageRefs } from '../../utils/stream-image-utils';
import { customFragmentFailurePatch } from './custom-fragment-rejection';
import { customFragmentAllowedPaths } from './custom-fragment-allowed-paths';
import { additionalBodyFailurePatch } from './additional-body-rejection';
import { getSyncAdapter } from '../sync-port';
import { deriveConversationMetadata, computeConversationActivityAt } from '../conversation-metadata';
import { withErrorReporting } from '../../sentry/report-silent';
import { trackEvent, telemetryProviderKind, telemetryModelID } from '../telemetry';
import { relaySendTelemetryProperties } from '../telemetry/relay-properties';
import { reportSendStartedTelemetry } from './send-start';
import { reportChatFailed } from './send-failure';
import * as Sentry from '@sentry/nextjs';
import { mergeCitationsWithExisting, deriveCostFields, mergeMessageUsageFields } from './cost-fields';
import {
  buildProviderSentryContext,
  normalizeChatFailure,
  shouldReportProviderError,
  createProviderSentryError,
} from './error-reporting';
import { recalculateConversationCost, shouldTrackProviderUsage } from './usage-tracking';
import { stopReasonFromError, stopReasonFromFinish } from './stop-reason-outcome';
import { isContextOverflowFailure } from './context-pipeline/chat-context';
import type { ChatOpCtx, SendHandle } from './operations';
import { clearOwnLibraryConfirmation, requestLibraryConfirmation } from '../library/confirmation';
import type { LibraryConfirmationRequest } from '../library/types';
import { LibraryResearchCancelledError } from './library-agent-loop';
import { libraryFailurePatch, type LibraryFailurePresentation } from './library-failure';
import { libraryDocumentRefsFromCitations } from './library-direct-context';
import { continueOutboundMessages, prepareLibraryDirectContext, runChatOutbound } from './operations-send';
import {
  continuationFingerprintForExplicitContinue,
  continuationForExplicitContinue,
  continuationSendCompleted,
  continuationSendInterrupted,
  continuationSendStarted,
} from './continuation-lifecycle';

import { oriveoAbortReason } from '@oriveo/core/util/abort-reason';
import { withMemoryItemIds } from './memory-item-ids';
import { patchAssistantMessage } from './agent-send-shared';
export function continueAnswering(
  ctx: ChatOpCtx,
  params: {
    messageId: string;
    conversation: Conversation;
    messages: ChatMessage[];
    provider: Provider;
    model: AIModel;
    reasoningMode: ReasoningMode;
    webSearchEnabled?: boolean;
    libraryContextCancelledText?: string;
    /** Continuation re-reads the named documents too, so library_* failures use the same localized copy and recovery CTA as the send path. */
    libraryFailurePresentation?: LibraryFailurePresentation;
    /** One-shot transient values, same as `transientGenerationParameters` in operations-send; no UI producer yet. */
    transientGenerationParameters?: GenerationParameterOverrides;
    /**
     * Same name and meaning as in `operations-send`: resend without the custom request fields.
     *
     * Once a custom field is rejected fail-closed, a plain retry is rejected again the same way,
     * so the only way out is to send without it. Continuation is a separate entry point and
     * therefore carries the same two switches and the same filter as the send path. The only UI
     * producer today is the retry card (`operations-retry` -> send).
     */
    excludeCustomFragments?: boolean;
    excludeCustomFragmentOwners?: Array<'web' | 'reasoning' | 'generation'>;
  },
): SendHandle {
  const { store, appendChunk, te } = ctx;
  const {
    messageId,
    conversation,
    messages,
    provider,
    model,
    reasoningMode,
    webSearchEnabled,
    libraryContextCancelledText = 'Library context reading was cancelled.',
    libraryFailurePresentation,
    transientGenerationParameters,
    excludeCustomFragments = false,
    excludeCustomFragmentOwners = [],
  } = params;

  const msgIndex = messages.findIndex((m) => m.id === messageId);
  // The continuation target drops the previous round's error presentation metadata up front, so
  // the generating / delivered / failed paths below all start from a clean snapshot. Otherwise
  // errorTitle/errorDetail/errorKind ride into the success state through completedMsg's
  // `...interruptedMsg`, or mix with a new error if this message fails again (RecoveryCard and
  // MessageBubble both render off errorKind).
  const interruptedMsg = clearErrorPresentationState(messages[msgIndex]);
  const existingText = interruptedMsg.text || '';
  // Research-mode citations are evidence the model or the server retrieved on its own, not
  // documents the user named. Inheriting them as direct context turns a search that should re-run
  // into a re-read of stale evidence.
  const directContextDocuments = interruptedMsg.libraryResearchEnabled
    ? []
    : libraryDocumentRefsFromCitations(interruptedMsg.citations);

  // Mark the target as generating.
  const generatingMessages = messages.map((m) => m.id === messageId ? { ...interruptedMsg, state: 'generating' as const } : m);
  store.getState().updateConversation(conversation.id, {
    messages: generatingMessages,
    ...deriveConversationMetadata(conversation, generatingMessages),
    updatedAt: computeConversationActivityAt(generatingMessages, conversation.createdAt),
  });

  // Continuation seeds the streaming dictionary with the existing text as the initial partial.
  // reasoning does not get the previous text: the streaming partial holds only this round's new
  // chunks, matching the done path's
  // `[interruptedMsg.reasoningText, reasoningText.trim()].join('\n\n')`.
  // MessageBubble.effectiveReasoningText concatenates prev + partial while continuing so the
  // reasoning block does not disappear before the first new chunk arrives.
  // The partial-flush and stop-stream paths need the same concatenation.
  store.getState().beginStreamingForConversation(conversation.id, messageId);
  store.getState().setStreamingText(conversation.id, existingText);
  const continueStartedAt = Date.now();
  // A continuation is a real outbound request: exactly one sent per attempt (attempt_kind=continue), reported before the outcome.
  let sentReported = false;
  const reportSent = () => {
    if (sentReported) return;
    sentReported = true;
    reportSendStartedTelemetry({
      finalConvId: conversation.id,
      isFirstMessage: false,
      provider,
      model,
      reasoningMode,
      webSearchEnabled,
      attachments: undefined,
      skillId: conversation.skillId,
      attemptKind: 'continue',
    });
  };

  let abortFn: (() => void) | null = null;
  let abortRequested = false;
  let abortInvoked = false;
  const directContextController = new AbortController();
  // Track the confirmation ids raised by this continuation, so cleanup only clears its own and
  // does not dismiss a dialog another session is waiting on.
  const ownConfirmationIds = new Set<string>();
  const requestOwnConfirmation = (request: LibraryConfirmationRequest) => {
    ownConfirmationIds.add(request.id);
    return requestLibraryConfirmation(store, request, directContextController.signal);
  };
  const requestAbort = () => {
    abortRequested = true;
    if (!abortFn || abortInvoked) return;
    abortInvoked = true;
    abortFn();
  };
  const setAbortFn = (fn: (() => void) | null) => {
    abortFn = fn;
    if (abortRequested) requestAbort();
  };

  // Wire protocol of this (most recent) attempt's outbound request: the overflow check picks its family from it.
  let requestRelayTransport: StreamOptions['relayTransport'];
  const done = (async () => {
    try {
      // The continuation state and the fingerprint of the leg that produced it are read before started clears the old state; every later lifecycle write is serialized,
      // so neither a successful nor an interrupted retry leaves stale continuation state behind.
      const [continuation, previousFingerprint] = await Promise.all([
        continuationForExplicitContinue(conversation.id, messageId),
        continuationFingerprintForExplicitContinue(conversation.id, messageId),
      ]);
      await Promise.resolve(continuationSendStarted(conversation.id, messageId)).catch(() => undefined);
      if (directContextDocuments.length > 0) {
        setAbortFn(() => directContextController.abort(oriveoAbortReason('direct-context-cancel')));
      }
      const latestUserText = [...messages.slice(0, msgIndex)].reverse()
        .find((m) => m.role === 'user')
        ?.text ?? existingText;
      // purpose=continue: history is cut up to and including the target, and the continuation sentence is appended by the assembler;
      // assembly, option chain, streaming, rho, manifest and overflow fallback are the same chain as sending.
      const outbound = await runChatOutbound(ctx, {
        purpose: 'continue',
        conversationId: conversation.id,
        conversation,
        provider,
        model,
        reasoningMode,
        webSearchEnabled,
        libraryActive: directContextDocuments.length > 0,
        messages: continueOutboundMessages(messages, interruptedMsg),
        keepAssistantId: messageId,
        latestUserText,
        assistantMessageId: messageId,
        initialText: existingText,
        ...(directContextDocuments.length > 0 ? {
          loadLibrary: () => prepareLibraryDirectContext({
            documents: directContextDocuments,
            provider,
            model,
            researchId: messageId,
            signal: directContextController.signal,
            requestConfirmation: requestOwnConfirmation,
            onQuota: (quota) => store.getState().setLibraryQuota(quota),
          }),
        } : {}),
        optionInputs: {
          ...(conversation.skillId ? { skillId: conversation.skillId } : {}),
          ...(transientGenerationParameters ? { transientGenerationParameters } : {}),
          excludeCustomFragments,
          excludeCustomFragmentOwners,
        },
        continuation,
        previousFingerprint,
        setAbortFn,
        isAbortRequested: () => abortRequested,
        onRelayTransport: (transport) => { requestRelayTransport = transport; },
      });
      const { pipeline, promptContext } = outbound;
      const directContext = outbound.libraryContext;

      if (pipeline.outcome === 'guarded') {
        // The request has been sent: stream-runner writes the message's final state; here we only add the memory item ids injected this time.
        if (outbound.memoryIds.length > 0) {
          patchAssistantMessage(store, conversation.id, messageId, { memoryItemIds: outbound.memoryIds });
        }
        reportSent();
        await Promise.resolve(continuationSendInterrupted(conversation.id, messageId)).catch(() => undefined);
        return;
      }

      const { fullText, reasoningText, reasoningDurationMs: newReasoningDurationMs, citations, usage, imageAttachments, servedModelID } = pipeline;

      const { finalText, processedAttachments } = await processImageAttachments(fullText, imageAttachments);
      const costInfo = deriveCostFields(usage, model, provider.kind, provider.authMode);
      const cost = costInfo.cost + promptContext.retrievalCost;
      const completedAt = new Date().toISOString();

      // Merge the historical citations with this round's, deduplicated by normalizeUrl.
      // Direct context is re-read for every continuation. Use the fresh identity
      // citations so a pending library-context:// URL cannot survive beside a
      // newly trusted source URL for the same document.
      const mergedCitations = mergeCitationsWithExisting(
        directContext?.citations ?? interruptedMsg.citations,
        directContext ? undefined : citations,
      );

      // Reasoning duration merge: prev.reasoningDurationMs plus this round's duration.
      const mergedReasoningDurationMs =
        interruptedMsg.reasoningDurationMs !== undefined || newReasoningDurationMs !== undefined
          ? (interruptedMsg.reasoningDurationMs ?? 0) + (newReasoningDurationMs ?? 0)
          : undefined;

      const completedMsg: ChatMessage = withMemoryItemIds({
        ...interruptedMsg, text: finalText, state: 'delivered' as const,
        stopReason: stopReasonFromFinish(pipeline.finish, finalText.trim() !== ''),
        reasoningText: [interruptedMsg.reasoningText, reasoningText.trim()].filter(Boolean).join('\n\n') || undefined,
        ...(mergedReasoningDurationMs !== undefined ? { reasoningDurationMs: mergedReasoningDurationMs } : {}),
        estimatedCost: (interruptedMsg.estimatedCost ?? 0) + cost,
        servedModelID,
        attachments: processedAttachments.length > 0
          ? [...(interruptedMsg.attachments ?? []), ...processedAttachments]
          : interruptedMsg.attachments,
        ...(mergedCitations && mergedCitations.length > 0 ? { citations: mergedCitations } : {}),
        // One continuation is one new billable upstream request: keep upstream when the upstream
        // reports it, otherwise use this round's source.
        costSource: costInfo.costSource,
        ...mergeMessageUsageFields(interruptedMsg, costInfo),
      }, outbound.memoryIds, true);

      // Replace the continuation target against the store's latest messages rather than the
      // snapshot, so concurrent writes during the continuation are not overwritten.
      const completedBase = store.getState().conversations.find((c) => c.id === conversation.id)?.messages ?? messages;
      const completedMessages = completedBase.map((m) => m.id === messageId ? completedMsg : m);
      const updatedCost = recalculateConversationCost(completedMessages);
      store.getState().updateConversation(conversation.id, {
        messages: completedMessages,
        ...deriveConversationMetadata(conversation, completedMessages),
        estimatedCost: updatedCost,
        updatedAt: computeConversationActivityAt(completedMessages, conversation.createdAt),
      });

      // Whole-turn atomic sync so a failed or interrupted half turn never reaches the cloud:
      // locate this turn's paired user message (the last delivered user before the continuation
      // target) and upload it together with the assistant. The user message of an interrupted
      // turn was not uploaded when it was sent, so this is its first upload and it prevents an
      // orphaned assistant on other clients. With no paired user, only the assistant is synced.
      const continuedIndex = completedMessages.findIndex((m) => m.id === messageId);
      const pairedUser = continuedIndex > 0
        ? [...completedMessages.slice(0, continuedIndex)].reverse().find((m) => m.role === 'user' && m.state === 'delivered')
        : undefined;
      const syncConv = store.getState().conversations.find((c) => c.id === conversation.id);
      if (pairedUser) {
        getSyncAdapter()?.didCompleteRound(pairedUser, completedMsg, conversation.id, syncConv, updatedCost);
      } else {
        getSyncAdapter()?.didCompleteAssistantMessage(completedMsg, conversation.id, updatedCost);
      }
      if (shouldTrackProviderUsage(provider)) {
        /* local cost only */
      }

      const contUploadableAtts = processedAttachments
        .filter((a) => a.localImageID)
        .map((a) => ({ att: a, msgID: messageId }));
      // Read conversations live (see the backfillStorageRefs comment: a frozen snapshot swallows
      // edits made during the upload).
      void backfillStorageRefs(
        conversation.id,
        contUploadableAtts,
        () => store.getState().conversations,
        store.getState().updateConversation,
      );
      reportSent();
      trackEvent('chat_message_completed', {
        provider_kind: telemetryProviderKind(provider.kind),
        model_id: telemetryModelID(provider.kind, model.id),
        served_model_id: servedModelID ? telemetryModelID(provider.kind, servedModelID) : null,
        prompt_tokens: usage?.prompt_tokens ?? null,
        completion_tokens: usage?.completion_tokens ?? null,
        latency_ms: Date.now() - continueStartedAt,
        cost_usd_micros: Math.round(cost * 1_000_000),
        has_image_output: processedAttachments.length > 0,
        attempt_kind: 'continue',
        ...relaySendTelemetryProperties(provider, model),
      });
      await Promise.resolve(continuationSendCompleted(conversation.id, messageId)).catch(() => undefined);
    } catch (err) {
      await Promise.resolve(continuationSendInterrupted(conversation.id, messageId)).catch(() => undefined);
      if (err instanceof LibraryResearchCancelledError) {
        const cancelledMsg: ChatMessage = {
          ...interruptedMsg,
          text: existingText
            ? `${existingText}\n\n${libraryContextCancelledText}`
            : libraryContextCancelledText,
          state: 'delivered',
          // The user cancelled the library retrieval: record interrupted and leave the state as delivered.
          stopReason: 'interrupted',
          citations: undefined,
        };
        const completedBase = store.getState().conversations
          .find((candidate) => candidate.id === conversation.id)?.messages ?? messages;
        const completedMessages = completedBase.map((message) =>
          message.id === messageId ? cancelledMsg : message,
        );
        const updatedCost = recalculateConversationCost(completedMessages);
        store.getState().updateConversation(conversation.id, {
          messages: completedMessages,
          ...deriveConversationMetadata(conversation, completedMessages),
          estimatedCost: updatedCost,
          updatedAt: computeConversationActivityAt(completedMessages, conversation.createdAt),
        });
        getSyncAdapter()?.didCompleteAssistantMessage(cancelledMsg, conversation.id, updatedCost);
        return;
      }
      // Same normalization as the catch in operations-send: a bare transport failure (offline,
      // network switch, cancel) can still arrive without a kind, and defaulting to upstream would
      // render a dead local network as a provider-side problem.
      const pe = normalizeChatFailure(err);
      // The partial from before the failure is still in the store's streaming dictionary (it is
      // only cleared in finally): streamingTexts already holds existingText plus this round's
      // delta (seeded by setStreamingText(existingText), appended by onChunk), while the
      // reasoning partial holds only this round's chunks and must be joined with the history.
      // Falling back to the old text keeps delivered content when no chunk arrived this round.
      const partialState = store.getState();
      // Terminal-state guard, same as the catch in operations-send: do not overwrite a message
      // stop() already marked interrupted with failed, or a deliberate stop is reported as a
      // failure and the recovery card degrades from 'continue' to 'retry'.
      const guardMsg = partialState.conversations
        .find((c) => c.id === conversation.id)?.messages
        .find((m) => m.id === messageId);
      const alreadyTerminal = guardMsg?.state === 'interrupted' || guardMsg?.state === 'failed';
      reportSent();
      // A user stop (stop() already saved interrupted and reported stopped) is not a failure: at most one outcome.
      if (!abortRequested && guardMsg?.state !== 'interrupted') {
        reportChatFailed({ provider, model, attemptKind: 'continue', error: pe ?? err, rawError: err, sendStartedAt: continueStartedAt });
      }
      const partialText = partialState.streamingTexts[conversation.id] || existingText;
      const partialReasoning = (partialState.streamingReasoningTexts[conversation.id] ?? '').trim();
      const mergedReasoning =
        [interruptedMsg.reasoningText, partialReasoning].filter(Boolean).join('\n\n') || undefined;
      // Replace the continuation target against the store's latest messages rather than the
      // snapshot, so concurrent writes during the continuation are not overwritten.
      const failedBase = store.getState().conversations.find((c) => c.id === conversation.id)?.messages ?? messages;
      const errorKindKey = mapErrorKindKey(pe.kind);
      // Same check as operations-send: stream-runner already attached the verdict to the error. Retrying reuses retryMessage.
      const additionalBodyRetry = Boolean(err && typeof err === 'object'
        && (err as { additionalBodyRetryEligible?: unknown }).additionalBodyRetryEligible === true);
      // Custom request fields fail closed: the body copy is localized per rejection reason, the
      // same way operations-send and the edit page do it. `ProviderErrorKind` is a closed union
      // in core, while the proxy layer's kind is the free-form string passed through from
      // `event.errorKind` (`moderation` is not in the union either). Widening it explicitly here
      // is safer than adding a member that only this path can produce to the shared error map.
      const customFragmentFailure = customFragmentFailurePatch(pe, te, (owner) => customFragmentAllowedPaths(model, owner));
      // library_* thrown while gathering evidence is a different failure class from a model
      // stream fault (same patch as operations-send).
      const libraryFailure = libraryFailurePatch(err, libraryFailurePresentation);
      // A locally rejected additional body: the text is the reason plus "nothing was sent", and the
      // technical detail is only the safe code (no retry affordance, see the bubble).
      const additionalBodyFailure = additionalBodyFailurePatch(err, te);
      // Persist stopReason: hadContent only looks at the answer body (including what existed before the continuation), not reasoning.
      // A user cancel that ends by throwing records interrupted; a context overflow records context_window_exceeded (same as operations-send).
      const failureStopReason = abortRequested
        ? 'interrupted' as const
        : isContextOverflowFailure(err, provider.kind, requestRelayTransport)
        ? 'context_window_exceeded' as const
        : stopReasonFromError(err, provider.kind, partialText.trim() !== '');
      const failedMessages = failedBase.map((m) =>
        m.id === messageId
          ? {
              ...m,
              text: partialText,
              ...(mergedReasoning ? { reasoningText: mergedReasoning } : {}),
              state: 'failed' as const,
              stopReason: failureStopReason,
              // A provider-sourced title is stored as the English source string and translated at render time (same as operations-send).
              errorTitle: additionalBodyRetry ? te('additionalBodyRejected.upstreamTitle')
                : pe.source === 'provider' ? PROVIDER_REQUEST_FAILED_TITLE : te(`${errorKindKey}.title`),
              ...(additionalBodyRetry ? { additionalBodyRetryEligible: true } : {}),
              errorDetail: additionalBodyFailure ? additionalBodyFailure.errorDetail : customFragmentFailure
                ? customFragmentFailure.errorDetail
                // Relay guidance: the body is stored as the English guidance source sentence and localized at render time; the raw upstream text goes to technical detail (same as operations-send).
                : pe.relayGuidance ? pe.message : (pe.detail || pe.message || ''),
              ...(typeof pe.kind === 'string' ? { errorKind: pe.kind } : {}),
              ...(typeof pe.source === 'string' ? { errorSource: pe.source } : {}),
              ...(additionalBodyFailure ? { errorTechnicalDetail: additionalBodyFailure.errorTechnicalDetail }
                : customFragmentFailure?.errorTechnicalDetail ? { errorTechnicalDetail: customFragmentFailure.errorTechnicalDetail }
                : pe.relayGuidance && pe.detail ? { errorTechnicalDetail: pe.detail }
                // In-stream error frame: once classified, keep the upstream text (already redacted and truncated by the sender) as technical detail, same as operations-send.
                : pe.streamErrorFrame && pe.message ? { errorTechnicalDetail: pe.message } : {}),
              ...(libraryFailure ?? {}),
            }
          : m,
      );
      if (!alreadyTerminal) {
        store.getState().updateConversation(conversation.id, {
          messages: failedMessages,
          ...deriveConversationMetadata(conversation, failedMessages),
          updatedAt: computeConversationActivityAt(failedMessages, conversation.createdAt),
        });
      }
      if (shouldReportProviderError(err)) {
        Sentry.captureException(createProviderSentryError(err), {
          ...buildProviderSentryContext(provider.kind, err),
          tags: {
            module: 'chat.stream',
            'provider.kind': provider.kind,
            'provider.error': pe?.kind ?? 'non_provider',
            'model.id': model.id,
            flow: 'continue',
          },
        });
      }
    } finally {
      clearOwnLibraryConfirmation(store, ownConfirmationIds);
      store.getState().clearStreamingForConversation(conversation.id);
    }
  })();

  return {
    convId: conversation.id,
    msgId: messageId,
    abort: requestAbort,
    done,
    attemptKind: 'continue',
  };
}

/**
 * Strip the error presentation metadata left behind by the previous failed round. A continuation
 * reuses the same assistant message, so the accumulated text and usage stay; only the fields that
 * describe the failure are cleared. Retry's clearReusableAssistantState goes further, because a
 * retry starts the round over and must also drop the usage and cost of the abandoned attempt.
 */
function clearErrorPresentationState(message: ChatMessage): ChatMessage {
  const clean = { ...message };
  delete clean.errorTitle;
  delete clean.errorDetail;
  delete clean.errorKind;
  delete clean.errorSource;
  delete clean.errorTechnicalDetail;
  delete clean.additionalBodyRetryEligible;
  return clean;
}
