/**
 * sendMessage - send a new message, including the first message of a new conversation.
 *
 * Flow: store update -> stream execution -> sync notification -> attachment upload
 */
import type { ChatMessage, Conversation, AIModel, Provider, Attachment, ReasoningMode, QuoteContext } from '@oriveo/shared';
import type { ContentPart } from '../providers/types';
import type { CapabilityPreferenceInput, GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import { networkError, type ProviderError } from '../providers/errors';
import { buildChatHistory, mapErrorKindKey, sanitizeOutboundMessages } from '../../utils/chat-stream-utils';
import { processImageAttachments, backfillStorageRefs } from '../../utils/stream-image-utils';
import { createUserMessage, createAssistantMessage } from './message-factory';
import { upsertMessages } from './message-merge';
import { deriveConversationMetadata, computeConversationActivityAt } from '../conversation-metadata';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent, filterGenerationParameterOverrides, filterRequestCapabilityIntent, providerControlsAreManaged } from './stream-options';
import { generationParameterProfileFingerprint, resolveGenerationParameterOverrides } from './generation-parameter-settings';
import { capabilityRuntimeIdentity, resolveCapabilityPreferences } from './capability-preference-settings';
import { migrateDraftScopedModelControls } from './draft-scope-migration';
import { CUSTOM_FRAGMENT_ERROR_KIND, customFragmentRejectionCopyKey } from './custom-fragment-rejection';
import { forwardPortCustomFragmentsIfNeeded, resolveCustomFragments } from './custom-fragment-settings';
import { webPreferenceReachesTheWire } from './capability-control-presentation';
import { getCapabilityRuntime } from '../metadata/metadata-client';
import { resolveModelCapabilityEvidence } from './capability-evidence';
import { trackEvent, telemetryProviderKind, telemetryModelID } from '../telemetry';
import { relaySendTelemetryProperties } from '../telemetry/relay-properties';
import * as Sentry from '@sentry/nextjs';
import { deriveCostFields, mergeMessageUsageFields } from './cost-fields';
import { mergeCitationsWithExisting } from './cost-fields';
import {
  buildProviderSentryContext,
  normalizeChatFailure,
  shouldReportProviderError,
  createProviderSentryError,
} from './error-reporting';
import { recalculateConversationCost } from './usage-tracking';
import {
  REMINDER_PREFIX,
  buildPromptInjectionContext,
  fitWrappedSegment,
} from './prompt-injection';
import { runStreamPipeline } from './stream-runner';
import { prepareSendStart, reportSendStartedTelemetry } from './send-start';
import { reportSendCompletion } from './send-completion';
import { continuationCaptured, continuationSendCompleted, continuationSendInterrupted, continuationSendStarted } from './continuation-lifecycle';
import { getSyncAdapter } from '../sync-port';
import type { ChatOpCtx, SendHandle } from './operations';
import type {
  LibraryConfirmationRequest,
  LibraryDocumentRef,
  LibraryProvider,
  LibraryReadResult,
} from '../library/types';
import { executeLibraryResearch, executeLibraryTool } from '../library/api';
import { clearOwnLibraryConfirmation, requestLibraryConfirmation } from '../library/confirmation';
import {
  getLibraryRuntimeConfig,
  resolveCatalogModel,
} from '../metadata/metadata-client';
import { LibraryResearchCancelledError } from './library-agent-loop';
import { libraryFailurePatch, type LibraryFailurePresentation } from './library-failure';
import {
  dedupeLibraryDocumentRefs,
  libraryDocumentRefsFromCitations,
  libraryDocumentRefsToPendingCitations,
  readLibraryDirectContext,
} from './library-direct-context';
import {
  runLibraryServerResearch,
  type LibraryServerResearchResult,
} from './library-server-research';

export function sendMessage(
  ctx: ChatOpCtx,
  params: {
    text: string;
    prevMessages: ChatMessage[];
    conversation: Conversation | undefined;
    provider: Provider;
    model: AIModel;
    reasoningMode: ReasoningMode;
    webSearchEnabled?: boolean;
    attachments?: Attachment[];
    quoteContext?: QuoteContext;
    skillId?: string;
    userMessageOverride?: ChatMessage;
    assistantMessageOverride?: ChatMessage;
    persistUserMessage?: boolean;
    userMessageAlreadyInHistory?: boolean;
    pinnedNoteIds?: string[];
    onNewConversation?: (convId: string) => void;
    onFailed?: (text: string) => void;
    libraryContextDocuments?: LibraryDocumentRef[];
    libraryContextCancelledText?: string;
    /**
     * Localized copy for library failures. Without it, library_* errors can only show the raw
     * server English, and the recovery card cannot tell which CTA belongs there (reconnect in
     * the library, or view the options).
     */
    libraryFailurePresentation?: LibraryFailurePresentation;
    /**
     * Optional local catalog research payload.
     */
    libraryServerResearch?: {
      query: string;
      sources?: LibraryProvider[];
    };
    /** Continuation: use the caller-supplied history, including the continuation marker, instead of prevMessages. */
    historyMessages?: ChatMessage[];
    /** Continuation: append the new body after the existing assistantMessageOverride body instead of replacing it. */
    appendToAssistant?: boolean;
    generationParameterDraftSessionId?: string;
    /**
     * One-shot value, the highest priority level of the generation parameter scope chain.
     * There is no UI producer for it today; it is a pass-through slot for callers that need a
     * value to apply to this send only. Never persisted, never synced.
     */
    transientGenerationParameters?: GenerationParameterOverrides;
    /** Typed intent from the caller; final scope resolution happens after a new conversation gets its id. */
    capabilityPreferences?: CapabilityPreferenceInput;
    /** Explicit user-confirmed recovery only: keep saved custom fields, omit them for this new request. */
    excludeCustomFragments?: boolean;
    /** Explicit resend only: omit the located custom source owner(s), not official recipes. */
    excludeCustomFragmentOwners?: Array<'web' | 'reasoning' | 'generation'>;
    /** Exact official recipe setting(s) omitted only for this confirmed resend. */
    capabilityRecipeOmissions?: Array<{ recipeRef: string; locatedPointers: string[] }>;
    /** One-request latch that lets the rejected owner leave dormant for exact resend. */
    capabilityRecipeResendOwners?: Array<'web' | 'reasoning' | 'generation'>;
    /** Explicit resend only: omit exactly the rejected capability owner(s) for this request. */
    excludeCapabilityOwners?: Array<'web' | 'reasoning' | 'generation'>;
  },
): SendHandle {
  const { store, appendChunk, te } = ctx;
  const {
    text,
    prevMessages,
    conversation,
    provider,
    model,
    reasoningMode,
    webSearchEnabled,
    attachments,
    quoteContext,
    skillId,
    userMessageOverride,
    assistantMessageOverride,
    persistUserMessage = true,
    userMessageAlreadyInHistory = false,
    pinnedNoteIds,
    onNewConversation,
    onFailed,
    libraryContextDocuments,
    libraryContextCancelledText = 'Library context reading was cancelled.',
    libraryFailurePresentation,
    libraryServerResearch,
    historyMessages,
    appendToAssistant = false,
    generationParameterDraftSessionId,
    transientGenerationParameters,
    capabilityPreferences,
    excludeCustomFragments = false,
    excludeCustomFragmentOwners = [],
    capabilityRecipeOmissions = [],
    capabilityRecipeResendOwners = [],
    excludeCapabilityOwners = [],
  } = params;

  const userMsg = userMessageOverride ?? createUserMessage({ text, provider, model, attachments, quoteContext });
  // On a libraryResearchEnabled message the citations are evidence the research mode found on
  // its own, not documents the user named. Without this guard, restoring a server-search or
  // agent-search message pins the previous round's evidence as direct documents: chips the user
  // never ticked appear on the bubble, and a search that should re-run degrades into re-reading
  // the old documents one by one.
  const inheritedContextDocuments = assistantMessageOverride?.libraryResearchEnabled
    ? []
    : libraryDocumentRefsFromCitations(assistantMessageOverride?.citations);
  const directContextDocuments = dedupeLibraryDocumentRefs(
    libraryContextDocuments ?? inheritedContextDocuments,
  );
  // Server-side search and named documents are mutually exclusive: both inject evidence, so enabling them together only splits the budget in half.
  const serverResearch = directContextDocuments.length > 0 ? undefined : libraryServerResearch;
  const baseAssistantMsg = assistantMessageOverride ?? createAssistantMessage({ provider, model, baseCreatedAt: userMsg.createdAt });
  const assistantMsg: ChatMessage = directContextDocuments.length > 0
    ? {
        ...baseAssistantMsg,
        citations: libraryDocumentRefsToPendingCitations(directContextDocuments),
      }
    : serverResearch
      // libraryResearchEnabled is the retry switch: without it, retrying this message falls back
      // to a plain send, so "retry" would quietly drop the server-side search.
      ? { ...baseAssistantMsg, libraryResearchEnabled: true }
      : baseAssistantMsg;
  const initialAssistantText = appendToAssistant ? (assistantMsg.text ?? '') : '';
  const effectiveWebSearchEnabled = directContextDocuments.length > 0 || serverResearch
    ? false
    : webSearchEnabled;

  let abortFn: (() => void) | null = null;
  let abortRequested = false;
  let abortInvoked = false;
  let researchSteps: ChatMessage['researchSteps'];
  const directContextController = new AbortController();
  // Record the confirmation ids this send raised, so cleanup clears only its own and does not dismiss a dialog another conversation is waiting on.
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

  const { finalConvId, isFirstMessage, initialConversationSnapshot, sendStartedAt } = prepareSendStart({
    store,
    userMsg,
    assistantMsg,
    prevMessages,
    persistUserMessage,
    conversation,
    provider,
    model,
    reasoningMode,
    webSearchEnabled: effectiveWebSearchEnabled,
    attachments,
    skillId,
    pinnedNoteIds,
    onNewConversation,
  });
  // Local-only pending marker: no sync/backup/telemetry. Completion removes a bare marker but
  // retains a complete captured tool block for an explicit later continue; refresh never resumes.
  void Promise.resolve(continuationSendStarted(finalConvId, assistantMsg.id)).catch(() => undefined);
  // New conversation: both kinds of draft move together, all of it inside `migrateDraftScopedModelControls` (see its comment).
  migrateDraftScopedModelControls({
    provider,
    model,
    conversation,
    draftSessionId: generationParameterDraftSessionId,
    conversationId: finalConvId,
  });

  const done = (async () => {
    try {
      if (directContextDocuments.length > 0 || serverResearch) {
        setAbortFn(() => directContextController.abort());
      }
      if (typeof navigator !== 'undefined' && !navigator.onLine) {
        // Use the networkError helper rather than a hand-made literal: it returns a real Error
        // subclass, so throwing carries a stack for Sentry. The UI error card is still rendered
        // by te(`network.title`) in the catch block, independent of this message.
        throw networkError(new Error('navigator.onLine === false'));
      }

      // Tidy up before sending: drop assistant turns with empty content and failed turns, keep
      // interrupted/generating turns that have content, and collapse adjacent user turns to the
      // newest one (see sanitizeOutboundMessages). Empty content makes some relay gateways hold
      // a persistent RST, and stale turns make the model answer a stopped question together
      // with the new one.
      const sanitizedOutboundMessages = sanitizeOutboundMessages(
        historyMessages ??
          (userMessageAlreadyInHistory ? prevMessages : [...prevMessages, userMsg]),
        appendToAssistant ? assistantMsg.id : undefined,
      );
      const attachmentScopeOptions = buildProviderStreamOptions(
        provider,
        buildStreamOptionsFromIntent(model, reasoningMode, webSearchEnabled),
        model,
      );
      const mayInjectVision = resolveModelCapabilityEvidence({
        key: 'vision_input', provider, model, streamOptions: attachmentScopeOptions,
      }).support === 'supported';
      const outboundMessages = mayInjectVision
        ? sanitizedOutboundMessages
        : sanitizedOutboundMessages.map((message) => ({
          ...message,
          attachments: message.attachments?.filter((attachment) => attachment.kind !== 'image'),
        }));
      const chatHistory = await buildChatHistory(outboundMessages, model, provider.kind);
      const effectiveConversation = conversation ?? initialConversationSnapshot;

      // System prompt injection: skill prompt + knowledge files + memory, all handled by buildSystemPromptContent.
      const promptContext = await buildPromptInjectionContext(store, effectiveConversation, text, model, provider.kind);
      let systemContent = promptContext.systemContent;
      // Both paths produce the same payload shape (systemInstruction / userContext / citations),
      // so injection, citation persistence and citation suppression below read this one variable.
      const libraryContext = directContextDocuments.length > 0
          ? await prepareLibraryDirectContext({
            documents: directContextDocuments,
            provider,
            model,
            researchId: assistantMsg.id,
            signal: directContextController.signal,
            requestConfirmation: requestOwnConfirmation,
            onQuota: (quota) => store.getState().setLibraryQuota(quota),
            // The step list is persisted with the message: the recovery route only looks at
            // libraryResearchEnabled, so researchSteps is not a route marker. It is kept so that
            // reviewing an old message still shows which documents were read at the time.
            onSteps: (steps) => {
              researchSteps = steps;
              store.getState().setLibraryResearchSteps(finalConvId, steps);
              applyResearchStepsToMessage(store, finalConvId, assistantMsg.id, steps);
            },
          })
        : serverResearch
          ? await prepareLibraryServerResearch({
            query: serverResearch.query,
            sources: serverResearch.sources,
            provider,
            model,
            researchId: assistantMsg.id,
            signal: directContextController.signal,
            requestConfirmation: requestOwnConfirmation,
            onQuota: (quota) => store.getState().setLibraryQuota(quota),
            onSteps: (steps) => {
              researchSteps = steps;
              store.getState().setLibraryResearchSteps(finalConvId, steps);
              applyResearchStepsToMessage(store, finalConvId, assistantMsg.id, steps);
            },
          })
        : undefined;
      if (libraryContext) {
        systemContent = systemContent
          ? `${systemContent}\n\n${libraryContext.systemInstruction}`
          : libraryContext.systemInstruction;
      }

      // With attachments, append a system prompt hint so the model does not invent content.
      const hasAttachments = outboundMessages.some((message) => message.id === userMsg.id && (message.attachments?.length ?? 0) > 0);
      if (hasAttachments) {
        const { AttachmentInjector } = await import('../attachments/attachment-injector');
        const guidance = AttachmentInjector.SYSTEM_PROMPT_GUIDANCE;
        systemContent = systemContent ? `${systemContent}\n\n${guidance}` : guidance;
      }

      if (systemContent) {
        chatHistory.unshift({ role: 'system', content: systemContent });
        if (promptContext.memoryInjected) {
          store.getState().incrementMemoryUsageCount();
        }
      }

      // Anti-forgetting mode: past 10 user turns, append a summary reminder to the last user message.
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
                const textContent = typeof original === 'string' ? original : original.map((p: ContentPart) => p.type === 'text' ? p.text : '').join('');
                chatHistory[i] = { ...chatHistory[i], content: `${textContent}\n\n${reminder}` };
                break;
              }
            }
          }
        }
      }

      if (libraryContext) {
        appendTextToLatestUserMessage(chatHistory, libraryContext.userContext);
      }

      const clientControlsAllowed = !providerControlsAreManaged(provider);
      const unresolvedGenerationParameters = clientControlsAllowed && !excludeCapabilityOwners.includes('generation') ? resolveGenerationParameterOverrides({
        providerId: provider.id,
        modelId: model.id,
        profileFingerprint: generationParameterProfileFingerprint(provider, model),
        conversationId: finalConvId,
        transient: transientGenerationParameters,
        // When a chip selects a tier explicitly, the connection-level reasoning defaults step aside as a group.
        reasoningMode,
        // The final facade filter below is the sole request gate. Do not
        // pre-drop values here: it would make lifecycle and request policy
        // diverge after metadata/identity changes.
      }) : undefined;
      const capabilityIdentity = clientControlsAllowed ? capabilityRuntimeIdentity(provider, model) : null;
      // Sending is a discrete event, so forward porting runs once here. Typed preferences are
      // ported by the read chain inside `resolveCapabilityPreferences`; local custom fields have
      // no such chain and must be ported explicitly.
      if (capabilityIdentity) {
        forwardPortCustomFragmentsIfNeeded({
          provider, model, transportIdentity: capabilityIdentity.transportIdentity,
        });
      }
      const storedCapabilityPreferences = clientControlsAllowed ? capabilityPreferences ?? (capabilityIdentity
        ? resolveCapabilityPreferences({
          ...capabilityIdentity, conversationId: finalConvId, skillId,
          singleSend: directContextDocuments.length > 0 || serverResearch ? { web: 'off' } : undefined,
        })
        : undefined) : undefined;
      const resolvedCapabilityPreferences = storedCapabilityPreferences ? {
        ...storedCapabilityPreferences,
        ...(excludeCapabilityOwners.includes('web') ? { web: 'off' as const } : {}),
        ...(excludeCapabilityOwners.includes('reasoning') ? { reasoningIntent: undefined } : {}),
      } : undefined;
      const preliminaryBaseOptions = clientControlsAllowed ? buildProviderStreamOptions(
        provider,
        buildStreamOptionsFromIntent(model, reasoningMode, effectiveWebSearchEnabled, unresolvedGenerationParameters, resolvedCapabilityPreferences),
        model,
      ) : undefined;
      const preliminaryOptions = capabilityRecipeResendOwners.length > 0
        ? { ...preliminaryBaseOptions, capabilityRecipeResendOwners }
        : preliminaryBaseOptions;
      const requestIntent = clientControlsAllowed ? filterRequestCapabilityIntent({
        provider, model, reasoningMode, webSearchEnabled: effectiveWebSearchEnabled,
        // A preference that cannot reach the wire right now does not count as an explicit web search request.
        webReachesTheWire: webPreferenceReachesTheWire({
          provider, model, ...(capabilityIdentity ? { transportIdentity: capabilityIdentity.transportIdentity } : {}),
        }),
        streamOptions: preliminaryOptions,
      }) : { supportsWebSearch: false };
      const generationParameters = clientControlsAllowed ? filterGenerationParameterOverrides(
        provider,
        model,
        unresolvedGenerationParameters,
        preliminaryOptions,
      ) : undefined;
      const resolvedCustomFragments = clientControlsAllowed && !excludeCustomFragments ? resolveCustomFragments({
        provider, model, transportIdentity: capabilityIdentity?.transportIdentity ?? '',
        // Named-library documents and server research are a distinct request shape.
        allow: !directContextDocuments.length && !serverResearch,
        runtime: getCapabilityRuntime(),
      }) : undefined;
      const customFragmentEntries = resolvedCustomFragments
        ? Object.entries(resolvedCustomFragments)
          .filter(([owner]) => !excludeCustomFragmentOwners.includes(owner as 'web' | 'reasoning' | 'generation'))
        : [];
      const customFragments = customFragmentEntries.length > 0
        ? Object.fromEntries(customFragmentEntries)
        : undefined;
      const streamOptions = clientControlsAllowed ? buildStreamOptionsFromIntent(
        model,
        requestIntent.reasoning,
        requestIntent.supportsWebSearch,
        generationParameters,
        requestIntent.capabilityPreferences,
        customFragments,
      ) : undefined;
      const streamOptionsWithRecovery = capabilityRecipeOmissions.length > 0 || capabilityRecipeResendOwners.length > 0
        ? {
            ...streamOptions,
            ...(capabilityRecipeOmissions.length ? { capabilityRecipeOmissions } : {}),
            ...(capabilityRecipeResendOwners.length ? { capabilityRecipeResendOwners } : {}),
          }
        : streamOptions;
      const relayStreamOptions = clientControlsAllowed ? buildProviderStreamOptions(provider, streamOptionsWithRecovery, model) : undefined;

      // Outbound fact taken after the final facade gate: web search counts as used only once the
      // configuration really made it into this request. The gate is the final outbound options,
      // not the user's intent - if the facade rejects it, or the transport envelope does not
      // support web search (the intersection computed in `buildProviderStreamOptions`), nothing
      // is sent even with the toggle on.
      // Field boundary: provider_kind / model_id are reported as usual, since without them the
      // whole "web search usage per model" view falls apart; execution facts - recipe identifier,
      // requested/observed state, search terms, response evidence - never enter telemetry.
      if (relayStreamOptions?.supportsWebSearch) {
        trackEvent('web_search_used', {
          provider_kind: telemetryProviderKind(provider.kind),
          model_id: telemetryModelID(provider.kind, model.id),
        });
      }

      const pipeline = await runStreamPipeline({
        store,
        appendChunk,
        conversationId: finalConvId,
        messageId: assistantMsg.id,
        provider,
        model,
        chatHistory,
        initialText: initialAssistantText,
        relayStreamOptions,
        setAbortFn,
        suppressStreamCitations: Boolean(libraryContext),
        onContinuation: (continuation) => continuationCaptured(finalConvId, assistantMsg.id, continuation),
      });

      if (pipeline.outcome === 'guarded') {
        // Guard hit: stream-runner already wrote citations back, so the transaction must not overwrite the final message state.
        return;
      }

      const {
        fullText,
        reasoningText,
        reasoningDurationMs,
        citations,
        usage,
        imageAttachments,
        servedModelID,
        capabilityResults,
        unhandledToolCalls = [],
      } = pipeline;

      for (const call of unhandledToolCalls) {
        trackEvent('tool_call_unhandled', {
          providerKind: telemetryProviderKind(provider.kind),
          transport: resolveCatalogModel(model.id, provider.kind)?.transport ?? model.transport ?? 'unknown',
          toolName: call.name,
        });
      }
      const toolCallSupport = resolveModelCapabilityEvidence({
        key: 'tool_call',
        provider,
        model,
        streamOptions: relayStreamOptions,
      }).support;
      if (unhandledToolCalls.length > 0 && toolCallSupport === 'unsupported') {
        trackEvent('tool_call_capability_mismatch', {
          providerKind: telemetryProviderKind(provider.kind),
          modelId: telemetryModelID(provider.kind, model.id),
        });
      }

      reportSendStartedTelemetry({
        finalConvId,
        isFirstMessage,
        provider,
        model,
        reasoningMode,
        webSearchEnabled: effectiveWebSearchEnabled,
        attachments,
        skillId,
      });

      const { finalText, processedAttachments } = await processImageAttachments(fullText, imageAttachments);
      const costInfo = deriveCostFields(usage, model, provider.kind, provider.authMode);
      const generationCost = costInfo.cost;
      const cost = generationCost + promptContext.retrievalCost;
      const completedAt = new Date().toISOString();

      const trimmedReasoning = reasoningText.trim();
      const mergedReasoning = appendToAssistant
        ? [assistantMsg.reasoningText, trimmedReasoning].filter(Boolean).join('\n\n')
        : trimmedReasoning;
      const mergedReasoningDurationMs = appendToAssistant
        && (assistantMsg.reasoningDurationMs !== undefined || reasoningDurationMs !== undefined)
        ? (assistantMsg.reasoningDurationMs ?? 0) + (reasoningDurationMs ?? 0)
        : reasoningDurationMs;
      const mergedAttachments = appendToAssistant
        ? [...(assistantMsg.attachments ?? []), ...processedAttachments]
        : processedAttachments;
      const mergedCitations = libraryContext
        ? libraryContext.citations
        : mergeCitationsWithExisting(appendToAssistant ? assistantMsg.citations : undefined, citations);
      const deliveredAssistantMsg: ChatMessage = {
        ...assistantMsg, text: finalText, state: 'delivered' as const,
        estimatedCost: (appendToAssistant ? assistantMsg.estimatedCost ?? 0 : 0) + cost,
        ...(mergedReasoning ? { reasoningText: mergedReasoning } : {}),
        ...(mergedReasoning && mergedReasoningDurationMs !== undefined ? { reasoningDurationMs: mergedReasoningDurationMs } : {}),
        ...(capabilityResults.length > 0 ? { capabilityResults } : {}),
        ...(unhandledToolCalls.length > 0 ? { unhandledToolCalls } : {}),
        servedModelID,
        ...(researchSteps ? { researchSteps } : {}),
        attachments: mergedAttachments.length > 0 ? mergedAttachments : undefined,
        ...(mergedCitations && mergedCitations.length > 0 ? { citations: mergedCitations } : {}),
        costSource: costInfo.costSource,
        ...mergeMessageUsageFields(appendToAssistant ? assistantMsg : {}, costInfo),
      };

      const latestConversation = store.getState().conversations.find((c) => c.id === finalConvId);
      const latestUserMsg = latestConversation?.messages.find((m) => m.id === userMsg.id) ?? userMsg;
      // Incremental upsert against the latest messages in the store rather than the prevMessages snapshot, so concurrent sends do not overwrite each other.
      const completedMessages = upsertMessages(
        latestConversation?.messages ?? prevMessages,
        persistUserMessage ? [latestUserMsg, deliveredAssistantMsg] : [deliveredAssistantMsg],
      );
      const updatedCost = recalculateConversationCost(completedMessages);
      const baseConv = conversation ?? latestConversation;
      if (!baseConv) {
        // Conversation deleted concurrently while streaming: discard this result, write nothing to the store, report no sync or telemetry.
        return;
      }
      store.getState().updateConversation(finalConvId, {
        messages: completedMessages,
        ...deriveConversationMetadata(baseConv, completedMessages),
        estimatedCost: updatedCost,
        updatedAt: computeConversationActivityAt(completedMessages, baseConv.createdAt),
      });

      // A failed half-round never goes to the cloud: the whole round (user + assistant) is synced
      // atomically from the conversation snapshot taken after the round was written back, so
      // metadata such as messageCount matches the absolute delivered count. Failures and
      // interruptions sync nothing from the catch block.
      const syncConv = store.getState().conversations.find((c) => c.id === finalConvId);
      getSyncAdapter()?.didCompleteRound(latestUserMsg, deliveredAssistantMsg, finalConvId, syncConv, updatedCost);
      reportSendCompletion({
        store,
        provider,
        model,
        conversationId: finalConvId,
        effectiveConversation,
        skillId,
        usage,
        cost,
        costSource: costInfo.costSource,
        servedModelID,
        processedAttachments,
        promptContext,
        sendStartedAt,
        completedAt,
      });
      void Promise.resolve(continuationSendCompleted(finalConvId, assistantMsg.id)).catch(() => undefined);

      // Upload attachments asynchronously.
      const allUploadableAtts: { att: Attachment; msgID: string }[] = [];
      if (userMsg.attachments) {
        for (const a of userMsg.attachments) {
          if (!a.storageRef && ((a.kind === 'image' && a.localImageID) || (a.kind === 'file' && (a.downloadBase64Data || a.base64Data)))) {
            allUploadableAtts.push({ att: a, msgID: userMsg.id });
          }
        }
      }
      for (const a of processedAttachments) {
        if (a.localImageID && !a.storageRef) allUploadableAtts.push({ att: a, msgID: deliveredAssistantMsg.id });
      }

      // Read conversations live: the backfill has to merge into the latest conversation once the upload finishes, since a snapshot would swallow edits made in the meantime.
      void backfillStorageRefs(
        finalConvId,
        allUploadableAtts,
        () => store.getState().conversations,
        store.getState().updateConversation,
      );
    } catch (err) {
      void Promise.resolve(continuationSendInterrupted(finalConvId, assistantMsg.id)).catch(() => undefined);
      if (err instanceof LibraryResearchCancelledError) {
        const cancelledAssistantMsg: ChatMessage = {
          ...assistantMsg,
          text: libraryContextCancelledText,
          state: 'delivered',
          citations: undefined,
          ...(researchSteps ? { researchSteps } : {}),
        };
        const latestConversation = store.getState().conversations.find((c) => c.id === finalConvId);
        const latestUserMsg = latestConversation?.messages.find((m) => m.id === userMsg.id) ?? userMsg;
        const completedMessages = upsertMessages(
          latestConversation?.messages ?? prevMessages,
          persistUserMessage ? [latestUserMsg, cancelledAssistantMsg] : [cancelledAssistantMsg],
        );
        const baseConv = conversation ?? latestConversation;
        if (baseConv) {
          const updatedCost = recalculateConversationCost(completedMessages);
          store.getState().updateConversation(finalConvId, {
            messages: completedMessages,
            ...deriveConversationMetadata(baseConv, completedMessages),
            estimatedCost: updatedCost,
            updatedAt: computeConversationActivityAt(completedMessages, baseConv.createdAt),
          });
          const snapshot = store.getState().conversations.find((c) => c.id === finalConvId);
          getSyncAdapter()?.didCompleteRound(latestUserMsg, cancelledAssistantMsg, finalConvId, snapshot, updatedCost);
        }
        return;
      }
      // A transport failure (connection lost, network switch, request cancelled) can still arrive
      // here as a bare `TypeError`: managed streams are normalized in `toStreamError`, but the
      // library, knowledge base and metadata fetches on the same send path have no wrapper of
      // their own. Without normalizing, `mapErrorKindKey(undefined)` lands on `upstream` and
      // renders "your network is down" as "the AI provider had a problem, try again later",
      // which only makes the user retry over and over.
      const pe = normalizeChatFailure(err);
      // stream-runner attaches capabilityResults to every stream error, even an empty array, so
      // testing whether the array exists is always true - using that as a gate would silence
      // every ordinary failure and Sentry would see no stream errors at all. The condition is
      // narrowed to "non-empty counts as carrying capability execution facts", matching the
      // telemetry side.
      const failureCapabilityResults = err && typeof err === 'object'
        && Array.isArray((err as { capabilityResults?: unknown }).capabilityResults)
        ? (err as { capabilityResults: NonNullable<ChatMessage['capabilityResults']> }).capabilityResults
        : undefined;
      const p5Failure = (failureCapabilityResults?.length ?? 0) > 0;
      reportSendStartedTelemetry({
        finalConvId,
        isFirstMessage,
        provider,
        model,
        reasoningMode,
        webSearchEnabled: effectiveWebSearchEnabled,
        attachments,
        skillId,
      });
      trackEvent('chat_message_failed', {
        provider_kind: telemetryProviderKind(provider.kind),
        model_id: telemetryModelID(provider.kind, model.id),
        // Report the normalized short slug (ProviderErrorKind) only; the raw error body never enters telemetry.
        error_code: pe?.kind ?? 'unknown',
        latency_ms: Date.now() - sendStartedAt,
        // A relay failure has to be traceable to the relay address that broke; same helper as sent/completed.
        ...relaySendTelemetryProperties(provider),
      });
      // The partial generated before the failure is still in the store's streaming map
      // (clearStreamingForConversation only runs in finally), so read it out here into the failed
      // message instead of zeroing half-written content with text:''.
      const partialState = store.getState();
      // Final-state guard (matching the guarded branch at the end of stream-runner's
      // runStreamPipeline): when an abort throws its way here, stop() has usually already marked
      // this message interrupted and cleared the streaming map. Overwriting to failed
      // unconditionally has two consequences: a deliberate stop is reported as a failure and the
      // recovery card turns from "continue" into "retry", and partialText reads '' out of the
      // cleared streaming map, wiping the interrupted body entirely.
      const guardMsg = partialState.conversations
        .find((c) => c.id === finalConvId)?.messages
        .find((m) => m.id === assistantMsg.id);
      const alreadyTerminal = guardMsg?.state === 'interrupted' || guardMsg?.state === 'failed';
      const partialText = partialState.streamingTexts[finalConvId] || guardMsg?.text || '';
      const partialReasoning = (partialState.streamingReasoningTexts[finalConvId] ?? '').trim();
      const errorKindKey = mapErrorKindKey(pe.kind);
      const errorTitleKey = pe.source === 'provider' ? 'requestFailed' : errorKindKey;
      // Custom request fields fail closed: the body becomes a localized sentence keyed by the
      // rejection reason (the same three-way split as the editor) rather than putting an internal
      // enum name such as `unknown_owned_path` in front of the user.
      // `ProviderErrorKind` is a closed union in core, while the proxy layer's kind is really a
      // free-form string passed through from `event.errorKind` (`moderation` is not in the union
      // either). Widening explicitly here is safer than adding a union member that only one
      // client can produce, which would ripple through the shared error mapping table.
      const customFragmentReasonKey = (pe.kind as string) === CUSTOM_FRAGMENT_ERROR_KIND
        ? customFragmentRejectionCopyKey(pe.detail || pe.message || '')
        : undefined;
      // Localized body only for a recognised library_* failure code; ordinary network or client
      // exceptions raised inside the same request have no fixed copy and keep their own detail.
      const libraryFailure = libraryFailurePatch(err, libraryFailurePresentation);
      const failedAssistantMsg: ChatMessage = {
        ...assistantMsg, text: partialText, state: 'failed' as const,
        ...(partialReasoning ? { reasoningText: partialReasoning } : {}),
        // Errors the provider or relay already returned get a neutral title only; the body keeps
        // the redacted upstream text in full. kind is still stored for the recovery CTA but must
        // not take part in rewriting user-facing copy.
        errorTitle: te(`${errorTitleKey}.title`),
        errorDetail: customFragmentReasonKey
          ? te(`${errorKindKey}.${customFragmentReasonKey}`)
          : (pe.detail || pe.message),
        ...(typeof pe.kind === 'string' ? { errorKind: pe.kind } : {}),
        ...(typeof pe.source === 'string' ? { errorSource: pe.source } : {}),
        ...(libraryFailure ?? {}),
        ...(researchSteps ? { researchSteps } : {}),
        ...(err && typeof err === 'object' && (err as { capabilityCustomRetryEligible?: unknown }).capabilityCustomRetryEligible === true
          ? { capabilityCustomRetryEligible: true } : {}),
        ...(err && typeof err === 'object' && isCapabilityRecoveryDescriptor((err as { capabilityRecovery?: unknown }).capabilityRecovery)
          ? { capabilityRecovery: (err as { capabilityRecovery: NonNullable<ChatMessage['capabilityRecovery']> }).capabilityRecovery } : {}),
        ...(p5Failure ? { capabilityResults: failureCapabilityResults } : {}),
      };
      // Incremental upsert against the latest messages in the store rather than the prevMessages snapshot, so concurrent sends do not overwrite each other.
      const failedConv = store.getState().conversations.find((c) => c.id === finalConvId);
      const latestUserForFail = failedConv?.messages.find((m) => m.id === userMsg.id) ?? userMsg;
      const failedMessages = upsertMessages(
        failedConv?.messages ?? prevMessages,
        persistUserMessage ? [latestUserForFail, failedAssistantMsg] : [failedAssistantMsg],
      );
      const baseConv = conversation ?? failedConv;
      if (baseConv && !alreadyTerminal) {
        store.getState().updateConversation(finalConvId, {
          messages: failedMessages,
          ...deriveConversationMetadata(baseConv, failedMessages),
          updatedAt: computeConversationActivityAt(failedMessages, baseConv.createdAt),
        });
      }
      // Sentry: report real pipeline failures only, filtering out user configuration errors; failures that truly carry capability execution facts stay suppressed.
      if (shouldReportProviderError(err) && !p5Failure) {
        Sentry.captureException(createProviderSentryError(err), {
          ...buildProviderSentryContext(provider.kind, err),
          tags: {
            module: 'chat.stream',
            'provider.kind': provider.kind,
            'provider.error': pe?.kind ?? 'non_provider',
            'model.id': model.id,
          },
        });
      }
      onFailed?.(text);
    } finally {
      clearOwnLibraryConfirmation(store, ownConfirmationIds);
      store.getState().clearStreamingForConversation(finalConvId);
    }
  })();

  return {
    convId: finalConvId,
    msgId: assistantMsg.id,
    abort: requestAbort,
    done,
  };
}

function isCapabilityRecoveryDescriptor(value: unknown): value is NonNullable<ChatMessage['capabilityRecovery']> {
  if (!value || typeof value !== 'object') return false;
  const descriptor = value as Partial<NonNullable<ChatMessage['capabilityRecovery']>>;
  return descriptor.version === 1 && descriptor.action === 'user_confirmed_resend_without_located_setting'
    && (descriptor.source === 'provider_recipe' || descriptor.source === 'custom')
    && Array.isArray(descriptor.owners) && descriptor.owners.length > 0
    && descriptor.owners.every((owner) => owner === 'web' || owner === 'reasoning' || owner === 'generation')
    && Array.isArray(descriptor.locatedPointers);
}

export async function prepareLibraryDirectContext(options: {
  documents: LibraryDocumentRef[];
  provider: Provider;
  model: AIModel;
  researchId: string;
  signal: AbortSignal;
  requestConfirmation: Parameters<typeof readLibraryDirectContext>[0]['requestConfirmation'];
  onQuota: NonNullable<Parameters<typeof readLibraryDirectContext>[0]['onQuota']>;
  /** Per-document read progress. Without it, selecting 5-10 long documents leaves the UI showing nothing but a typing indicator. */
  onSteps?: NonNullable<Parameters<typeof readLibraryDirectContext>[0]['onSteps']>;
}) {
  return readLibraryDirectContext({
    documents: options.documents,
    config: getLibraryRuntimeConfig(),
    // Prefer the provider's own contextLength and fall back to the aggregate catalog (same rule as the research path).
    modelContextLength:
      options.model.contextLength ??
      resolveCatalogModel(options.model.id, options.provider.kind)?.contextLength,
    signal: options.signal,
    executeRead: async (args, toolCallId, signal) => {
      const response = await executeLibraryTool('library_read', args, signal, {
        researchId: options.researchId,
        toolCallId,
        mode: 'direct',
      });
      return { ...response, result: response.result as LibraryReadResult };
    },
    requestConfirmation: options.requestConfirmation,
    onQuota: options.onQuota,
    ...(options.onSteps ? { onSteps: options.onSteps } : {}),
  });
}

/**
 * Injection preparation for unified server-side search.
 *
 * Returns the same payload shape as {@link prepareLibraryDirectContext}, so call sites never have
 * to tell the two paths apart. Telemetry is emitted here because this is the only layer holding
 * both provider / model and the number of evidence documents actually returned.
 */
export async function prepareLibraryServerResearch(options: {
  query: string;
  sources?: LibraryProvider[];
  provider: Provider;
  model: AIModel;
  researchId: string;
  signal: AbortSignal;
  requestConfirmation: Parameters<typeof runLibraryServerResearch>[0]['requestConfirmation'];
  onQuota: NonNullable<Parameters<typeof runLibraryServerResearch>[0]['onQuota']>;
  onSteps?: NonNullable<Parameters<typeof runLibraryServerResearch>[0]['onSteps']>;
  /** Telemetry route value; an agent first leg with zero tool calls is recorded as a separate value. */
  telemetryRoute?: 'server' | 'agent_no_toolcall_fallback';
}): Promise<LibraryServerResearchResult> {
  const result = await runLibraryServerResearch({
    query: options.query,
    ...(options.sources ? { sources: options.sources } : {}),
    config: getLibraryRuntimeConfig(),
    // Prefer the provider's own contextLength and fall back to the aggregate catalog (same rule as the research path).
    modelContextLength:
      options.model.contextLength ??
      resolveCatalogModel(options.model.id, options.provider.kind)?.contextLength,
    signal: options.signal,
    executeResearch: (args, signal) =>
      executeLibraryResearch(args.query, args.sources, {
        researchId: options.researchId,
        toolCallId: `research:${options.researchId}`,
        // Input the backend authoritatively blocks: omitting it degrades the denylist gate into client-side goodwill.
        providerKind: options.provider.kind,
        maxDocuments: args.maxDocuments,
        signal,
      }),
    requestConfirmation: options.requestConfirmation,
    onQuota: options.onQuota,
    ...(options.onSteps ? { onSteps: options.onSteps } : {}),
  });
  trackEvent('library_research_route', {
    route: options.telemetryRoute ?? 'server',
    provider_kind: telemetryProviderKind(options.provider.kind),
    model_id: telemetryModelID(options.provider.kind, options.model.id),
    documents: result.documentCount,
    had_warnings: result.warnings.length > 0,
  });
  return result;
}

function applyResearchStepsToMessage(
  store: ChatOpCtx['store'],
  conversationID: string,
  messageID: string,
  steps: ChatMessage['researchSteps'],
): void {
  const conversation = store.getState().conversations.find((c) => c.id === conversationID);
  if (!conversation) return;
  store.getState().updateConversation(conversationID, {
    messages: conversation.messages.map((message) =>
      message.id === messageID ? { ...message, researchSteps: steps } : message),
  });
}

export function appendTextToLatestUserMessage(
  messages: Array<{ role: string; content: string | ContentPart[] }>,
  text: string,
): void {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message.role !== 'user') continue;
    if (typeof message.content === 'string') {
      message.content = `${message.content}\n\n${text}`;
    } else {
      message.content = [...message.content, { type: 'text', text: `\n\n${text}` }];
    }
    return;
  }
}
