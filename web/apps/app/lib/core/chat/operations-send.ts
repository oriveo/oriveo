/**
 * sendMessage - send a new message, including the first message of a new conversation.
 *
 * Flow: store update -> stream execution -> sync notification -> attachment upload
 */
import type { ChatMessage, Citation, Conversation, AIModel, Provider, Attachment, ReasoningMode, QuoteContext } from '@oriveo/shared';
import { PROVIDER_REQUEST_FAILED_TITLE } from '../providers/error-i18n';
import type { CapabilityPreferenceInput, GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import { networkError, type ProviderError } from '../providers/errors';
import { mapErrorKindKey, readStream } from '../../utils/chat-stream-utils';
import { buildOutboundChatHistory, filterOutboundAttachments } from './outbound-history';
import { loadExternalSearchSendContext } from './external-search-send';
import {
  createExternalSearchExecutor,
  createWebSearchEntry,
  planExternalSearchTurn,
  rememberToolsRejected,
  hostMemoryToolsRegistered,
  searchThinkingOn,
  searchThinkingProtocol,
  setExternalSearchActivity,
  clearExternalSearchActivity,
  startExternalSearchReply,
  toolsRejectedBefore,
  externalSearchMessagePatch,
  type ExternalSearchReply,
} from './external-search-turn';
import { TOOLS_REJECTED_STATUSES, type SearchTurnPlan } from '@oriveo/core/search/search-turn';
import type { SearchRegenerateAction } from '@oriveo/core/search/search-route';
import { HOST_PROMPTS } from '@oriveo/core/search/search-tool-host';
import { ToolCallLoop } from '@oriveo/core/tools/tool-call-loop';
import { ToolLoopError, type ToolRegistryEntry } from '@oriveo/core/tools/tool-loop-contracts';
import { ToolRegistry } from '@oriveo/core/tools/tool-registry';
import { effectiveMaxSteps } from '@oriveo/core/mcp/mcp-types';
import { currentMcpRuntimeConfig } from '../mcp/mcp-store';
import { externalSearchModelKey } from '../../search/external-search-context';
import { createProposeMemoryEntry, currentMemoryCandidateRepository } from './propose-memory-entry';
import { createSearchMemoryEntry } from './search-memory-runtime';
import type { TelemetryEventName } from '@oriveo/shared';
import { searchConnectionsFromProviders } from '../../search/search-settings-data';
import { adoptDraftSearchSource } from '../../search/external-search-context';
import { type AssembleDynamic, type ContextPlan, type LibraryEntry } from '@oriveo/core/context/assemble';
import { recallForTurn } from '../memory/memory-recall-runtime';
import { CONTEXT_BUDGET_CONSTANTS } from '@oriveo/core/context/budget';
import {
  SEARCH_MEMORY_PROXY_TOOL,
  createSearchMemoryTurn,
  isSearchMemoryToolName,
  planRecallIds,
  planRecallMax,
  resolveSearchMemoryMode,
} from './search-memory-runtime';
import { ContextContinuation, type ContinuationInstructionsMode } from '@oriveo/core/context/continuation';
import type { ContinuationIntent } from '@oriveo/core/providers/request-preference/continuation';
import { withoutUnreceivableImages } from './attachment-policy';
import {
  appendChatManifest,
  applyCheckpointRowAssembly,
  assembleChatPlan,
  chatCompactionContextOf,
  chatContinuationFingerprintOf,
  chatStopFamilyOf,
  compareChatContinuationFingerprint,
  chatWireModelIdOf,
  compactChatContextAssembly,
  failedStopFamilyOf,
  failedWireModelIdOf,
  failureAnyOutputStarted,
  failureOutputStarted,
  isContextOverflowFailure,
  latestValidChatCheckpoint,
  observedChatInputOf,
  overflowFallbackChatContextAssembly,
  prepareChatContextAssembly,
  projectPlanMessages,
  recordChatOverflowMiss,
  recordChatRhoSample,
  requestCompactionSummary,
  userMaxOutputOf,
  withChatRhoModel,
  chatPlanWindowOf,
  type ChatContextAssembly,
  type ChatContinuationFingerprint,
} from './context-pipeline/chat-context';
import { CompactionBreakers, createCompactionCoordinator } from './context-pipeline/compaction-coordinator';
import type { ContextCheckpointRow } from '../../infra/storage/context-checkpoint-store';
import { outboundHistoryHasVideo, resolveAttachmentLine } from '../attachments/attachment-transport-resolver';
import { messagesCarryFilePart, nativeFileModeOf } from '@oriveo/core/providers/attachment-transport';
import { recordToolCallFallback, relayFirstSendMessagesBlockedByFiles } from './relay-rejection-loop';
import { processImageAttachments, backfillStorageRefs } from '../../utils/stream-image-utils';
import { createUserMessage, createAssistantMessage } from './message-factory';
import { upsertMessages } from './message-merge';
import { deriveConversationMetadata, computeConversationActivityAt } from '../conversation-metadata';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent, dispatchesImageGeneration, filterGenerationParameterOverrides, filterRequestCapabilityIntent, providerControlsAreManaged } from './stream-options';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { generationParameterFallbackModelId, generationParameterProfileFingerprint, resolveGenerationParameterOverrides } from './generation-parameter-settings';
import { canonicalFinalTransport, capabilityPreferenceIdentity, resolveCapabilityPreferences, subscriptionFinalTransport, resolveRelayWebPreference, type CapabilityPreferences } from './capability-preference-settings';
import { migrateDraftScopedModelControls } from './draft-scope-migration';
import { customFragmentFailurePatch } from './custom-fragment-rejection';
import { customFragmentAllowedPaths } from './custom-fragment-allowed-paths';
import { additionalBodyFailurePatch } from './additional-body-rejection';
import { forwardPortCustomFragmentsIfNeeded, resolveCustomFragments } from './custom-fragment-settings';
import { withAdditionalBody } from './additional-body-settings';
import { webPreferenceReachesTheWire } from './capability-control-presentation';
import { relayWebProviderDefault, webSearchDispatched } from './relay-web-probe-records';
import { relayWebReplyNoticeFor, setRelayWebReplyNotice } from './relay-web-reply-notice';
import { getCapabilityRuntime, normalizeModelFactsID } from '../metadata/metadata-client';
import { effectiveCapabilityTransport, resolveModelCapabilityEvidence } from './capability-evidence';
import { trackEvent, telemetryProviderKind, telemetryModelID } from '../telemetry';
import * as Sentry from '@sentry/nextjs';
import { deriveCostFields, generatedImageUnits, mergeMessageUsageFields, roundCostOf } from './cost-fields';
import { mergeCitationsWithExisting } from './cost-fields';
import {
  buildProviderSentryContext,
  normalizeChatFailure,
  shouldReportProviderError,
  createProviderSentryError,
} from './error-reporting';
import { recalculateConversationCostTotals } from './usage-tracking';
import { addMessageCost } from '../cost/cost-currency';
import { recordOfficialInputRejection } from '../capability/input-rejection-flow';
import { attachOfficialInputRejection, officialInputRejectionOf } from '../capability/rejection-recovery';
import { unbilledSkillRetrievalUsage, type PromptInjectionContext } from './prompt-injection';
import { runStreamPipeline, type StreamPipelineResult } from './stream-runner';
import { transportInput, type TransportInput } from './context-pipeline/transport-input';
import { stopReasonFromError, stopReasonFromFinish } from './stop-reason-outcome';
import { ContextOverflowClassifier } from '@oriveo/core/context/overflow';
import { prepareSendStart, reportSendStartedTelemetry, rollbackSendStart } from './send-start';
import { CapConfirmCancelledError, capConfirmAttemptOf, gateCapConfirm, onceCallback } from './context-visibility/cap-confirm-gate';
import { reportSendCompletion } from './send-completion';
import { reportChatFailed } from './send-failure';
import type { ChatAttemptKind } from '../telemetry/chat-failure';
import { continuationCaptured, continuationSendCompleted, continuationSendInterrupted, continuationSendStarted } from './continuation-lifecycle';
import { getSyncAdapter } from '../sync-port';
import type { ChatOpCtx, SendHandle } from './operations';
import { prepareMcpSend } from '../mcp/mcp-chat';
import { oriveoAbortReason } from '@oriveo/core/util/abort-reason';
import { generateMemoryCandidate, offerDirectiveSuggestion, offerInstructSuggestion } from './conversation-instructions/directive-suggestion';
import { resolveProposedMemorySuggestion, type MemorySuggestionTicket } from './conversation-instructions/memory-suggestion';
import { markProposeMemoryDegraded, memoryToolsConnectionSupported, resolveProposeMemoryMode } from './propose-memory-runtime';
import {
  PROPOSE_MEMORY_TOOL,
  PROPOSE_MEMORY_TOOL_NAME,
  PROPOSE_MEMORY_TOOL_RESULT,
  shouldDegradeProposeMemory,
} from '@oriveo/core/context/memory-propose';
import type { ProxyMessage, ProxyToolCall, ProxyToolDefinition } from '@oriveo/core/providers/request-builders/runtime';
import type { CompletedToolCall } from '@oriveo/core/providers/tool-call-accumulator';
import { openAIChatToolAdapter } from '@oriveo/core/tools/tool-loop-contracts';
import { mergeToolLoopUsage } from '@oriveo/core/tools/tool-call-loop';
import {
  isDeterministicToolCallUnsupported,
  type ToolCallRecoveryIdentity,
  type ToolCallRejectionContext,
} from './capability-recovery-runtime';
import { sendLibraryAgentLeg } from '../providers/proxy-client';
import { requestBaseURLText } from '../providers/endpoint-source';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { createMemoryCandidateRepository } from '../memory/memory-candidate-repository';
import { createMemoryItemRepository } from '../memory/memory-item-repository';
import { sendMcpToolMessage, type SendMcpToolMessageParams } from './operations-mcp-send';
import type {
  LibraryConfirmationRequest,
  LibraryDocumentRef,
  LibraryProvider,
  LibraryReadResult,
} from '../library/types';
import { executeLibraryResearch, executeLibraryTool } from '../library/api';
import { clearOwnLibraryConfirmation, requestLibraryConfirmation } from '../library/confirmation';
import {
  getImageGenRoute,
  getLibraryRuntimeConfig,
  getRelayRuntimeConfig,
  resolveCatalogModel,
} from '../metadata/metadata-client';
import { relayImageRoute } from '@oriveo/core/providers/relay-runtime-support';
import { LibraryResearchCancelledError } from './library-agent-loop';
import { libraryFailurePatch, type LibraryFailurePresentation } from './library-failure';
import { telemetryToolName } from '../mcp/mcp-telemetry';
import { flushPendingStreaming } from './stream-batcher';
import { withMemoryItemIds } from './memory-item-ids';
import { appendText, patchAssistantMessage, prepareAgentSubscriptionOutbound } from './agent-send-shared';
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

/** Of the four closed imageGen route values (Server fetcher.go), the dedicated endpoints that take only a one-sentence prompt; chat_api is conversational image generation and goes through chat. */
const PROMPT_ONLY_IMAGE_GEN_ROUTES: ReadonlySet<string> = new Set(['images_api', 'dashscope_multimodal', 'minimax_image_generation']);

/** Whether this image generation request hits a dedicated prompt endpoint: for a relay look at the transport's image route, for an official provider the route of the imageGen profile. */
function dispatchesToImagesEndpoint(provider: Provider, model: AIModel, options: StreamOptions | undefined): boolean {
  if (provider.kind === 'relay') {
    return relayImageRoute(options?.relayTransport ?? 'openai_chat_completions', getRelayRuntimeConfig()) === 'images_endpoint';
  }
  const route = getImageGenRoute(model.imageGenProfile);
  return route !== null && PROMPT_ONLY_IMAGE_GEN_ROUTES.has(route);
}

/**
 * Decides whether this send is handed to the MCP tool loop, and returns its arguments if so. It only reads the local MCP store and sends no request.
 */
function resolveMcpDelegation(params: Parameters<typeof sendMessage>[1]): SendMcpToolMessageParams | null {
  if (params.libraryServerResearch) return null;
  if (params.libraryContextDocuments?.length) return null;
  // A continuation is a single purpose=continue request and never enters the tool loop.
  if (params.continueAssistant) return null;
  const override = params.assistantMessageOverride;
  // When a message that named documents is resumed, its citations are inherited as named documents (see inheritedContextDocuments below).
  if (!params.libraryContextDocuments && override && !override.libraryResearchEnabled
    && libraryDocumentRefsFromCitations(override.citations).length > 0) return null;
  if (params.excludeCustomFragments
    || params.excludeCustomFragmentOwners?.length
    || params.capabilityRecipeOmissions?.length
    || params.capabilityRecipeResendOwners?.length
    || params.excludeCapabilityOwners?.length) return null;
  const plan = prepareMcpSend({
    conversationId: params.conversation?.id,
    draftSessionId: params.generationParameterDraftSessionId,
    provider: params.provider,
    model: params.model,
  });
  if (plan.tools.length === 0) return null;
  return {
    text: params.text,
    prevMessages: params.prevMessages,
    conversation: params.conversation,
    provider: params.provider,
    model: params.model,
    reasoningMode: params.reasoningMode,
    plan,
    ...(params.attachments ? { attachments: params.attachments } : {}),
    ...(params.quoteContext ? { quoteContext: params.quoteContext } : {}),
    ...(params.skillId ? { skillId: params.skillId } : {}),
    ...(params.pinnedNoteIds ? { pinnedNoteIds: params.pinnedNoteIds } : {}),
    ...(params.userMessageOverride ? { userMessageOverride: params.userMessageOverride } : {}),
    ...(override ? { assistantMessageOverride: override } : {}),
    ...(params.persistUserMessage != null ? { persistUserMessage: params.persistUserMessage } : {}),
    ...(params.userMessageAlreadyInHistory != null ? { userMessageAlreadyInHistory: params.userMessageAlreadyInHistory } : {}),
    ...(params.appendToAssistant ? { appendToAssistant: params.appendToAssistant } : {}),
    ...(params.onNewConversation ? { onNewConversation: params.onNewConversation } : {}),
    ...(params.onFailed ? { onFailed: params.onFailed } : {}),
    ...(params.generationParameterDraftSessionId ? { generationParameterDraftSessionId: params.generationParameterDraftSessionId } : {}),
    ...(params.transientGenerationParameters ? { transientGenerationParameters: params.transientGenerationParameters } : {}),
    ...(params.omitAdditionalBody ? { omitAdditionalBody: true } : {}),
    ...(params.attemptKind ? { attemptKind: params.attemptKind } : {}),
    ...(params.onSendConfirmed ? { onSendConfirmed: params.onSendConfirmed } : {}),
    ...(params.webSearchEnabled != null ? { webSearchEnabled: params.webSearchEnabled } : {}),
    ...(params.searchRegenerate ? { searchRegenerate: params.searchRegenerate } : {}),
  };
}

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
    /**
     * Continuation (library continuation): assistantMessageOverride is the continuation target, the outbound history is cut up to and including it,
     * purpose=continue, and the new body follows its existing body.
     */
    continueAssistant?: boolean;
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
    /** "Retry without the additional body": omitted for this one send only, independent of omitting web search or reasoning. */
    omitAdditionalBody?: boolean;
    /** Explicit resend only: omit the located custom source owner(s), not official recipes. */
    excludeCustomFragmentOwners?: Array<'web' | 'reasoning' | 'generation'>;
    /** Exact official recipe setting(s) omitted only for this confirmed resend. */
    capabilityRecipeOmissions?: Array<{ recipeRef: string; locatedPointers: string[] }>;
    /** One-request latch that lets the rejected owner leave dormant for exact resend. */
    capabilityRecipeResendOwners?: Array<'web' | 'reasoning' | 'generation'>;
    /** Explicit resend only: omit exactly the rejected capability owner(s) for this request. */
    excludeCapabilityOwners?: Array<'web' | 'reasoning' | 'generation'>;
    /** Entry point that started this attempt (telemetry attempt_kind); defaults to send. */
    attemptKind?: ChatAttemptKind;
    /** External search regenerate basis: regenerate / edit-resend / re-search + the source of the message being regenerated; omitted = new send. */
    searchRegenerate?: { action: SearchRegenerateAction; previousCitations?: readonly Citation[] | null };
    /**
     * Called once after the pre-send confirmation passes (including when none is needed) and before transport (for example the remote delete of an edit-and-resend);
     * not called when the confirmation is cancelled; if the send fails before the gate it is called at wrap-up, matching the old "always happens" behaviour.
     */
    onSendConfirmed?: () => void;
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
    continueAssistant = false,
    appendToAssistant: appendToAssistantParam = false,
    generationParameterDraftSessionId,
    transientGenerationParameters,
    capabilityPreferences,
    excludeCustomFragments = false,
    omitAdditionalBody = false,
    excludeCustomFragmentOwners = [],
    capabilityRecipeOmissions = [],
    capabilityRecipeResendOwners = [],
    excludeCapabilityOwners = [],
    attemptKind = 'send',
    searchRegenerate,
  } = params;
  const sendConfirmed = onceCallback(params.onSendConfirmed);

  // Remote MCP: when this conversation has servers switched on and the connection can carry tools,
  // the send goes through the tool loop instead. The decision is made here rather than in the UI
  // because retry and edit-and-resend re-enter through this function; deciding at each entry point
  // would inevitably miss one. Not delegated: named documents and server-side research (they need
  // the injection pipeline, and the library takes precedence), and targeted resends the user
  // confirmed (those switches only take effect on the plain send path). With no usable tool the
  // plan is empty and the original path is unchanged.
  const userMsg = userMessageOverride ?? createUserMessage({ text, provider, model, attachments, quoteContext });
  // The "set as instruction" suggestion strip only judges fresh user sends (including fresh MCP / library sends); retries, regenerations, edits, continuations and restores do not.
  const isFreshUserSend = attemptKind === 'send' && !userMessageOverride && !userMessageAlreadyInHistory
    && persistUserMessage && !continueAssistant;
  const mcpDelegation = resolveMcpDelegation(params);
  if (mcpDelegation) {
    // The pre-built userMsg is handed to the MCP path (equivalent to building it inside). On a fresh user send, the propose_memory mode and the suggestion strip ticket
    // are decided and opened by the MCP path after persisting (the ticket hangs on the assistant message it creates); in tool mode propose_memory is appended as the last registry entry.
    return sendMcpToolMessage(ctx, {
      ...mcpDelegation,
      userMessageOverride: userMsg,
      ...(isFreshUserSend ? { freshUserSend: { webSearchEnabled } } : {}),
    });
  }

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
  const continueTarget = continueAssistant && assistantMessageOverride ? assistantMessageOverride : undefined;
  const appendToAssistant = appendToAssistantParam || continueTarget !== undefined;
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
  // A first message in a new conversation is judged too: the conversation is already created at this point, so use its id.
  // The mode and ticket travel with the outbound request: in tool mode the first leg carries propose_memory, and the suggestion strip is published through the ticket.
  const proposeMemoryMode = isFreshUserSend
    ? resolveProposeMemoryMode({
      store, conversationId: finalConvId, provider, model, freshSend: true, webSearchEnabled: effectiveWebSearchEnabled,
    })
    : 'none';
  const memoryTicket = isFreshUserSend
    ? offerDirectiveSuggestion(store, finalConvId, userMsg, assistantMsg.id, proposeMemoryMode)
    : undefined;
  // Local-only pending marker: no sync/backup/telemetry. Completion removes a bare marker but
  // retains a complete captured tool block for an explicit later continue; refresh never resumes.
  void Promise.resolve(continuationSendStarted(finalConvId, assistantMsg.id)).catch(() => undefined);
  // The web reply notice of this reply is recomputed from the actual outbound only on delivery (a failure attaches none).
  setRelayWebReplyNotice(assistantMsg.id, null);
  // New conversation: both kinds of draft move together, all of it inside `migrateDraftScopedModelControls` (see its comment).
  migrateDraftScopedModelControls({
    provider,
    model,
    conversation,
    draftSessionId: generationParameterDraftSessionId,
    conversationId: finalConvId,
  });
  // New conversation created: the search source picked in model options while in draft is written once under the real id; this turn's outbound waits for it to be stored before reading the source.
  if (!conversation && generationParameterDraftSessionId) {
    adoptDraftSearchSource({ draftSessionId: generationParameterDraftSessionId, conversationId: finalConvId });
  }

  // Wire protocol of this (most recent) attempt's outbound request: the overflow family is taken from it, not from the connection kind.
  let requestRelayTransport: StreamOptions['relayTransport'];
  // This turn's external search (handed over at the start of runChatOutbound): wrap-up persistence follows it; on user stop send stopped first.
  let externalSearchReply: ExternalSearchReply | undefined;
  const externalSearchPatch = (existing: Pick<ChatMessage, 'citations' | 'capabilityResults'>): Partial<ChatMessage> => {
    clearExternalSearchActivity(finalConvId);
    if (!externalSearchReply) return {};
    if (abortRequested) externalSearchReply.stop();
    return externalSearchMessagePatch(externalSearchReply.finish(), externalSearchReply.turn.binding.service, existing);
  };
  const done = (async () => {
    try {
      if (directContextDocuments.length > 0 || serverResearch) {
        setAbortFn(() => directContextController.abort(oriveoAbortReason('direct-context-cancel')));
      }
      if (typeof navigator !== 'undefined' && !navigator.onLine) {
        // Use the networkError helper rather than a hand-made literal: it returns a real Error
        // subclass, so throwing carries a stack for Sentry. The UI error card is still rendered
        // by te(`network.title`) in the catch block, independent of this message.
        throw networkError(new Error('navigator.onLine === false'), 'offline');
      }

      // Normalization before sending, the system prompt and the [D] block are all produced by ContextAssembler (send / retry / regenerate / edit-and-send use purpose=chat,
      // library continuation uses purpose=continue); assembly, the option chain, streaming, rho, the manifest and overflow recovery all go through the same runChatOutbound chain.
      const effectiveConversation = conversation ?? initialConversationSnapshot;
      const rawOutboundMessages = continueTarget
        ? continueOutboundMessages(prevMessages, assistantMsg)
        : userMessageAlreadyInHistory ? prevMessages : [...prevMessages, userMsg];
      const outbound = await runChatOutbound(ctx, {
        purpose: continueTarget ? 'continue' : 'chat',
        conversationId: finalConvId,
        conversation: effectiveConversation,
        provider,
        model,
        reasoningMode,
        webSearchEnabled,
        libraryActive: directContextDocuments.length > 0 || Boolean(serverResearch),
        messages: rawOutboundMessages,
        ...(continueTarget ? {} : { currentTurnId: userMsg.id }),
        ...(appendToAssistant ? { keepAssistantId: assistantMsg.id } : {}),
        latestUserText: text,
        assistantMessageId: assistantMsg.id,
        initialText: initialAssistantText,
        // Both paths produce the same payload shape ([D] library entries / citations),
        // so injection, citation persistence and citation suppression read only this one return value.
        loadLibrary: async () => directContextDocuments.length > 0
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
            : undefined,
        optionInputs: {
          ...(skillId ? { skillId } : {}),
          ...(transientGenerationParameters ? { transientGenerationParameters } : {}),
          ...(capabilityPreferences ? { capabilityPreferences } : {}),
          excludeCustomFragments,
          omitAdditionalBody,
          excludeCustomFragmentOwners,
          capabilityRecipeOmissions,
          capabilityRecipeResendOwners,
          excludeCapabilityOwners,
        },
        setAbortFn,
        isAbortRequested: () => abortRequested,
        onRelayTransport: (transport) => { requestRelayTransport = transport; },
        attemptKind,
        onSendConfirmed: sendConfirmed,
        ...(memoryTicket && proposeMemoryMode === 'tool'
          ? { proposeMemory: { ticket: memoryTicket, userMessage: userMsg } }
          : {}),
        ...(searchRegenerate ? { searchRegenerate } : {}),
        onExternalSearchReply: (reply) => { externalSearchReply = reply; },
      });
      const { pipeline, promptContext, libraryContext, relayStreamOptions } = outbound;

      if (pipeline.outcome === 'guarded') {
        // The request went out: stream-runner writes the final message state, so here we only add the memory item ids injected this time.
        if (outbound.memoryIds.length > 0) {
          patchAssistantMessage(store, finalConvId, assistantMsg.id, { memoryItemIds: outbound.memoryIds });
        }
        if (externalSearchReply) {
          const guarded = store.getState().conversations.find((c) => c.id === finalConvId)?.messages.find((m) => m.id === assistantMsg.id);
          patchAssistantMessage(store, finalConvId, assistantMsg.id, externalSearchPatch(guarded ?? {}));
        }
        // Guard hit: stream-runner already wrote citations back, so the transaction must not overwrite the final message state.
        // The request did go out, so still report this attempt's sent (the outcome is the stopped event from the stop side, not reported here).
        reportSendStartedTelemetry({
          finalConvId,
          isFirstMessage,
          provider,
          model,
          reasoningMode,
          webSearchEnabled: effectiveWebSearchEnabled,
          attachments,
          skillId,
          attemptKind,
        });
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
          toolName: telemetryToolName(call.name),
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
        attemptKind,
      });

      const { finalText, processedAttachments } = await processImageAttachments(fullText, imageAttachments);
      const costInfo = deriveCostFields(usage, model, provider, () => new Date(), generatedImageUnits(processedAttachments));
      const roundCost = roundCostOf(costInfo, promptContext.retrievalCost);
      const cost = roundCost.estimatedCost;
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
      const deliveredAssistantMsg: ChatMessage = withMemoryItemIds({
        ...assistantMsg, text: finalText, state: 'delivered' as const,
        stopReason: abortRequested ? 'interrupted' : stopReasonFromFinish(pipeline.finish, fullText.trim() !== ''),
        ...addMessageCost(appendToAssistant ? assistantMsg : undefined, roundCost),
        ...(mergedReasoning ? { reasoningText: mergedReasoning } : {}),
        ...(mergedReasoning && mergedReasoningDurationMs !== undefined ? { reasoningDurationMs: mergedReasoningDurationMs } : {}),
        ...(capabilityResults.length > 0 ? { capabilityResults } : {}),
        ...(unhandledToolCalls.length > 0 ? { unhandledToolCalls } : {}),
        servedModelID,
        ...(researchSteps ? { researchSteps } : {}),
        attachments: mergedAttachments.length > 0 ? mergedAttachments : undefined,
        ...(mergedCitations && mergedCitations.length > 0 ? { citations: mergedCitations } : {}),
        ...externalSearchPatch({ citations: mergedCitations, capabilityResults: capabilityResults.length > 0 ? capabilityResults : undefined }),
        costSource: roundCost.costSource,
        ...mergeMessageUsageFields(appendToAssistant ? assistantMsg : {}, costInfo),
      }, outbound.memoryIds, Boolean(appendToAssistant));

      const latestConversation = store.getState().conversations.find((c) => c.id === finalConvId);
      const latestUserMsg = latestConversation?.messages.find((m) => m.id === userMsg.id) ?? userMsg;
      // Incremental upsert against the latest messages in the store rather than the prevMessages snapshot, so concurrent sends do not overwrite each other.
      const completedMessages = upsertMessages(
        latestConversation?.messages ?? prevMessages,
        persistUserMessage ? [latestUserMsg, deliveredAssistantMsg] : [deliveredAssistantMsg],
      );
      const totalsBase = latestConversation ?? conversation;
      const costTotals = recalculateConversationCostTotals(completedMessages, totalsBase
        ? { conversation: totalsBase, previousMessages: latestConversation?.messages ?? prevMessages }
        : null);
      const updatedCost = costTotals.estimatedCost;
      const baseConv = conversation ?? latestConversation;
      if (!baseConv) {
        // Conversation deleted concurrently while streaming: discard this result, write nothing to the store, report no sync or telemetry.
        return;
      }
      store.getState().updateConversation(finalConvId, {
        messages: completedMessages,
        ...deriveConversationMetadata(baseConv, completedMessages),
        estimatedCost: updatedCost,
        nonUsdCostTotals: costTotals.nonUsdCostTotals,
        updatedAt: computeConversationActivityAt(completedMessages, baseConv.createdAt),
      });

      // A failed half-round never goes to the cloud: the whole round (user + assistant) is synced
      // atomically from the conversation snapshot taken after the round was written back, so
      // metadata such as messageCount matches the absolute delivered count. Failures and
      // interruptions sync nothing from the catch block.
      const deliveredRelayOptions = pipeline.relaySentStreamOptions ?? relayStreamOptions;
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
        costSource: roundCost.costSource,
        servedModelID,
        processedAttachments,
        promptContext,
        sendStartedAt,
        completedAt,
        attemptKind,
        // Take the transport and fragment from the request actually delivered (a protocol-level fallback is recorded under the protocol actually used).
        relayWebObservation: {
          sentFragment: deliveredRelayOptions?.relayWebFragment,
          transport: deliveredRelayOptions?.relayTransport,
          citations,
        },
      });
      // Web switch on but the delivered request carried no fragment -> a one-line notice under the reply (kept in session memory only).
      setRelayWebReplyNotice(assistantMsg.id, relayWebReplyNoticeFor(provider, deliveredRelayOptions));
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
      if (err instanceof CapConfirmCancelledError) {
        // Cancel means rollback: delete this message pair locally (no didDeleteMessages call, since the user message has not been synced),
        // report neither sent nor failed and do not call onFailed; the original input is handed back to the caller through done to refill the composer.
        rollbackSendStart(store, finalConvId, persistUserMessage && !userMessageAlreadyInHistory
          ? [userMsg.id, assistantMsg.id]
          : [assistantMsg.id]);
        return {
          rolledBack: {
            text,
            ...(attachments?.length ? { attachments } : {}),
            ...(quoteContext ? { quoteContext } : {}),
            ...(libraryContextDocuments?.length ? { libraryContextDocuments } : {}),
          },
        };
      }
      // Failed before the gate: do what normally happens after confirmation anyway (only a cancel at the confirmation skips it).
      sendConfirmed();
      void Promise.resolve(continuationSendInterrupted(finalConvId, assistantMsg.id)).catch(() => undefined);
      if (err instanceof LibraryResearchCancelledError) {
        const cancelledAssistantMsg: ChatMessage = {
          ...assistantMsg,
          text: libraryContextCancelledText,
          state: 'delivered',
          // The user cancelled library retrieval: record interrupted, keep the state delivered as before.
          stopReason: 'interrupted',
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
          const costTotals = recalculateConversationCostTotals(completedMessages, {
            conversation: latestConversation ?? baseConv,
            previousMessages: latestConversation?.messages ?? prevMessages,
          });
          const updatedCost = costTotals.estimatedCost;
          store.getState().updateConversation(finalConvId, {
            messages: completedMessages,
            ...deriveConversationMetadata(baseConv, completedMessages),
            estimatedCost: updatedCost,
            nonUsdCostTotals: costTotals.nonUsdCostTotals,
            updatedAt: computeConversationActivityAt(completedMessages, baseConv.createdAt),
          });
          const snapshot = store.getState().conversations.find((c) => c.id === finalConvId);
          getSyncAdapter()?.didCompleteRound(latestUserMsg, cancelledAssistantMsg, finalConvId, snapshot, updatedCost);
        }
        return;
      }
      // A transport failure (connection lost, network switch, request cancelled) can still arrive
      // here as a bare `TypeError`: streams are normalized in `toStreamError`, but the
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
        attemptKind,
      });
      // When the user stops the stream (stop() already saved the message as interrupted and reported stopped), the abort also
      // bubbles up here, often wrapped as a network error: that is not a failure, so failed is never reported again
      // (event conservation: at most one outcome).
      const stoppedByUser = abortRequested || store.getState().conversations
        .find((c) => c.id === finalConvId)?.messages
        .find((m) => m.id === assistantMsg.id)?.state === 'interrupted';
      if (!stoppedByUser) {
        reportChatFailed({ provider, model, attemptKind, error: pe ?? err, rawError: err, sendStartedAt });
      }
      // The partial generated before the failure is still in the store's streaming map
      // (clearStreamingForConversation only runs in finally), so read it out here into the failed
      // message instead of zeroing half-written content with text:''.
      // Flush the tail still sitting in the rAF batch writer first (the error frame and the last
      // piece of body text often arrive in the same frame), or it would be lost.
      flushPendingStreaming(finalConvId);
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
      // Stop / failure also persist the external search's source, facts and error card (requests already sent still count).
      if (alreadyTerminal && guardMsg && externalSearchReply) {
        patchAssistantMessage(store, finalConvId, assistantMsg.id, externalSearchPatch(guardMsg));
      }
      const partialText = partialState.streamingTexts[finalConvId] || guardMsg?.text || '';
      const partialReasoning = (partialState.streamingReasoningTexts[finalConvId] ?? '').trim();
      const errorKindKey = mapErrorKindKey(pe.kind);
      const additionalBodyRetry = Boolean(err && typeof err === 'object'
        && (err as { additionalBodyRetryEligible?: unknown }).additionalBodyRetryEligible === true);
      // A 400 before the stream starts that names one panel parameter exactly: the error card says which one and the user decides whether to resend without it.
      const generationParameterRejection = generationParameterRejectionOf(err);
      const inputRejection = officialInputRejectionOf(err);
      const relayImageUnsupported = Boolean(err && typeof err === 'object'
        && (err as { relayImageUnsupported?: unknown }).relayImageUnsupported === true);
      const relayFileUnsupported = !relayImageUnsupported && Boolean(err && typeof err === 'object'
        && (err as { relayFileUnsupported?: unknown }).relayFileUnsupported === true);
      const errorTitleKey = additionalBodyRetry ? 'additionalBodyRejected.upstreamTitle' : `${errorKindKey}.title`;
      // Custom request fields fail closed: the body becomes a localized sentence keyed by the
      // rejection reason (the same three-way split as the editor) rather than putting an internal
      // enum name such as `unknown_owned_path` in front of the user.
      // `ProviderErrorKind` is a closed union in core, while the proxy layer's kind is really a
      // free-form string passed through from `event.errorKind` (`moderation` is not in the union
      // either). Widening explicitly here is safer than adding a union member that only one
      // client can produce, which would ripple through the shared error mapping table.
      const customFragmentFailure = customFragmentFailurePatch(pe, te, (owner) => customFragmentAllowedPaths(model, owner));
      // Localized body only for a recognised library_* failure code; ordinary network or client
      // exceptions raised inside the same request have no fixed copy and keep their own detail.
      const libraryFailure = libraryFailurePatch(err, libraryFailurePresentation);
      // A locally rejected additional body: the text is the reason plus "nothing was sent", and the
      // technical detail is only the safe code (no retry affordance, see the bubble).
      const additionalBodyFailure = additionalBodyFailurePatch(err, te);
      // Persist stopReason: hadContent only looks at the answer text, not reasoning.
      // A context overflow (recovery failed or text already produced) is recorded as context_window_exceeded, with the failure styling unchanged.
      // A user cancel that ends by throwing: the criterion is this send's abortRequested, not a guess from the error type.
      const failureStopReason = abortRequested
        ? 'interrupted' as const
        : isInStreamOverflowFailure(err) || isContextOverflowFailure(err, provider.kind, requestRelayTransport)
        ? 'context_window_exceeded' as const
        : stopReasonFromError(err, provider.kind, partialText.trim() !== '');
      const failedAssistantMsg: ChatMessage = {
        ...assistantMsg, text: partialText, state: 'failed' as const,
        stopReason: failureStopReason,
        ...(partialReasoning ? { reasoningText: partialReasoning } : {}),
        // Errors the provider or relay already returned get a neutral title only; the body keeps
        // the redacted upstream text in full. kind is still stored for the recovery CTA but must
        // not take part in rewriting user-facing copy.
        // A provider-sourced title is stored as the English source string and translated at render time
        // in the current language, so switching language follows.
        errorTitle: !additionalBodyRetry && pe.source === 'provider' ? PROVIDER_REQUEST_FAILED_TITLE : te(errorTitleKey),
        ...(additionalBodyRetry ? { additionalBodyRetryEligible: true } : {}),
        ...(generationParameterRejection ? { generationParameterRejection } : {}),
        ...(inputRejection ? { inputRejection } : {}),
        ...(relayImageUnsupported ? { relayImageUnsupported: true } : {}),
        ...(relayFileUnsupported ? { relayFileUnsupported: true } : {}),
        errorDetail: additionalBodyFailure ? additionalBodyFailure.errorDetail : customFragmentFailure
          ? customFragmentFailure.errorDetail
          // Relay guidance: the body is stored as the English guidance source sentence and localized at render
          // time (switching language follows); the upstream text goes into the technical detail.
          : pe.relayGuidance ? pe.message : (pe.detail || pe.message),
        ...(typeof pe.kind === 'string' ? { errorKind: pe.kind } : {}),
        ...(typeof pe.source === 'string' ? { errorSource: pe.source } : {}),
        ...(additionalBodyFailure ? { errorTechnicalDetail: additionalBodyFailure.errorTechnicalDetail }
          : customFragmentFailure?.errorTechnicalDetail ? { errorTechnicalDetail: customFragmentFailure.errorTechnicalDetail }
          : pe.relayGuidance && pe.detail ? { errorTechnicalDetail: pe.detail }
          // In-stream error frame: once classified, keep the upstream text (already redacted and truncated by the sender) as technical detail.
          : pe.streamErrorFrame && pe.message ? { errorTechnicalDetail: pe.message }
          // The card body now explains that this one setting was rejected; the upstream text stays in the technical detail.
          : generationParameterRejection && (pe.detail || pe.message) ? { errorTechnicalDetail: pe.detail || pe.message } : {}),
        ...(libraryFailure ?? {}),
        ...(researchSteps ? { researchSteps } : {}),
        ...(err && typeof err === 'object' && (err as { capabilityCustomRetryEligible?: unknown }).capabilityCustomRetryEligible === true
          ? { capabilityCustomRetryEligible: true } : {}),
        ...(err && typeof err === 'object' && isCapabilityRecoveryDescriptor((err as { capabilityRecovery?: unknown }).capabilityRecovery)
          ? { capabilityRecovery: (err as { capabilityRecovery: NonNullable<ChatMessage['capabilityRecovery']> }).capabilityRecovery } : {}),
        ...(p5Failure ? { capabilityResults: failureCapabilityResults } : {}),
        ...externalSearchPatch({ capabilityResults: p5Failure ? failureCapabilityResults : undefined }),
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
    attemptKind,
  };
}

/** Inputs of the outbound option chain (generation parameters, capability preferences, custom fields, additional body): the same for send and continue. */
export interface ChatOutboundOptionInputs {
  skillId?: string;
  transientGenerationParameters?: GenerationParameterOverrides;
  capabilityPreferences?: CapabilityPreferenceInput;
  excludeCustomFragments?: boolean;
  omitAdditionalBody?: boolean;
  excludeCustomFragmentOwners?: Array<'web' | 'reasoning' | 'generation'>;
  capabilityRecipeOmissions?: Array<{ recipeRef: string; locatedPointers: string[] }>;
  capabilityRecipeResendOwners?: Array<'web' | 'reasoning' | 'generation'>;
  excludeCapabilityOwners?: Array<'web' | 'reasoning' | 'generation'>;
}

export interface ChatOutboundRequest<L extends { entries: LibraryEntry[] }> {
  purpose: 'chat' | 'continue';
  conversationId: string;
  conversation: Conversation | undefined;
  provider: Provider;
  model: AIModel;
  reasoningMode: ReasoningMode;
  /** The user's web search switch (it is turned off for this single send when library evidence is present). */
  webSearchEnabled?: boolean;
  /** This send carries library evidence (named documents / server retrieval / a continuation re-reading named documents): web search and custom fields are turned off for this single send. */
  libraryActive: boolean;
  /** Outbound candidates: chat includes this round's user message; continue is cut up to and including the target assistant. */
  messages: ChatMessage[];
  /** Id of this round's user message (attachments are filtered for this round and the attachment guide goes into [D]); continue has no user message for this round. */
  currentTurnId?: string;
  keepAssistantId?: string;
  latestUserText: string;
  assistantMessageId: string;
  initialText: string;
  /** Loads the library evidence: called after assembly and before the option chain, and the result goes into [D]. */
  loadLibrary?: () => Promise<L | undefined>;
  optionInputs: ChatOutboundOptionInputs;
  /** Local continuation state read by an explicit continuation; together with previousFingerprint it decides fullPlan / stateful. */
  continuation?: ContinuationIntent;
  previousFingerprint?: ChatContinuationFingerprint;
  setAbortFn: (fn: (() => void) | null) => void;
  isAbortRequested: () => boolean;
  /** Wire protocol of this (most recent) attempt's outbound request: the caller's failure classification takes the family from it. */
  onRelayTransport: (transport: StreamOptions['relayTransport']) => void;
  /** Entry point: only send / edit ask the user at the pre-send confirmation; defaults to send. */
  attemptKind?: ChatAttemptKind;
  /** Called after the pre-send confirmation passes (including when none is needed) and before transport. */
  onSendConfirmed?: () => void;
  /** This round's propose_memory is in tool mode: the suggestion strip ticket and this round's user message (candidate source, and the fallback run on degradation). */
  proposeMemory?: { ticket: MemorySuggestionTicket; userMessage: ChatMessage };
  /** External search regenerate basis: entry action + source of the message being regenerated; omitted = new send. */
  searchRegenerate?: { action: SearchRegenerateAction; previousCitations?: readonly Citation[] | null };
  /** This turn's external search is handed to the caller at the very start: wrap-up (including stop / failure) is persisted by the caller per it. */
  onExternalSearchReply?: (reply: ExternalSearchReply) => void;
}

export interface ChatOutboundResult<L> {
  pipeline: StreamPipelineResult;
  promptContext: PromptInjectionContext;
  libraryContext: L | undefined;
  /** Outbound options of the last attempt. */
  relayStreamOptions: StreamOptions | undefined;
  /** Memory item ids injected by the final plan (the recomputed one after an overflow recompute). */
  memoryIds: string[];
}

function continuationInstructionsModeOf(continuation: ContinuationIntent): ContinuationInstructionsMode | null {
  const mode = continuation.state.instructionsMode;
  return mode === 'resend' || mode === 'omit' ? mode : null;
}

/**
 * Outbound chain shared by chat and continue: ContextAssembler assembly -> option chain -> 0.90 fallback ->
 * runStreamPipeline -> one overflow-fallback resend -> rho and manifest. Refusal happens in the entry pre-check; a failure is thrown to the caller as is to render in the UI.
 */
export async function runChatOutbound<L extends { entries: LibraryEntry[] }>(
  ctx: ChatOpCtx,
  req: ChatOutboundRequest<L>,
): Promise<ChatOutboundResult<L>> {
  const { store, appendChunk } = ctx;
  const { provider, model, reasoningMode, conversationId } = req;
  const {
    skillId,
    transientGenerationParameters,
    capabilityPreferences,
    excludeCustomFragments = false,
    omitAdditionalBody = false,
    excludeCustomFragmentOwners = [],
    capabilityRecipeOmissions = [],
    capabilityRecipeResendOwners = [],
    excludeCapabilityOwners = [],
  } = req.optionInputs;
  // Only when this turn goes external (resolveWebSearchState().nativeFieldsSuppressed) are native / relay web fields stripped; otherwise unchanged from before.
  // The external row's switch ignores session web search: computed once either way (returns at zero cost when there is no local service).
  const searchConnections = searchConnectionsFromProviders(store.getState().providers ?? []);
  const externalSearchContext = !req.libraryActive && !providerControlsAreManaged(provider)
    && !excludeCapabilityOwners.includes('web')
    ? await loadExternalSearchSendContext({
      provider, model, conversationId, reasoningMode, webOn: req.webSearchEnabled === true,
      connections: searchConnections,
    })
    : null;
  const externalSearchDropsNativeWeb = externalSearchContext?.state.nativeFieldsSuppressed === true;
  const effectiveWebSearchEnabled = req.libraryActive || externalSearchDropsNativeWeb ? false : req.webSearchEnabled;

  const attachmentScopeOptions = buildProviderStreamOptions(
    provider,
    buildStreamOptionsFromIntent(model, reasoningMode, req.webSearchEnabled),
    model,
  );
  // Run this round's attachments through the current model's capabilities again: a retry or an edited resend carries the original message's attachments, possibly from another model.
  // Same vision criterion as the entry point (a relay with unknown vision support still sends images). The pre-send preflight uses the same function.
  const receivableMessages = req.currentTurnId
    ? filterOutboundAttachments({
      messages: req.messages, currentTurnId: req.currentTurnId,
      provider, model, streamOptions: attachmentScopeOptions,
    })
    : withoutUnreceivableImages(req.messages, provider, model, attachmentScopeOptions);
  const contextAssembly = await prepareChatContextAssembly({
    store, conversation: req.conversation, conversationId, provider, model,
    messages: receivableMessages,
    ...(req.keepAssistantId ? { keepAssistantId: req.keepAssistantId } : {}),
    latestUserText: req.latestUserText,
    purpose: req.purpose,
  });
  // The real send takes the retrieval usage: a retrieval that was a cache hit and already billed by a successful send is not counted again.
  const promptContext = unbilledSkillRetrievalUsage(contextAssembly.promptContext);
  const libraryContext = req.loadLibrary ? await req.loadLibrary() : undefined;
  // With attachments, add an attachment guide (to keep the model from inventing wrong content); it goes into [D].
  const hasAttachments = req.currentTurnId !== undefined
    && projectPlanMessages(assembleChatPlan(contextAssembly, { provider, model }), receivableMessages).messages
      .some((message) => message.id === req.currentTurnId && (message.attachments?.length ?? 0) > 0);
  const attachmentGuidance = hasAttachments
    ? (await import('../attachments/attachment-injector')).AttachmentInjector.SYSTEM_PROMPT_GUIDANCE
    : undefined;
  // L3 recall: query = the original text of the user message this answer responds to; this outbound (including an overflow resend) reuses the same copy.
  const recall = recallForTurn({
    items: store.getState().memoryItems,
    useMemory: contextAssembly.input.conversation.useMemory,
    query: req.latestUserText,
    conversationId,
    folderId: req.conversation?.folderID ?? null,
  });
  const contextDynamic: AssembleDynamic = {
    ...(recall.length > 0 ? { recall } : {}),
    ...(libraryContext ? { library: libraryContext.entries } : {}),
    ...(attachmentGuidance ? { attachmentGuide: attachmentGuidance } : {}),
  };

  const clientControlsAllowed = !providerControlsAreManaged(provider);
  const unresolvedGenerationParameters = clientControlsAllowed && !excludeCapabilityOwners.includes('generation') ? resolveGenerationParameterOverrides({
    providerId: provider.id,
    modelId: model.id,
    profileFingerprint: generationParameterProfileFingerprint(provider, model),
    fallbackModelId: generationParameterFallbackModelId(provider, model),
    conversationId,
    transient: transientGenerationParameters,
    // When the chip explicitly picks a level, the whole connection-level reasoning default yields.
    reasoningMode,
    // The final facade filter below is the sole request gate.  Do not
    // pre-drop values here: it would make lifecycle and request policy
    // diverge after metadata/identity changes.
  }) : undefined;
  // A relay without metadata uses a fallback identity, so the web search switch can still send.
  const capabilityIdentity = clientControlsAllowed ? capabilityPreferenceIdentity(provider, model) : null;
  // Send / continue are discrete events, so forwarding runs once here. Typed preferences forward themselves through the read chain
  // inside `resolveCapabilityPreferences`; local custom fields have no such chain and must be run explicitly.
  if (capabilityIdentity) {
    forwardPortCustomFragmentsIfNeeded({
      provider, model, transportIdentity: capabilityIdentity.transportIdentity,
    });
  }
  const singleSendPreferences = req.libraryActive ? { web: 'off' as const } : undefined;
  const storedCapabilityPreferences = clientControlsAllowed ? capabilityPreferences ?? (capabilityIdentity
    ? withRelayWebPreference(resolveCapabilityPreferences({
      ...capabilityIdentity, conversationId, skillId,
      singleSend: singleSendPreferences,
      // Relay default layer: if never set, it is on when the first-send protocol has a saved fragment.
      providerDefault: relayWebProviderDefault(provider, model),
    }), resolveRelayWebPreference(provider, model, {
      conversationId, ...(skillId ? { skillId } : {}),
      ...(singleSendPreferences ? { singleSend: singleSendPreferences } : {}),
      ...(relayWebProviderDefault(provider, model) ? { providerDefault: relayWebProviderDefault(provider, model) } : {}),
    }))
    : undefined) : undefined;
  const resolvedCapabilityPreferences = storedCapabilityPreferences ? {
    ...storedCapabilityPreferences,
    ...(excludeCapabilityOwners.includes('web') || externalSearchDropsNativeWeb ? { web: 'off' as const } : {}),
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
    // When the preference cannot reach the wire right now, it does not count as an "explicit web search request".
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
    allow: !req.libraryActive,
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
  // The additional body is not excluded by named library documents / server retrieval: the contract's attachment points include both library retrieval legs.
  const providerStreamOptions = withAdditionalBody(
    clientControlsAllowed ? buildProviderStreamOptions(provider, streamOptionsWithRecovery, model) : undefined,
    { provider, model, conversationId, omit: omitAdditionalBody },
  );

  // The plan of this request and the assembly it used: overflow recovery, rho write-back and the manifest all follow it.
  const chatUserMaxOutput = userMaxOutputOf(generationParameters);
  const planOptions: { provider: Provider; model: AIModel; dynamic: AssembleDynamic; userMaxOutput: typeof chatUserMaxOutput } = {
    provider, model, dynamic: contextDynamic, userMaxOutput: chatUserMaxOutput,
  };
  // The rho key is the model id actually sent on the wire.
  const wireAssembly = await withChatRhoModel(contextAssembly, provider, model, chatWireModelIdOf(model, providerStreamOptions));
  // An image generation model uses purpose imageGeneration: it sends only plan.imagePrompt plus the last user message's attachments,
  // without system / memory / [D] / checkpoint; the plan has no messages, so neither the 0.90 fallback nor overflow recovery reassemble.
  // It is imageGeneration only when the request actually goes to a dedicated prompt endpoint (official images_api / dashscope_multimodal / minimax_image_generation, relay images_endpoint);
  // Gemini image modality,
  // the Responses inline image tool and official chat_api image generation remain chat protocols, go through chat and carry history.
  const imageGeneration = clientControlsAllowed
    ? Boolean(providerStreamOptions?.supportsImageGen) && dispatchesToImagesEndpoint(provider, model, providerStreamOptions)
    : dispatchesImageGeneration(model);
  const planAssembly: ChatContextAssembly = imageGeneration
    ? { ...wireAssembly, input: { ...wireAssembly.input, purpose: 'imageGeneration' } }
    : wireAssembly;
  const basePlan = assembleChatPlan(planAssembly, planOptions);
  let chatPlan = basePlan;
  let chatPlanAssembly: ChatContextAssembly = planAssembly;
  // For a chat send, first apply the latest stored row under the current history before assembly (image generation / continuation do not).
  const usesCheckpointRows = !imageGeneration && planAssembly.input.purpose === 'chat';
  let storedRowApplied = false;
  // Checkpoint id applied at assembly: pre-send compaction uses it to recognize a row that landed after assembly (null = no row at assembly time).
  let assembledCheckpointId: string | null = null;
  // A deterministic fallback (pre-send / overflow resend) carries the non-empty summary of the current checkpoint winner, or null when there is none.
  let storedSummary: string | null = null;
  // Assembly obtained by applying a stored row -> that row's checkpointId (written into the manifest, from which post-compaction usage judges cleared_since);
  // assemblies from the in-memory fallback and overflow re-projection are not in the table.
  const checkpointIdOfAssembly = new WeakMap<ChatContextAssembly, string>();
  const manifestCheckpointId = () => {
    const id = checkpointIdOfAssembly.get(chatPlanAssembly);
    return id ? { checkpointId: id } : {};
  };
  // A continuation does not apply stored rows, but the deterministic fallback still carries the winner's summary.
  if (!imageGeneration && planAssembly.input.purpose === 'continue') {
    const stored = await latestValidChatCheckpoint(conversationId, planAssembly);
    storedSummary = stored?.summary?.trim() || null;
  }
  if (usesCheckpointRows) {
    const stored = await latestValidChatCheckpoint(conversationId, planAssembly);
    storedSummary = stored?.summary?.trim() || null;
    const applied = stored ? applyCheckpointRowAssembly(planAssembly, stored) : null;
    if (applied && stored) {
      checkpointIdOfAssembly.set(applied, stored.checkpointId);
      chatPlan = assembleChatPlan(applied, planOptions);
      chatPlanAssembly = applied;
      storedRowApplied = true;
      assembledCheckpointId = stored.checkpointId;
    }
  }
  // Compact through the coordinator (AI / fallback decided by the compaction rules) and persist, returning an assembly rebuilt from the new row; noop / failure returns null.
  const compactViaCoordinator = async (
    trigger: 'preSend' | 'overflow',
    plan: typeof basePlan,
    B?: number | null,
  ): Promise<ChatContextAssembly | null> => {
    let row: ContextCheckpointRow | null = null;
    // The stop button also works during compaction: aborting this send aborts the compaction too (including the summary call), and nothing is persisted.
    const compactionController = new AbortController();
    req.setAbortFn(() => compactionController.abort());
    try {
      const coordinator = createCompactionCoordinator({
        context: () => chatCompactionContextOf(planAssembly, plan, {
          provider, model, userMaxOutput: chatUserMaxOutput, ...(B !== undefined ? { B } : {}),
        }),
        summarize: (summaryRequest, signal) => requestCompactionSummary({
          provider, model, req: summaryRequest, chatSystem: plan.system,
          instructions: planAssembly.input.conversation.instructions ?? '', signal,
        }),
      });
      row = (await coordinator.compact(conversationId, trigger, {
        signal: compactionController.signal,
        ...(trigger === 'preSend' ? { assembledCheckpointId } : {}),
      })).row ?? null;
    } catch (error) {
      // A compaction failure does not block the send: treat it as noop.
      console.error(`[ContextCompaction] ${trigger} compaction failed:`, error);
    }
    // Hand the abort hook back: later stops are caught by the abortFn the pipeline registers (it was not "consumed" here).
    req.setAbortFn(null);
    // The user pressed stop during compaction: cancel the whole send and send no chat request.
    if (req.isAbortRequested() || compactionController.signal.aborted) {
      throw new DOMException('Send stopped during context compaction', 'AbortError');
    }
    const applied = row ? applyCheckpointRowAssembly(planAssembly, row) : null;
    if (applied && row) checkpointIdOfAssembly.set(applied, row.checkpointId);
    return applied;
  };
  if (chatPlan.compaction === 'required') {
    // Still goes through 0.90: compact through the coordinator and persist, reassembling with the new row;
    // when the coordinator is noop and there is no stored row to use, fall back to the in-memory fallback (affects this request only, not persisted).
    let compactedAssembly: ChatContextAssembly | null = null;
    if (usesCheckpointRows) compactedAssembly = await compactViaCoordinator('preSend', basePlan);
    if (!compactedAssembly && !storedRowApplied) compactedAssembly = compactChatContextAssembly(planAssembly, chatPlan, storedSummary);
    if (compactedAssembly) {
      chatPlan = assembleChatPlan(compactedAssembly, planOptions);
      chatPlanAssembly = compactedAssembly;
    }
  }
  // Confirmation gate: after compaction and before transport, judge this plan by its estimated input and suspend to wait for the user if it needs to ask; a cancel throws CapConfirmCancelledError.
  // Asks only on the first outbound: the second runPipeline of overflow recovery does not pass here; continue never asks.
  if (req.purpose === 'chat') {
    const gateController = new AbortController();
    // A stop while waiting = cancel: stop is only taken over when the gate really suspends to ask the user. When it does not ask, nothing is registered,
    // otherwise this stop would be "consumed" by the gate's abort hook, the abortFn registered by the pipeline would never receive it, and the request would be wrongly treated as a cancel rollback.
    let asked = false;
    try {
      await gateCapConfirm({
        store, conversationId, provider, model,
        attempt: capConfirmAttemptOf(req.attemptKind),
        // Window used to assemble this plan (tier taken from the assembly), not recomputed from the store.
        window: chatPlanWindowOf(chatPlanAssembly, planOptions),
        estimatedInput: chatPlan.budget.estimatedInput,
        signal: gateController.signal,
        onAsk: () => {
          asked = true;
          req.setAbortFn(() => gateController.abort());
        },
      });
    } finally {
      if (asked) req.setAbortFn(null);
    }
    if (asked && (req.isAbortRequested() || gateController.signal.aborted)) throw new CapConfirmCancelledError();
  }
  req.onSendConfirmed?.();
  // Each chat send records one round (the circuit breaker recovers per round).
  if (usesCheckpointRows) CompactionBreakers.recordTurn(conversationId);
  // max_tokens = plan.budget.oWire: it only travels with the outbound options for a user-supplied key.
  const chatOutputLimit = chatPlan.budget.oWire;
  const plannedStreamOptions = clientControlsAllowed && chatOutputLimit !== undefined
    ? { ...providerStreamOptions, maxOutputTokens: chatOutputLimit }
    : providerStreamOptions;
  // A relay image generation going to /images/generations takes only a one-sentence prompt: use plan.imagePrompt, without [D] / checkpoint.
  const imagePromptStreamOptions = imageGeneration && provider.kind === 'relay'
    ? { ...plannedStreamOptions, relayImagePrompt: chatPlan.imagePrompt ?? '' }
    : plannedStreamOptions;

  // Wire protocol actually used by this request: for a relay look at the transport in the outbound options, for a subscription the upstream backend, for an official provider the catalog.
  const attemptWireProtocol = provider.kind === 'relay'
    ? canonicalFinalTransport(imagePromptStreamOptions?.relayTransport)
    : subscriptionFinalTransport(provider, model)
      ?? canonicalFinalTransport(resolveCatalogModel(model.id, provider.kind)?.transport ?? model.transport);

  // Outbound of one attempt: plan -> history and options. An explicit continuation decides fullPlan / stateful here.
  const prepareAttempt = async (plan: ContextPlan, assembly: ChatContextAssembly) => {
    const fingerprint = chatContinuationFingerprintOf(plan, chatWireModelIdOf(model, imagePromptStreamOptions), assembly);
    const continuationFingerprint = req.continuation
      ? compareChatContinuationFingerprint(req.previousFingerprint, fingerprint)
      : undefined;
    const previousResponseId = req.continuation?.kind === 'previous_id'
      && typeof req.continuation.state.previousResponseId === 'string'
      ? req.continuation.state.previousResponseId
      : null;
    // previous_response_id exists only in the Responses protocol: if this wire protocol is not openai_responses
    // (including relay chat completions) there is no stateful form, so always use the full plan.
    const decision = req.continuation && continuationFingerprint && plan.purpose !== 'imageGeneration'
      && attemptWireProtocol === 'openai_responses'
      ? ContextContinuation.decideContinuation({
        previousResponseId,
        instructionsMode: continuationInstructionsModeOf(req.continuation),
        systemChangedSinceLastLeg: continuationFingerprint.systemChanged,
        modelChanged: continuationFingerprint.modelChanged,
        checkpointChanged: continuationFingerprint.checkpointChanged,
      })
      : { kind: 'fullPlan' as const };
    const planned = projectPlanMessages(plan, receivableMessages);
    let transport: TransportInput;
    let hasVideo = false;
    let blockedByFiles: boolean;
    const videoOptionsOf = (outboundHasVideo: boolean) => {
      const videoOptions = imagePromptStreamOptions && outboundHasVideo
        ? { ...imagePromptStreamOptions, outboundHistoryHasVideo: true }
        : imagePromptStreamOptions;
      // The continuation verdict is decided only once here and handed to the builder explicitly: the builder attaches previous_response_id by it and does not judge again.
      return continuationFingerprint
        ? { ...videoOptions, continuationFingerprint, continuationDecision: decision }
        : videoOptions;
    };
    if (plan.purpose === 'imageGeneration') {
      // A single user message: text = plan.imagePrompt, attachments = the last user message's (already filtered by the current model's capabilities), no system.
      const lastUser = [...receivableMessages].reverse().find((message) => message.role === 'user');
      const imageMessages: ChatMessage[] = lastUser ? [{ ...lastUser, text: plan.imagePrompt ?? '' }] : [];
      hasVideo = await outboundHistoryHasVideo(imageMessages);
      const history = await buildOutboundChatHistory(ctx, {
        messages: imageMessages, provider, model, streamOptions: attachmentScopeOptions,
      });
      transport = transportInput(planned, { options: videoOptionsOf(hasVideo), history });
      blockedByFiles = await relayFirstSendMessagesBlockedByFiles({
        provider, model, messages: imageMessages, streamOptions: attachmentScopeOptions,
      });
    } else if (decision.kind === 'stateful') {
      // The upstream already holds the old context: input sends only the continuation sentence; resend carries system the way this client does, omit does not.
      transport = transportInput(planned, {
        options: videoOptionsOf(hasVideo), stateful: { sendInstructions: decision.sendInstructions },
      });
      // First-send attachment criterion: history is not resent, so there are no attachments.
      blockedByFiles = await relayFirstSendMessagesBlockedByFiles({
        provider, model, messages: [], streamOptions: attachmentScopeOptions,
      });
    } else {
      const projectedMessages = planned.messages;
      // Full plan for continue: for replay-type continuations the service replays the target assistant, so the outbound history no longer carries it.
      const replayKind = plan.purpose === 'continue' ? req.continuation?.kind : undefined;
      const plannedMessages = replayKind && TARGET_REPLAY_CONTINUATION_KINDS.has(replayKind)
        ? continueOutboundMessages(projectedMessages, { id: req.assistantMessageId }, replayKind)
        : projectedMessages;
      // Outbound history has video (including video whose bytes are not loaded) -> Gemini does not choose Interactions.
      hasVideo = await outboundHistoryHasVideo(plannedMessages);
      const history = await buildOutboundChatHistory(ctx, {
        messages: plannedMessages, provider, model, streamOptions: attachmentScopeOptions,
      });
      // First-send attachment criterion: computed from the filtered raw attachments.
      blockedByFiles = await relayFirstSendMessagesBlockedByFiles({
        provider, model, messages: plannedMessages, streamOptions: attachmentScopeOptions,
      });
      transport = transportInput(planned, { options: videoOptionsOf(hasVideo), history });
    }
    return { transport, blockedByFiles, fingerprint, stateful: decision.kind === 'stateful', planned };
  };

  // First prepare an outbound from the plan without web content: the memory-tool registration decision needs to know whether this outbound has a native file part,
  // and the external search plan's host.memoryTools needs the registration result. Web content goes only into [D] and does not change attachments.
  let attempt = await prepareAttempt(chatPlan, chatPlanAssembly);

  // Tool mode new sends attach propose_memory with tool_choice auto (a normal send has no other client tools, so it is the last item).
  const proposeMemory = req.purpose === 'chat' && !imageGeneration ? req.proposeMemory : undefined;
  // This outbound carries a native file part, and once this route attaches a client tool it no longer accepts native files -> memory runs as fallback this turn.
  const nativeFilesBlockToolLoop = req.purpose === 'chat' && !imageGeneration
    && messagesCarryFilePart(attempt.transport.messages)
    && nativeFileModeOf(await resolveAttachmentLine({
      provider, model, streamOptions: attachmentScopeOptions, toolLoop: true,
    })) === 'off';
  // When the effective generation params include json_schema, run as fallback this turn: do not attach propose; candidates go through the v1 memory split.
  const proposeFallback = proposeMemory !== undefined
    && !memoryToolsConnectionSupported(
      provider, model, effectiveWebSearchEnabled, generationParameters, nativeFilesBlockToolLoop,
    );
  if (proposeMemory && proposeFallback) generateMemoryCandidate(store, proposeMemory.ticket, proposeMemory.userMessage);
  let proposeToolsAttached = proposeMemory !== undefined && !proposeFallback;
  // In tool mode, a chat request attaches search_memory after propose_memory (retries / regeneration attach it too).
  const searchMode = req.purpose === 'chat' && !imageGeneration
    && resolveSearchMemoryMode({
      store, conversationId, provider, model, webSearchEnabled: effectiveWebSearchEnabled, generationParameters,
      nativeFilesBlockToolLoop,
    }) === 'tool';
  let searchToolsAttached = searchMode;
  // excludeIds takes the current plan's [D] recall; tool_result is trimmed by this request's recallMax / rhoHi.
  const searchTurn = searchMode
    ? createSearchMemoryTurn({
      store,
      conversationId,
      folderId: req.conversation?.folderID ?? null,
      recallIds: () => planRecallIds(chatPlan, recall),
      recallMax: () => planRecallMax(chatPlan),
      rhoHi: () => chatPlanAssembly.input.rhoHi ?? CONTEXT_BUDGET_CONSTANTS.rho0,
    })
    : undefined;
  // External web search: after the refusal preflight and compaction pass, plan this turn before assembling the request; pre-search / reused content goes into [D].
  const searchModelKey = externalSearchModelKey(provider.id, model.id);
  const searchPlanInput = (rejection: { status: number; leg: number } | null) => ({
    toolCall: resolveModelCapabilityEvidence({ key: 'tool_call', provider, model }).support,
    host: {
      library: false,
      mcp: false,
      // The registry this turn really has memory tool entries (same decision as the library / MCP path).
      memoryTools: hostMemoryToolsRegistered({ propose: proposeToolsAttached, search: searchToolsAttached }),
      nativeMoonshotLoop: false,
      serverMaxSteps: effectiveMaxSteps(currentMcpRuntimeConfig()),
      // Web's generic loop replays providerContinuation on every leg (tool_loop continuation table).
      continuationKind: 'tool_loop',
    },
    thinking: {
      on: searchThinkingOn(reasoningMode, excludeCapabilityOwners.includes('reasoning')),
      protocol: searchThinkingProtocol(provider, attemptWireProtocol),
      continuationStateAvailable: true,
    },
    ...(req.searchRegenerate ? { regenerate: req.searchRegenerate } : {}),
    userText: req.latestUserText,
    B: chatPlan.budget.B ?? null,
    upstreamRejection: rejection,
    toolsRejectedBefore: toolsRejectedBefore(conversationId, searchModelKey),
  });
  const webSearchTurn = req.purpose === 'chat' && !imageGeneration && !chatPlan.reject
    ? planExternalSearchTurn(externalSearchContext, searchPlanInput(null))
    : null;
  const searchExecutor = webSearchTurn && externalSearchContext
    ? createExternalSearchExecutor(webSearchTurn.binding, { uid: externalSearchContext.data.uid, connections: searchConnections })
    : null;
  const startSearch = (plan: SearchTurnPlan): ExternalSearchReply | null => {
    if (!webSearchTurn || !searchExecutor) return null;
    clearExternalSearchActivity(conversationId);
    for (const t of plan.telemetry) trackEvent(t.event as TelemetryEventName, t.props);
    const reply = startExternalSearchReply({
      turn: webSearchTurn,
      plan,
      B: chatPlan.budget.B ?? null,
      rhoHi: chatPlanAssembly.input.rhoHi ?? CONTEXT_BUDGET_CONSTANTS.rho0,
      execute: searchExecutor,
      onActivity: (detail) => {
        setExternalSearchActivity(conversationId, detail);
        store.getState().setStreamingActivity(conversationId, detail ? 'external_search' : null);
      },
      track: (event, props) => trackEvent(event, props),
    });
    req.onExternalSearchReply?.(reply);
    return reply;
  };
  // Pre-search / reuse: same event loop, deliver.content goes verbatim as the segment right after <oriveo-library> in [D].
  const applySearchDynamic = async (reply: ExternalSearchReply): Promise<boolean> => {
    const plan = reply.turn.plan;
    let web: string | null = null;
    if (plan.reuse) web = reply.reuse(req.searchRegenerate?.previousCitations) || null;
    else if (plan.presearch) web = await reply.search(plan.presearch.query, plan.presearch.count);
    if (!web) return false;
    planOptions.dynamic = { ...planOptions.dynamic, web };
    chatPlan = assembleChatPlan(chatPlanAssembly, planOptions);
    return true;
  };
  let searchReply = webSearchTurn ? startSearch(webSearchTurn.plan) : null;
  // [D] changed: re-prepare the outbound from the plan with web content (attachments / file part same as above).
  if (searchReply && !searchReply.turn.plan.requestHasWebSearchTool && await applySearchDynamic(searchReply)) {
    attempt = await prepareAttempt(chatPlan, chatPlanAssembly);
  }
  req.onRelayTransport(attempt.transport.options?.relayTransport);

  // Outbound facts after the final facade gate: web search counts as "used" only if the web configuration really went into this request.
  // The gate is the final outbound options rather than the user's intent: when the facade rejects it, or the transport envelope does not support
  // Web Search (the intersection inside `buildProviderStreamOptions`), nothing is sent even if the switch is on.
  // Field-level boundary: the provider_kind / model_id registered in the matrix are sent as is (without them the "web search usage by model"
  // dashboard is useless); execution facts such as the recipe identifier, requested/observed status, search terms and response
  // evidence never enter telemetry.
  // For a relay, "the effective fragment was actually merged this round" is the criterion (webSearchDispatched).
  if (webSearchDispatched(provider, attempt.transport.options)) {
    trackEvent('web_search_used', {
      provider_kind: telemetryProviderKind(provider.kind),
      model_id: telemetryModelID(provider.kind, model.id),
    });
  }

  // Ids of search results handed to the model and actually used (tail-leg wrap-up or a resend after empty text with thinking), merged into memoryIds.
  let searchMemoryIds: string[] = [];
  const hostMemoryTools = (): ProxyToolDefinition[] => [
    ...(proposeToolsAttached ? [PROPOSE_MEMORY_PROXY_TOOL] : []),
    ...(searchToolsAttached ? [SEARCH_MEMORY_PROXY_TOOL] : []),
  ];
  const isHostMemoryCall = (call: CompletedToolCall): boolean => (proposeToolsAttached && isProposeMemoryCall(call))
    || (searchToolsAttached && isSearchMemoryToolName(call.name));
  const withProposeTools = (transport: TransportInput): TransportInput => {
    const tools = hostMemoryTools();
    return tools.length > 0
      ? { ...transport, options: { ...transport.options, clientTools: { tools, toolChoice: 'auto' } } }
      : transport;
  };
  const runPipeline = () => {
    const current = attempt;
    return runStreamPipeline({
      store,
      appendChunk,
      conversationId,
      messageId: req.assistantMessageId,
      provider,
      model,
      transport: withProposeTools(current.transport),
      initialText: req.initialText,
      setAbortFn: req.setAbortFn,
      suppressStreamCitations: Boolean(libraryContext),
      relayMessagesBlockedByFiles: current.blockedByFiles,
      continuation: req.continuation,
      // The continuation state is stored together with the fingerprint of the leg that produced it (local, not persisted).
      onContinuation: (continuation) => continuationCaptured(conversationId, req.assistantMessageId, continuation, current.fingerprint),
    });
  };
  // Rho samples and overflow misses are recorded only on single-leg requests: a library retrieval leg / direct-context text changes the outbound shape,
  // and the input of a stateful continuation includes the old context held upstream, so neither represents this connection's token/byte ratio; the MCP tool loop is already routed away at the entry.
  const rhoEligible = () => !libraryContext && !attempt.stateful && !imageGeneration;
  // A failed attempt: on overflow with predicted P-hat < U write back rho and record the manifest; returns whether it overflowed.
  const recordFailedAttempt = async (error: unknown): Promise<boolean> => {
    const requestRelayTransport = attempt.transport.options?.relayTransport;
    const overflow = isContextOverflowFailure(error, provider.kind, requestRelayTransport);
    const wireModelId = failedWireModelIdOf(error, model, attempt.transport.options);
    if (overflow && rhoEligible() && !req.isAbortRequested()) {
      await recordChatOverflowMiss({ provider, model, wireModelId, plan: chatPlan, userMaxOutput: chatUserMaxOutput });
    }
    await appendChatManifest({
      conversationId, provider, model, plan: chatPlan, userMaxOutput: chatUserMaxOutput,
      wireModelId, family: failedStopFamilyOf(error, provider.kind, requestRelayTransport),
      ...(chatPlanAssembly.tailFrom ? { tailFrom: chatPlanAssembly.tailFrom } : {}),
      ...manifestCheckpointId(),
      // A user cancel that ends by throwing (often wrapped as a network error) is recorded as interrupted, not as error / incomplete.
      stopReason: req.isAbortRequested()
        ? 'interrupted'
        : overflow ? 'context_window_exceeded' : stopReasonFromError(error, provider.kind, failureOutputStarted(error)),
    });
    return overflow;
  };
  // A first leg carrying tools is deterministically rejected (before any text, no structured tool_calls seen) -> resend once without tools, run the fallback this round and record the degradation;
  // after a successful tool-less resend, write the tool capability memory the way the MCP path does (the same recordToolCallFallback).
  const sendingAccountId = getActiveUIDSync();
  const recordProposeToolFallback = (rejection: ToolCallRejectionContext | undefined): void => {
    if (getActiveUIDSync() !== sendingAccountId) return;
    const options = attempt.transport.options;
    const identity: ToolCallRecoveryIdentity = {
      accountId: sendingAccountId,
      connectionId: provider.id,
      authMode: provider.kind === 'relay' ? options?.relayAuthMode ?? 'unknown' : provider.authMode ?? 'apiKey',
      canonicalModelId: normalizeModelFactsID(provider.kind === 'relay' ? model.id : model.canonicalModelId ?? model.id),
      finalTransport: effectiveCapabilityTransport(provider, model, undefined, options),
    };
    recordToolCallFallback(provider, model, identity, rejection, options?.relayTransport);
  };
  // Current leg of the tool loop (legStarted from 0): rejection fallback only recognizes the first leg.
  let webSearchLoopLegIndex = 0;
  // External search tool path (search only): generic ToolCallLoop, memory tools join the same loop and no tail leg is added (generic_tool_loop).
  const runWebSearchToolLoop = async (reply: ExternalSearchReply): Promise<StreamPipelineResult> => {
    const toolHost = reply.turn.plan.toolHost;
    if (!toolHost.webSearchRegistered) throw new Error('web_search tool path without registered host');
    const entries: ToolRegistryEntry[] = [];
    if (proposeToolsAttached && proposeMemory) {
      entries.push(createProposeMemoryEntry({
        ticket: proposeMemory.ticket,
        store,
        repo: currentMemoryCandidateRepository(store),
        userText: proposeMemory.userMessage.text ?? '',
        ids: { conversationId, messageId: proposeMemory.userMessage.id, folderId: req.conversation?.folderID ?? null },
      }));
    }
    if (searchToolsAttached && searchTurn) entries.push(createSearchMemoryEntry(searchTurn));
    entries.push(createWebSearchEntry(reply));
    proposeToolsAttached = false;
    searchToolsAttached = false;
    const controller = new AbortController();
    req.setAbortFn(() => controller.abort());
    const agentOutbound = await prepareAgentSubscriptionOutbound(store, provider, model, attempt.transport.options);
    const unhandled: CompletedToolCall[] = [];
    let legText = '';
    try {
      const result = await new ToolCallLoop({
        registry: new ToolRegistry(entries),
        runLeg: ({ messages, tools, toolChoice }) => {
          const transport = transportInput(attempt.planned, { options: agentOutbound.streamOptions, toolLeg: { messages, tools } });
          return sendLibraryAgentLeg(
            provider.kind, agentOutbound.apiKey, model.id, transport.messages, transport.tools,
            requestBaseURLText(provider), transport.options, toolChoice,
          );
        },
        signal: controller.signal,
        limits: {
          maxSteps: toolHost.maxSteps,
          maxConsecutiveToolFailures: toolHost.consecutiveFailureBreaker === 'off' ? Number.POSITIVE_INFINITY : toolHost.consecutiveFailureBreaker,
        },
        stoppedErrorCode: HOST_PROMPTS[toolHost.prompts].stoppedErrorCode,
        onUnhandledToolCalls: (calls) => {
          unhandled.push(...calls.map((call) => ({ id: call.id, name: call.function.name, arguments: call.function.arguments })));
        },
      }).run(attempt.transport.messages as ProxyMessage[], (event) => {
        if (event.type === 'legStarted') {
          legText = '';
          webSearchLoopLegIndex = event.legIndex;
        }
        else if (event.type === 'textDelta') {
          legText += event.text;
          store.getState().setStreamingActivity(conversationId, null);
          store.getState().setStreamingText(conversationId, appendText(req.initialText, legText));
        } else if (event.type === 'reasoningDelta') store.getState().appendStreamingReasoningText(conversationId, event.text);
        else if (event.type === 'toolCallsAccepted') store.getState().setStreamingText(conversationId, req.initialText);
      });
      return {
        outcome: req.isAbortRequested() ? 'guarded' : 'completed',
        fullText: appendText(req.initialText, result.text),
        reasoningText: (store.getState().streamingReasoningTexts[conversationId] ?? '').trim(),
        citations: undefined,
        usage: result.usage,
        imageAttachments: [],
        capabilityResults: [],
        unhandledToolCalls: unhandled,
        ...(result.finish ? { finish: result.finish } : {}),
      };
    } finally {
      req.setAbortFn(null);
    }
  };
  // The first leg with web_search is rejected by upstream with 400 / 422 (before any text): recompute the plan; if it switches to pre-search, resend this turn as pre-search.
  // A 400 / 422 from the second leg on is a normal error: no switching, no new reply state. Context-too-long recognized by the overflow check is excluded first and goes to overflow recovery.
  const runSearchToolPath = async (reply: ExternalSearchReply): Promise<StreamPipelineResult> => {
    try {
      return await runWebSearchToolLoop(reply);
    } catch (error) {
      const status = error instanceof ToolLoopError ? error.status : undefined;
      if (req.isAbortRequested() || !(error instanceof ToolLoopError) || error.streamStarted || webSearchLoopLegIndex !== 0
        || isContextOverflowFailure(error, provider.kind, attempt.transport.options?.relayTransport)
        || status === undefined || !TOOLS_REJECTED_STATUSES.includes(status) || !webSearchTurn) throw error;
      const replanned = planExternalSearchTurn(externalSearchContext, searchPlanInput({ status, leg: 0 }));
      if (!replanned || !replanned.plan.presearch) throw error;
      rememberToolsRejected(conversationId, searchModelKey);
      const fallback = startSearch(replanned.plan);
      if (!fallback) throw error;
      searchReply = fallback;
      // Tools removed from this turn: propose_memory runs fallback this turn (same as resend without tools).
      if (proposeMemory) generateMemoryCandidate(store, proposeMemory.ticket, proposeMemory.userMessage);
      store.getState().setStreamingText(conversationId, req.initialText);
      await applySearchDynamic(fallback);
      attempt = await prepareAttempt(chatPlan, chatPlanAssembly);
      return runPipeline();
    }
  };
  const runFirstLeg = async (): Promise<StreamPipelineResult> => {
    if (searchReply?.turn.plan.requestHasWebSearchTool) return runSearchToolPath(searchReply);
    try {
      return await runPipeline();
    } catch (error) {
      // The upstream of an official connection rejects media / parameters by signature: record a v2 negative cache (a parameter is recorded as `param:<name>` and omitted next time), no retry;
      // the error still lands on the failure card as usual (Relay uses its own loop).
      if (provider.kind !== 'relay' && !req.isAbortRequested()) {
        attachOfficialInputRejection(error, recordOfficialInputRejection({
          provider, model, streamOptions: attachmentScopeOptions, messages: attempt.transport.messages, error,
        }));
      }
      const rejectionContext = error && typeof error === 'object'
        ? (error as { toolCallRejectionContext?: unknown }).toolCallRejectionContext
        : undefined;
      const degrade = (proposeToolsAttached || searchToolsAttached) && !req.isAbortRequested()
        && shouldDegradeProposeMemory({
          toolUnsupported: isDeterministicToolCallUnsupported(rejectionContext),
          legIndex: 0,
          streamStarted: failureAnyOutputStarted(error),
          receivedStructuredToolCalls: false,
        });
      if (!degrade) throw error;
      // The two host tools share one degradation set.
      proposeToolsAttached = false;
      searchToolsAttached = false;
      markProposeMemoryDegraded(provider.id, model.id);
      if (proposeMemory) generateMemoryCandidate(store, proposeMemory.ticket, proposeMemory.userMessage);
      const resent = await runPipeline();
      // degrade has confirmed this is a deterministic tool-rejection context.
      recordProposeToolFallback(rejectionContext as ToolCallRejectionContext);
      return resent;
    }
  };
  // Tail leg: the first leg ended with tool_calls and all are host tools (propose / search) -> replay the first leg (with the continuation
  // if any) plus one tool_result per call and add one more leg; the final text = first-leg text followed by tail-leg text.
  const runProposeMemoryTailLeg = async (
    first: StreamPipelineResult,
    calls: CompletedToolCall[],
    results: ReadonlyMap<string, string>,
    continuation: StreamPipelineResult['continuation'],
  ): Promise<StreamPipelineResult> => {
    const firstLegText = first.fullText.startsWith(req.initialText)
      ? first.fullText.slice(req.initialText.length)
      : first.fullText;
    const toolCalls: ProxyToolCall[] = calls.map((call) => ({
      id: call.id, type: 'function' as const, function: { name: call.name, arguments: call.arguments },
    }));
    const legMessages: ProxyMessage[] = [
      ...attempt.transport.messages,
      openAIChatToolAdapter.encodeAssistantToolCalls({ text: firstLegText, toolCalls, ...(continuation ? { continuation } : {}) }),
      ...toolCalls.map((call) => openAIChatToolAdapter.encodeToolResult({
        callID: call.id, toolName: call.function.name, content: results.get(call.id) ?? PROPOSE_MEMORY_TOOL_RESULT,
      })),
    ];
    const agentOutbound = await prepareAgentSubscriptionOutbound(store, provider, model, attempt.transport.options);
    const transport = transportInput(attempt.planned, {
      options: agentOutbound.streamOptions,
      toolLeg: { messages: legMessages, tools: hostMemoryTools() },
    });
    // The tail leg renders after the first-leg text.
    store.getState().setStreamingText(conversationId, first.fullText);
    const handle = sendLibraryAgentLeg(
      provider.kind,
      agentOutbound.apiKey,
      model.id,
      transport.messages,
      transport.tools,
      requestBaseURLText(provider),
      transport.options,
      'none',
    );
    req.setAbortFn(handle.abort);
    let tailText = '';
    // Thrown as is on failure: the caller renders an error card as for an ordinary failure, and the candidate the first leg already built is kept.
    const tail = await readStream(
      handle.stream,
      req.initialText,
      (chunk) => {
        tailText += chunk;
        store.getState().setStreamingActivity(conversationId, null);
        store.getState().setStreamingText(conversationId, appendText(first.fullText, tailText));
      },
      undefined,
      (chunk) => {
        if (chunk) store.getState().appendStreamingReasoningText(conversationId, chunk);
      },
    );
    // A propose call in the tail leg only builds a candidate and a search call is not executed; no further leg is added.
    await applyProposeMemoryCalls((tail.toolCalls ?? []).filter(isProposeMemoryCall));
    const tailOtherCalls = (tail.toolCalls ?? []).filter((call) => !isProposeMemoryCall(call) && !isHostMemoryCall(call));
    const guardMsg = store.getState().conversations
      .find((c) => c.id === conversationId)?.messages.find((m) => m.id === req.assistantMessageId);
    const { finish: _firstFinish, continuation: _firstContinuation, ...firstRest } = first;
    return {
      ...firstRest,
      outcome: guardMsg && (guardMsg.state === 'interrupted' || guardMsg.state === 'failed') ? 'guarded' : 'completed',
      fullText: appendText(first.fullText, tail.fullText.startsWith(req.initialText)
        ? tail.fullText.slice(req.initialText.length)
        : tail.fullText),
      reasoningText: [first.reasoningText, tail.reasoningText].filter((text) => text.trim() !== '').join('\n\n'),
      citations: tail.citations ?? first.citations,
      usage: mergeToolLoopUsage(first.usage, tail.usage),
      ...(tail.servedModelID ?? first.servedModelID ? { servedModelID: tail.servedModelID ?? first.servedModelID } : {}),
      imageAttachments: [...first.imageAttachments, ...tail.imageAttachments],
      unhandledToolCalls: tailOtherCalls,
      ...(tail.finish ? { finish: tail.finish } : {}),
    };
  };
  // Each propose call writes its candidate in order (counted per round); the first create of the round becomes the suggestion strip; failures only warn.
  let proposedInTurn = 0;
  let instructedInTurn = 0;
  const applyProposeMemoryCalls = async (calls: CompletedToolCall[]): Promise<void> => {
    if (!proposeMemory || calls.length === 0) return;
    const { ticket, userMessage } = proposeMemory;
    try {
      const conv = store.getState().conversations.find((c) => c.id === conversationId);
      const uid = getActiveUIDSync();
      // Lazy import: bootstrap pulls up the chat module, so a static import would form a cycle (same as generateMemoryCandidate).
      const { getOrCreateStableWebDeviceId } = await import('../bootstrap');
      const items = createMemoryItemRepository({ store, uid, deviceId: getOrCreateStableWebDeviceId() });
      const repository = createMemoryCandidateRepository({ uid, items });
      const countedBefore = proposedInTurn;
      for (const call of calls) {
        const prior = proposedInTurn;
        proposedInTurn += 1;
        try {
          const candidate = await repository.propose(call.arguments, prior, {
            userText: userMessage.text ?? '',
            messageId: userMessage.id,
            conversationId,
            folderId: conv?.folderID ?? null,
            priorInstructInTurn: instructedInTurn,
            onInstruct: (sentence) => {
              instructedInTurn += 1;
              offerInstructSuggestion(store, ticket, sentence);
            },
          });
          resolveProposedMemorySuggestion(store, ticket, candidate);
        } catch (error) {
          console.warn('[memory-candidate] propose failed', error);
        }
      }
      proposedInTurn = countedBefore + calls.length;
    } catch (error) {
      console.warn('[memory-candidate] propose failed', error);
    }
  };
  // Overflow recovery: if no text / thinking / image was produced -> compact, then automatically resend once reusing the same assistant message; 401/429/5xx do not count as overflow.
  // A chat send compacts through the coordinator and persists (taking B the same way as the in-memory fallback); on noop the in-memory fallback is kept.
  const overflowRecoveryAssembly = async (): Promise<ChatContextAssembly | null> => {
    let recoveryAssembly: ChatContextAssembly | null = null;
    if (usesCheckpointRows) {
      recoveryAssembly = await compactViaCoordinator('overflow', chatPlan, chatPlan.budget.B ?? chatPlan.budget.estimatedInput);
    }
    // The in-memory fallback reselects the tail from the full history without stored rows (rows already applied are not wrapped into a new checkpoint again); B still takes the failed request's.
    recoveryAssembly ??= overflowFallbackChatContextAssembly(planAssembly, { ...basePlan, budget: chatPlan.budget }, storedSummary);
    return recoveryAssembly;
  };
  // Resend once with the recovered assembly (only once); if it fails again, record one failed attempt and throw as is.
  const resendAfterOverflow = async (recoveryAssembly: ChatContextAssembly): Promise<StreamPipelineResult> => {
    // Internal automatic resend within this turn (reuse): if the tool path already has web results this turn, already-produced sources are rebuilt into an envelope per reuse and put in [D];
    // the resend registers no tools and sends no search request; message facts and sources remain those real searches of this turn (numbering matches the envelope).
    // Content from pre-search / reuse / rejection fallback is already in planOptions.dynamic.web; the recovery plan carries it as-is.
    if (searchReply?.turn.plan.requestHasWebSearchTool && searchReply.webResultsPresent()) {
      const web = searchReply.replayEnvelope();
      if (web) planOptions.dynamic = { ...planOptions.dynamic, web };
    }
    const recoveryPlan = assembleChatPlan(recoveryAssembly, planOptions);
    // The checkpoint changed: a stateful continuation falls back to the full plan by fingerprint.
    attempt = await prepareAttempt(recoveryPlan, recoveryAssembly);
    chatPlan = recoveryPlan;
    chatPlanAssembly = recoveryAssembly;
    req.onRelayTransport(attempt.transport.options?.relayTransport);
    try {
      return await runPipeline();
    } catch (secondError) {
      await recordFailedAttempt(secondError);
      throw secondError;
    }
  };
  let pipeline: StreamPipelineResult;
  // Overflow recovery resends only once for the whole round (shared by HTTP and in-stream).
  let overflowResent = false;
  try {
    pipeline = await runFirstLeg();
  } catch (firstError) {
    const overflow = await recordFailedAttempt(firstError);
    let recoveryAssembly: ChatContextAssembly | null = null;
    if (overflow && !failureAnyOutputStarted(firstError) && !req.isAbortRequested()) {
      recoveryAssembly = await overflowRecoveryAssembly();
    }
    if (!recoveryAssembly) throw firstError;
    pipeline = await resendAfterOverflow(recoveryAssembly);
    overflowResent = true;
  }
  // The first leg finished normally but the in-stream stop_reason says the window was exceeded (Anthropic model_context_window_exceeded) and no output was produced ->
  // go through the same recovery as an HTTP overflow, once only; if output was already produced it wraps up as usual and stopReason records context_window_exceeded.
  // "Output produced" uses the same criterion as failureAnyOutputStarted for HTTP overflow: text (after initialText), thinking or an image, any one of them.
  const pipelineAnyOutputStarted = (result: StreamPipelineResult): boolean => {
    const text = result.fullText ?? '';
    const newText = text.startsWith(req.initialText) ? text.slice(req.initialText.length) : text;
    return newText !== '' || (result.reasoningText ?? '') !== '' || result.imageAttachments.length > 0;
  };
  const inStreamOverflow = (result: StreamPipelineResult): boolean => result.outcome === 'completed'
    && !req.isAbortRequested()
    && !pipelineAnyOutputStarted(result)
    && ContextOverflowClassifier.isOverflow(stopReasonFromFinish(result.finish, false));
  if (!overflowResent && inStreamOverflow(pipeline)) {
    const overflowed = pipeline;
    const overflowOptions = overflowed.relaySentStreamOptions ?? attempt.transport.options;
    const overflowWireModelId = chatWireModelIdOf(model, overflowOptions);
    if (rhoEligible()) {
      await recordChatOverflowMiss({
        provider, model, wireModelId: overflowWireModelId, plan: chatPlan, userMaxOutput: chatUserMaxOutput,
      });
    }
    const recoveryAssembly = await overflowRecoveryAssembly();
    if (recoveryAssembly) {
      // The first leg records one overflow manifest; when not recovered, the wrap-up below records it.
      await appendChatManifest({
        conversationId, provider, model, plan: chatPlan, userMaxOutput: chatUserMaxOutput,
        wireModelId: overflowWireModelId,
        family: chatStopFamilyOf(overflowed.finish, provider.kind, overflowOptions?.relayTransport),
        ...(chatPlanAssembly.tailFrom ? { tailFrom: chatPlanAssembly.tailFrom } : {}),
        ...manifestCheckpointId(),
        stopReason: 'context_window_exceeded',
      });
      pipeline = await resendAfterOverflow(recoveryAssembly);
      overflowResent = true;
    }
  }
  // After the resend, if the stream still says the window was exceeded with no output -> wrap up as failed like an HTTP second overflow (record one failed attempt, then throw).
  if (overflowResent && inStreamOverflow(pipeline)) {
    const overflowOptions = pipeline.relaySentStreamOptions ?? attempt.transport.options;
    const overflowWireModelId = chatWireModelIdOf(model, overflowOptions);
    if (rhoEligible()) {
      await recordChatOverflowMiss({
        provider, model, wireModelId: overflowWireModelId, plan: chatPlan, userMaxOutput: chatUserMaxOutput,
      });
    }
    await appendChatManifest({
      conversationId, provider, model, plan: chatPlan, userMaxOutput: chatUserMaxOutput,
      wireModelId: overflowWireModelId,
      family: chatStopFamilyOf(pipeline.finish, provider.kind, overflowOptions?.relayTransport),
      ...(chatPlanAssembly.tailFrom ? { tailFrom: chatPlanAssembly.tailFrom } : {}),
      ...manifestCheckpointId(),
      stopReason: 'context_window_exceeded',
    });
    throw inStreamOverflowFailure(pipeline.finish?.finishRaw);
  }
  let proposeTailLegRan = false;
  if ((proposeToolsAttached || searchToolsAttached) && pipeline.outcome === 'completed') {
    const firstLegCalls = pipeline.unhandledToolCalls ?? [];
    const hostCalls = firstLegCalls.filter(isHostMemoryCall);
    if (hostCalls.length > 0) {
      const otherCalls = firstLegCalls.filter((call) => !isHostMemoryCall(call));
      await applyProposeMemoryCalls(hostCalls.filter(isProposeMemoryCall));
      // One tool_result per call: propose returns a fixed text and search executes in order (round counting and excludeIds accumulate).
      const hostResults = new Map<string, string>();
      for (const call of hostCalls) {
        hostResults.set(call.id, isProposeMemoryCall(call) || !searchTurn
          ? PROPOSE_MEMORY_TOOL_RESULT
          : searchTurn.run(call.arguments));
      }
      // Host tool calls do not enter the "no executor" card.
      pipeline = { ...pipeline, unhandledToolCalls: otherCalls };
      // Without thinking -> add a leg whether or not there is a continuation; with thinking and no continuation state -> wrap up if the first-leg text is non-empty,
      // otherwise resend the original request once without tools (no degradation recorded, the candidate is kept).
      if (otherCalls.length === 0 && !req.isAbortRequested()) {
        const firstLegReasoned = pipeline.reasoningText.trim() !== ''
          || pipeline.continuation?.kind === 'replay_reasoning';
        const firstLegText = pipeline.fullText.startsWith(req.initialText)
          ? pipeline.fullText.slice(req.initialText.length)
          : pipeline.fullText;
        if (!firstLegReasoned || pipeline.continuation) {
          pipeline = await runProposeMemoryTailLeg(pipeline, hostCalls, hostResults, pipeline.continuation);
          proposeTailLegRan = true;
          searchMemoryIds = searchTurn?.returnedIds ?? [];
        } else if (firstLegText.trim() === '') {
          const first = pipeline;
          proposeToolsAttached = false;
          searchToolsAttached = false;
          // Items found by search follow the [D] automatic recall and are trimmed as a whole under the same recallMax.
          const searchEntries = searchTurn?.returnedEntries ?? [];
          if (searchEntries.length > 0) {
            const resendPlan = assembleChatPlan(chatPlanAssembly, {
              ...planOptions,
              dynamic: { ...contextDynamic, recall: [...recall, ...searchEntries] },
            });
            attempt = await prepareAttempt(resendPlan, chatPlanAssembly);
            chatPlan = resendPlan;
          }
          const retry = await runPipeline();
          // Usage of the two legs is added up (same as the tail leg); no rho sample is recorded.
          pipeline = { ...retry, usage: mergeToolLoopUsage(first.usage, retry.usage) };
          proposeTailLegRan = true;
        }
      }
    }
  }
  const observedInput = observedChatInputOf(pipeline.usage);
  // Outbound options actually delivered (they differ from the requested ones after a first-send protocol switch / protocol-level fallback).
  const deliveredOptions = pipeline.relaySentStreamOptions ?? attempt.transport.options;
  const wireModelId = chatWireModelIdOf(model, deliveredOptions);
  // The user already pressed stop and the stream closed silently (not via guarded): also recorded as interrupted.
  const attemptStopReason = pipeline.outcome === 'guarded' || req.isAbortRequested()
    ? 'interrupted' as const
    : stopReasonFromFinish(pipeline.finish, (pipeline.fullText ?? '').trim() !== '');
  // An input that wraps up with context_window_exceeded has hit the window and is not this connection's normal ratio, so it records no sample.
  // A round with a tail leg records no rho sample: the usage of two legs is added up and is not a single leg's token/byte ratio.
  if (pipeline.outcome === 'completed' && rhoEligible() && !proposeTailLegRan && attemptStopReason !== 'context_window_exceeded') {
    await recordChatRhoSample({ provider, wireModelId, plan: chatPlan, history: attempt.transport.messages, observedInput });
  }
  await appendChatManifest({
    conversationId, provider, model, plan: chatPlan, userMaxOutput: chatUserMaxOutput,
    wireModelId, family: chatStopFamilyOf(pipeline.finish, provider.kind, deliveredOptions?.relayTransport),
    ...(chatPlanAssembly.tailFrom ? { tailFrom: chatPlanAssembly.tailFrom } : {}),
    ...manifestCheckpointId(),
    stopReason: attemptStopReason,
    ...(observedInput !== undefined ? { observedInput } : {}),
  });
  return {
    pipeline, promptContext, libraryContext, relayStreamOptions: attempt.transport.options,
    memoryIds: [...new Set([...chatPlan.memoryIds, ...searchMemoryIds])],
  };
}

/**
 * Failure object for a second in-stream overflow: HTTP 200 wraps up normally with no error body, so isContextOverflowFailure cannot recognize it;
 * the marker makes the failure wrap-up record context_window_exceeded. The message carries only the upstream finishRaw (technical original text, not self-written copy).
 */
const IN_STREAM_OVERFLOW = Symbol('inStreamContextOverflow');

function inStreamOverflowFailure(finishRaw: string | null | undefined): ProviderError {
  const raw = finishRaw?.trim() || 'context_window_exceeded';
  return Object.assign({ kind: 'badRequest', title: raw, message: raw, source: 'provider' } as ProviderError, {
    [IN_STREAM_OVERFLOW]: true,
  });
}

function isInStreamOverflowFailure(err: unknown): boolean {
  return Boolean(err && typeof err === 'object' && (err as { [IN_STREAM_OVERFLOW]?: unknown })[IN_STREAM_OVERFLOW] === true);
}

/** Wire tool definition of propose_memory (canonical OpenAI function shape; the route projects it by protocol). */
const PROPOSE_MEMORY_PROXY_TOOL: ProxyToolDefinition = PROPOSE_MEMORY_TOOL as unknown as ProxyToolDefinition;

function isProposeMemoryCall(call: CompletedToolCall): boolean {
  return call.name === PROPOSE_MEMORY_TOOL_NAME;
}

/** Kind of continuation in which the service replays the target assistant according to the recipe (insertReplayBeforeFinalUser). */
const TARGET_REPLAY_CONTINUATION_KINDS = new Set(['replay_blocks', 'replay_reasoning']);

/**
 * Outbound candidates for a continuation: history is cut up to and including the target assistant, and the target uses this run's clean snapshot.
 * With continuationKind it is used for the already projected outbound history: for replay-type kinds the service replays the target, so the target is dropped here
 * and the rest kept (including the trailing continuation sentence), leaving a single outbound assistant; previous_id (fullPlan fallback) and the no-continuation-state case keep the target.
 * Decided by kind, not by whether a state field exists (same criterion on all three platforms).
 */
export function continueOutboundMessages(
  messages: ChatMessage[],
  target: Pick<ChatMessage, 'id'> & Partial<ChatMessage>,
  continuationKind?: string,
): ChatMessage[] {
  const index = messages.findIndex((message) => message.id === target.id);
  if (continuationKind !== undefined && TARGET_REPLAY_CONTINUATION_KINDS.has(continuationKind)) {
    return index < 0 ? messages : [...messages.slice(0, index), ...messages.slice(index + 1)];
  }
  if (index < 0) return [...messages, target as ChatMessage];
  return [...messages.slice(0, index), target as ChatMessage];
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

function generationParameterRejectionOf(error: unknown): { parameterId: string; signatureId?: string } | undefined {
  const value = error && typeof error === 'object'
    ? (error as { generationParameterRejection?: unknown }).generationParameterRejection
    : undefined;
  if (!value || typeof value !== 'object') return undefined;
  const { parameterId, signatureId } = value as { parameterId?: unknown; signatureId?: unknown };
  if (typeof parameterId !== 'string' || !parameterId) return undefined;
  return typeof signatureId === 'string' && signatureId ? { parameterId, signatureId } : { parameterId };
}

/** The relay web switch reads the fixed identity: the web value resolved under the protocol-bearing identity is replaced by it; thinking levels are untouched. */
function withRelayWebPreference(
  preferences: CapabilityPreferences,
  relayWeb: CapabilityPreferences['web'] | undefined,
): CapabilityPreferences {
  return relayWeb ? { ...preferences, web: relayWeb } : preferences;
}
