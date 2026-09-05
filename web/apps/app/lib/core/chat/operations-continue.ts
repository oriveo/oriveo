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
import type { ContentPart } from '../providers/types';
import type { GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import { buildChatHistory, mapErrorKindKey, sanitizeOutboundMessages } from '../../utils/chat-stream-utils';
import { processImageAttachments, backfillStorageRefs } from '../../utils/stream-image-utils';
import { CUSTOM_FRAGMENT_ERROR_KIND, customFragmentRejectionCopyKey } from './custom-fragment-rejection';
import { getSyncAdapter } from '../sync-port';
import { deriveConversationMetadata, computeConversationActivityAt } from '../conversation-metadata';
import { withErrorReporting } from '../../sentry/report-silent';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent, filterGenerationParameterOverrides, filterRequestCapabilityIntent, providerControlsAreManaged } from './stream-options';
import { generationParameterProfileFingerprint, resolveGenerationParameterOverrides } from './generation-parameter-settings';
import { capabilityRuntimeIdentity, resolveCapabilityPreferences } from './capability-preference-settings';
import { forwardPortCustomFragmentsIfNeeded, resolveCustomFragments } from './custom-fragment-settings';
import { webPreferenceReachesTheWire } from './capability-control-presentation';
import { getCapabilityRuntime } from '../metadata/metadata-client';
import { resolveModelCapabilityEvidence } from './capability-evidence';
import { trackEvent, telemetryProviderKind, telemetryModelID } from '../telemetry';
import * as Sentry from '@sentry/nextjs';
import { mergeCitationsWithExisting, deriveCostFields, mergeMessageUsageFields } from './cost-fields';
import {
  buildProviderSentryContext,
  normalizeChatFailure,
  shouldReportProviderError,
  createProviderSentryError,
} from './error-reporting';
import { recalculateConversationCost, shouldTrackProviderUsage } from './usage-tracking';
import { runStreamPipeline } from './stream-runner';
import {
  REMINDER_PREFIX,
  buildPromptInjectionContext,
  fitWrappedSegment,
} from './prompt-injection';
import type { ChatOpCtx, SendHandle } from './operations';
import { clearOwnLibraryConfirmation, requestLibraryConfirmation } from '../library/confirmation';
import type { LibraryConfirmationRequest } from '../library/types';
import { LibraryResearchCancelledError } from './library-agent-loop';
import { libraryFailurePatch, type LibraryFailurePresentation } from './library-failure';
import { libraryDocumentRefsFromCitations } from './library-direct-context';
import { appendTextToLatestUserMessage, prepareLibraryDirectContext } from './operations-send';
import { continuationCaptured, continuationForExplicitContinue, continuationSendCompleted, continuationSendInterrupted, continuationSendStarted } from './continuation-lifecycle';

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

  const done = (async () => {
    try {
      const continuation = await continuationForExplicitContinue(conversation.id, messageId);
      // Capture is read before started clears the old state. From here every lifecycle write is
      // serialized, so a stale continuation cannot survive a successful or interrupted retry.
      await Promise.resolve(continuationSendStarted(conversation.id, messageId)).catch(() => undefined);
      if (directContextDocuments.length > 0) {
        setAbortFn(() => directContextController.abort());
      }
      // The continuation target is an assistant message that is not finished yet, so it must not
      // be resent as an ordinary history entry. The recipe compiler inserts the opaque replay
      // right before the last user continuation; when local state is missing or damaged the
      // resend degrades to a plain user continuation and never synthesizes assistant history.
      const sanitizedHistory = sanitizeOutboundMessages(
        messages.slice(0, msgIndex),
      );
      const attachmentScopeOptions = buildProviderStreamOptions(
        provider,
        buildStreamOptionsFromIntent(model, reasoningMode, webSearchEnabled),
        model,
      );
      const mayInjectVision = resolveModelCapabilityEvidence({
        key: 'vision_input', provider, model, streamOptions: attachmentScopeOptions,
      }).support === 'supported';
      const historyUpToInterrupted = mayInjectVision
        ? sanitizedHistory
        : sanitizedHistory.map((message) => ({
          ...message,
          attachments: message.attachments?.filter((attachment) => attachment.kind !== 'image'),
        }));

      const chatHistory = await buildChatHistory(historyUpToInterrupted, model, provider.kind);
      const explicitContinueInput = { role: 'user' as const, content: '[Continue from where you left off]' };
      if (continuation?.kind === 'previous_id') {
        // Stateful Responses/Interactions already own the prior context. Sending the full local
        // transcript again alongside previous_*_id duplicates context and can change semantics.
        chatHistory.splice(0, chatHistory.length, explicitContinueInput);
      } else {
        chatHistory.push(explicitContinueInput);
      }
      const latestUserText = [...historyUpToInterrupted].reverse()
        .find((m) => m.role === 'user')
        ?.text ?? existingText;
      const promptContext = await buildPromptInjectionContext(store, conversation, latestUserText, model, provider.kind);
      const directContext = directContextDocuments.length > 0
          ? await prepareLibraryDirectContext({
            documents: directContextDocuments,
            provider,
            model,
            researchId: messageId,
            signal: directContextController.signal,
            requestConfirmation: requestOwnConfirmation,
            onQuota: (quota) => store.getState().setLibraryQuota(quota),
          })
        : undefined;
      const systemContent = [promptContext.systemContent, directContext?.systemInstruction]
        .filter(Boolean)
        .join('\n\n');
      if (systemContent) {
        chatHistory.unshift({ role: 'system', content: systemContent });
        if (promptContext.memoryInjected) {
          store.getState().incrementMemoryUsageCount();
        }
      }

      if (directContext) {
        appendTextToLatestUserMessage(chatHistory, directContext.userContext);
      }

      const prefs = store.getState().preferences;
      if (prefs.memoryAntiForgetEnabled && promptContext.useMemory) {
        const userMsgCount = chatHistory.filter((m) => m.role === 'user').length;
        const summaryText = prefs.memoryAntiForgetText?.trim();
        if (userMsgCount >= 10 && summaryText) {
          const reminder = fitWrappedSegment(REMINDER_PREFIX, summaryText, ']', promptContext.remainingChars);
          if (reminder) {
            for (let i = chatHistory.length - 1; i >= 0; i--) {
              if (chatHistory[i].role === 'user') {
                const original = chatHistory[i].content;
                const textContent = typeof original === 'string'
                  ? original
                  : original.map((p: ContentPart) => p.type === 'text' ? p.text : '').join('');
                chatHistory[i] = { ...chatHistory[i], content: `${textContent}\n\n${reminder}` };
                break;
              }
            }
          }
        }
      }

      const clientControlsAllowed = !providerControlsAreManaged(provider);
      const unresolvedGenerationParameters = clientControlsAllowed ? resolveGenerationParameterOverrides({
        providerId: provider.id,
        modelId: model.id,
        profileFingerprint: generationParameterProfileFingerprint(provider, model),
        conversationId: conversation.id,
        transient: transientGenerationParameters,
        reasoningMode,
      }) : undefined;
      const capabilityIdentity = clientControlsAllowed ? capabilityRuntimeIdentity(provider, model) : null;
      // Continuing an answer is a discrete event too. Typed preferences are advanced by the read
      // chain itself, while local custom fields are run explicitly once here.
      if (capabilityIdentity) {
        forwardPortCustomFragmentsIfNeeded({
          provider, model, transportIdentity: capabilityIdentity.transportIdentity,
        });
      }
      const capabilityPreferences = capabilityIdentity ? resolveCapabilityPreferences({
        ...capabilityIdentity, conversationId: conversation.id,
        skillId: conversation.skillId,
        singleSend: directContextDocuments.length > 0 ? { web: 'off' } : undefined,
      }) : undefined;
      const preliminaryOptions = clientControlsAllowed ? buildProviderStreamOptions(
        provider,
        buildStreamOptionsFromIntent(model, reasoningMode, directContextDocuments.length > 0 ? false : webSearchEnabled, unresolvedGenerationParameters, capabilityPreferences),
        model,
      ) : undefined;
      const requestIntent = clientControlsAllowed ? filterRequestCapabilityIntent({
        provider,
        model,
        reasoningMode,
        webSearchEnabled: directContextDocuments.length > 0 ? false : webSearchEnabled,
        // A preference that cannot reach the wire right now does not count as an explicit web request.
        webReachesTheWire: webPreferenceReachesTheWire({
          provider, model, ...(capabilityIdentity ? { transportIdentity: capabilityIdentity.transportIdentity } : {}),
        }),
        streamOptions: preliminaryOptions,
      }) : { supportsWebSearch: false };
      // Same filter as `operations-send`: excludeCustomFragments turns the whole set off, while
      // excludeCustomFragmentOwners removes only the named owners.
      const resolvedContinueFragments = clientControlsAllowed && !excludeCustomFragments
        ? resolveCustomFragments({
          provider, model, transportIdentity: capabilityIdentity?.transportIdentity ?? '',
          allow: !directContextDocuments.length,
          runtime: getCapabilityRuntime(),
        })
        : undefined;
      const continueFragmentEntries = resolvedContinueFragments
        ? Object.entries(resolvedContinueFragments)
          .filter(([owner]) => !excludeCustomFragmentOwners.includes(owner as 'web' | 'reasoning' | 'generation'))
        : [];
      const continueCustomFragments = continueFragmentEntries.length > 0
        ? Object.fromEntries(continueFragmentEntries)
        : undefined;
      const streamOptions = clientControlsAllowed ? buildStreamOptionsFromIntent(
        model,
        requestIntent.reasoning,
        requestIntent.supportsWebSearch,
        filterGenerationParameterOverrides(provider, model, unresolvedGenerationParameters, preliminaryOptions),
        requestIntent.capabilityPreferences,
        continueCustomFragments,
      ) : undefined;
      const providerStreamOptions = clientControlsAllowed ? buildProviderStreamOptions(provider, streamOptions, model) : undefined;

      // Continuation is a real outbound request and uses the same gate as sendMessage: web search
      // counts as used only when the web configuration actually made it into this request. The
      // gate is the final outbound options rather than user intent -- when the facade rejects it,
      // or the transport envelope cannot carry web search (the intersection done in
      // `buildProviderStreamOptions`), nothing is sent even with the toggle on.
      // Field boundary: provider_kind / model_id are reported as registered, while execution
      // facts such as recipe identity, requested/observed state, search terms and response
      // evidence never enter telemetry.
      if (providerStreamOptions?.supportsWebSearch) {
        trackEvent('web_search_used', {
          provider_kind: telemetryProviderKind(provider.kind),
          model_id: telemetryModelID(provider.kind, model.id),
        });
      }

      const pipeline = await runStreamPipeline({
        store,
        appendChunk,
        conversationId: conversation.id,
        messageId,
        provider,
        model,
        chatHistory,
        initialText: existingText,
        relayStreamOptions: providerStreamOptions,
        setAbortFn,
        suppressStreamCitations: directContextDocuments.length > 0,
        continuation,
        onContinuation: (next) => continuationCaptured(conversation.id, messageId, next),
      });

      if (pipeline.outcome === 'guarded') {
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

      const completedMsg: ChatMessage = {
        ...interruptedMsg, text: finalText, state: 'delivered' as const,
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
      };

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
      const partialText = partialState.streamingTexts[conversation.id] || existingText;
      const partialReasoning = (partialState.streamingReasoningTexts[conversation.id] ?? '').trim();
      const mergedReasoning =
        [interruptedMsg.reasoningText, partialReasoning].filter(Boolean).join('\n\n') || undefined;
      // Replace the continuation target against the store's latest messages rather than the
      // snapshot, so concurrent writes during the continuation are not overwritten.
      const failedBase = store.getState().conversations.find((c) => c.id === conversation.id)?.messages ?? messages;
      const errorKindKey = mapErrorKindKey(pe.kind);
      const errorTitleKey = pe.source === 'provider' ? 'requestFailed' : errorKindKey;
      // Custom request fields fail closed: the body copy is localized per rejection reason, the
      // same way operations-send and the edit page do it. `ProviderErrorKind` is a closed union
      // in core, while the proxy layer's kind is the free-form string passed through from
      // `event.errorKind` (`moderation` is not in the union either). Widening it explicitly here
      // is safer than adding a member that only this path can produce to the shared error map.
      const customFragmentReasonKey = (pe.kind as string) === CUSTOM_FRAGMENT_ERROR_KIND
        ? customFragmentRejectionCopyKey(pe.detail || pe.message || '')
        : undefined;
      // library_* thrown while gathering evidence is a different failure class from a model
      // stream fault (same patch as operations-send).
      const libraryFailure = libraryFailurePatch(err, libraryFailurePresentation);
      const failedMessages = failedBase.map((m) =>
        m.id === messageId
          ? {
              ...m,
              text: partialText,
              ...(mergedReasoning ? { reasoningText: mergedReasoning } : {}),
              state: 'failed' as const,
              errorTitle: te(`${errorTitleKey}.title`),
              errorDetail: customFragmentReasonKey
                ? te(`${errorKindKey}.${customFragmentReasonKey}`)
                : (pe.detail || pe.message || ''),
              ...(typeof pe.kind === 'string' ? { errorKind: pe.kind } : {}),
              ...(typeof pe.source === 'string' ? { errorSource: pe.source } : {}),
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
  };
}

/**
 * Strip the error presentation metadata left behind by the previous failed round.
 * managedRequestId / lastSseSequence are kept: continuation relies on them to replay the
 * server-side cursor. Retry's clearReusableAssistantState does the opposite, because a retry is a
 * brand new request and must drop the session identifiers as well.
 */
function clearErrorPresentationState(message: ChatMessage): ChatMessage {
  const clean = { ...message };
  delete clean.errorTitle;
  delete clean.errorDetail;
  delete clean.errorKind;
  delete clean.errorSource;
  delete clean.managedErrorCode;
  delete clean.managedErrorMessage;
  delete clean.managedErrorAction;
  delete clean.managedErrorReasonCode;
  delete clean.managedErrorRiskRef;
  delete clean.managedErrorRetryAt;
  delete clean.managedErrorTraceId;
  delete clean.managedPartialErrorCode;
  delete clean.managedPartialErrorMessage;
  delete clean.managedPartialErrorAction;
  return clean;
}
