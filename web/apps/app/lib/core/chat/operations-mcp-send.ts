/**
 * Sending when only remote MCP is on (the library agent is off): model legs, the generic tool loop and
 * the MCP entries.
 *
 * The loop runs in the browser: model legs go through `/api/chat/stream` and tool execution through
 * `/api/mcp/forward`. The structure mirrors the library agent's send path (operations-library-send.ts):
 * the same leg runner, the same subscription outbound handling and the same recovery that resends once
 * without tools when the upstream rejects `tools`. When the library agent is on as well, this path is
 * not used and the MCP entries are merged into its registry instead.
 *
 * The entry point is `sendMessage`: it delegates here when the conversation has MCP servers switched
 * on and the connection can carry tools, so retry and edit-and-resend pick up tools without each entry
 * point deciding separately.
 */
import type {
  AIModel,
  Attachment,
  ChatMessage,
  Conversation,
  Provider,
  QuoteContext,
  ReasoningMode,
} from '@oriveo/shared';
import type { ProxyToolCall } from '@oriveo/core/providers/request-builders/runtime';
import type { GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import type { StreamUsage } from '@oriveo/core/providers/types';
import { stopReasonFromError, stopReasonFromFinish } from './stop-reason-outcome';
import { ToolCallLoop, type ToolCallLoopOptions } from '@oriveo/core/tools/tool-call-loop';
import { ToolLoopError, type ToolLoopProgressEvent, type ToolLoopResult, type ToolRegistryEntry } from '@oriveo/core/tools/tool-loop-contracts';
import { ToolRegistry } from '@oriveo/core/tools/tool-registry';
import { MCP_LOOP_PROMPTS, MCP_LOOP_STOPPED_ERROR_CODE, MCP_SAFETY_PROMPT, mcpLoopLimits, type McpToolPlan } from '@oriveo/core/mcp/index';
import { oriveoAbortReason } from '@oriveo/core/util/abort-reason';
import { mapErrorKindKey } from '../../utils/chat-stream-utils';
import { transportInput } from './context-pipeline/transport-input';
import { filterCurrentTurnAttachments, withoutUnreceivableImages } from './attachment-policy';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { adoptMcpDraftServers, createMcpSendSession } from '../mcp/mcp-chat';
import { currentMcpRuntimeConfig } from '../mcp/mcp-store';
import { telemetryToolName } from '../mcp/mcp-telemetry';
import { normalizeModelFactsID, resolveCatalogModel } from '../metadata/metadata-client';
import { sendLibraryAgentLeg } from '../providers/proxy-client';
import { trackEvent, telemetryProviderKind } from '../telemetry';
import { withAdditionalBody } from './additional-body-settings';
import { createAdditionalBodyRetryTap } from './additional-body-retry-tap';
import {
  appendText,
  completeRound,
  patchAssistantMessage,
  prepareAgentSubscriptionOutbound,
  prepareToolLoopContext,
  readProviderErrorSource,
} from './agent-send-shared';
import { withMemoryItemIds } from './memory-item-ids';
import { generateMemoryCandidate, offerDirectiveSuggestion } from './conversation-instructions/directive-suggestion';
import type { MemorySuggestionTicket } from './conversation-instructions/memory-suggestion';
import { markProposeMemoryDegraded, memoryToolsConnectionSupported, resolveProposeMemoryMode } from './propose-memory-runtime';
import { resolveSearchMemoryMode } from './search-memory-runtime';
import { createProposeMemoryEntry, currentMemoryCandidateRepository } from './propose-memory-entry';
import { effectiveCapabilityTransport } from './capability-evidence';
import { recordToolCallFallback, toolCallRememberedUnsupported } from './relay-rejection-loop';
import { applyRelayToolRejection } from '../providers/relay-key-access-writeback';
import { capabilityRuntimeIdentity, resolveCapabilityPreferences } from './capability-preference-settings';
import {
  isDeterministicToolCallUnsupported,
  type ToolCallRecoveryIdentity,
  type ToolCallRejectionContext,
} from './capability-recovery-runtime';
import { deriveCostFields, mergeMessageUsageFields } from './cost-fields';
import { migrateDraftScopedModelControls } from './draft-scope-migration';
import { generationParameterFallbackModelId, generationParameterProfileFingerprint, resolveGenerationParameterOverrides } from './generation-parameter-settings';
import { createAssistantMessage, createUserMessage } from './message-factory';
import type { ChatOpCtx, SendHandle } from './operations';
import { reportSendCompletion } from './send-completion';
import { prepareSendStart, reportSendStartedTelemetry, rollbackSendStart } from './send-start';
import { CapConfirmCancelledError, capConfirmAttemptOf, gateCapConfirm, onceCallback } from './context-visibility/cap-confirm-gate';
import { reportChatFailed } from './send-failure';
import type { ChatAttemptKind } from '../telemetry/chat-failure';
import { requestBaseURLText } from '../providers/endpoint-source';
import { PROVIDER_REQUEST_FAILED_TITLE } from '../providers/error-i18n';
import {
  buildProviderStreamOptions,
  buildStreamOptionsFromIntent,
  filterGenerationParameterOverrides,
  filterRequestCapabilityIntent,
} from './stream-options';

export interface SendMcpToolMessageParams {
  /** "Retry without the additional body": omitted for this one send only; the stored content is unchanged. */
  omitAdditionalBody?: boolean;
  text: string;
  prevMessages: ChatMessage[];
  conversation: Conversation | undefined;
  provider: Provider;
  model: AIModel;
  reasoningMode: ReasoningMode;
  /** The MCP tools available to this request (the non-empty result of `prepareMcpSend`). */
  plan: McpToolPlan;
  attachments?: Attachment[];
  quoteContext?: QuoteContext;
  skillId?: string;
  pinnedNoteIds?: string[];
  userMessageOverride?: ChatMessage;
  assistantMessageOverride?: ChatMessage;
  persistUserMessage?: boolean;
  userMessageAlreadyInHistory?: boolean;
  historyMessages?: ChatMessage[];
  appendToAssistant?: boolean;
  onNewConversation?: (convId: string) => void;
  onFailed?: (text: string) => void;
  generationParameterDraftSessionId?: string;
  /** Entry point that started this attempt (telemetry attempt_kind); defaults to send. */
  attemptKind?: ChatAttemptKind;
  transientGenerationParameters?: GenerationParameterOverrides;
  /** Called once after the pre-send confirmation passes (including when none is needed) and before the first leg, same as sendMessage. */
  onSendConfirmed?: () => void;
  /**
   * A fresh user send: after persisting, decide the propose_memory mode here and open this round's suggestion strip (same as the library path); the ticket
   * must hang on the assistant message created inside this function, which the caller cannot reach. In tool mode propose_memory is registered as the last registry entry.
   */
  freshUserSend?: { webSearchEnabled?: boolean };
}

export function sendMcpToolMessage(ctx: ChatOpCtx, params: SendMcpToolMessageParams): SendHandle {
  const { store, te } = ctx;
  const sendConfirmed = onceCallback(params.onSendConfirmed);
  const userMessage = params.userMessageOverride ?? createUserMessage({
    text: params.text,
    provider: params.provider,
    model: params.model,
    attachments: params.attachments,
    quoteContext: params.quoteContext,
  });
  const baseAssistant = params.assistantMessageOverride ?? createAssistantMessage({
    provider: params.provider,
    model: params.model,
    baseCreatedAt: userMessage.createdAt,
  });
  // A retry is a brand-new reply: the previous round's steps and "no executor" notices are not carried
  // over. Only a continuation keeps appending to the existing ones.
  const assistantMessage: ChatMessage = params.appendToAssistant
    ? baseAssistant
    : { ...baseAssistant, toolSteps: undefined, toolStepLimitReached: undefined, unhandledToolCalls: undefined };
  const initialText = params.appendToAssistant ? assistantMessage.text : '';
  const controller = new AbortController();
  const sendingAccountId = getActiveUIDSync();

  const attemptKind = params.attemptKind ?? 'send';
  const { finalConvId, isFirstMessage, initialConversationSnapshot, sendStartedAt } = prepareSendStart({
    store,
    userMsg: userMessage,
    assistantMsg: assistantMessage,
    prevMessages: params.prevMessages,
    persistUserMessage: params.persistUserMessage,
    conversation: params.conversation,
    provider: params.provider,
    model: params.model,
    reasoningMode: params.reasoningMode,
    webSearchEnabled: false,
    attachments: params.attachments,
    skillId: params.skillId ?? params.conversation?.skillId,
    pinnedNoteIds: params.pinnedNoteIds,
    onNewConversation: params.onNewConversation,
  });
  let sentReported = false;
  const reportSent = () => {
    if (sentReported) return;
    sentReported = true;
    reportSendStartedTelemetry({
      finalConvId,
      isFirstMessage,
      provider: params.provider,
      model: params.model,
      reasoningMode: params.reasoningMode,
      webSearchEnabled: false,
      attachments: params.attachments,
      skillId: params.skillId ?? params.conversation?.skillId,
      attemptKind,
    });
  };
  migrateDraftScopedModelControls({
    provider: params.provider,
    model: params.model,
    conversation: params.conversation,
    draftSessionId: params.generationParameterDraftSessionId,
    conversationId: finalConvId,
  });
  // New conversation: move the servers switched on in the draft scope under the real id, so later sends
  // find them by conversation id.
  if (!params.conversation) adoptMcpDraftServers(params.generationParameterDraftSessionId, finalConvId);
  const effectiveConversation = params.conversation ?? initialConversationSnapshot;
  let proposeEntry: ToolRegistryEntry | undefined;
  let proposeTicket: MemorySuggestionTicket | undefined;
  if (params.freshUserSend) {
    const proposeMemoryMode = resolveProposeMemoryMode({
      store, conversationId: finalConvId, provider: params.provider, model: params.model, freshSend: true,
      webSearchEnabled: params.freshUserSend.webSearchEnabled,
    });
    const memoryTicket = offerDirectiveSuggestion(store, finalConvId, userMessage, assistantMessage.id, proposeMemoryMode);
    if (proposeMemoryMode === 'tool') {
      proposeTicket = memoryTicket;
      proposeEntry = createProposeMemoryEntry({
        ticket: memoryTicket,
        store,
        repo: currentMemoryCandidateRepository(store),
        userText: userMessage.text ?? '',
        ids: {
          conversationId: finalConvId,
          messageId: userMessage.id,
          folderId: store.getState().conversations.find((c) => c.id === finalConvId)?.folderID ?? null,
        },
      });
    }
  }

  const runtimeConfig = currentMcpRuntimeConfig();
  const session = createMcpSendSession({
    uid: sendingAccountId,
    conversationId: finalConvId,
    messageId: assistantMessage.id,
    plan: params.plan,
    initialSteps: params.appendToAssistant ? assistantMessage.toolSteps : undefined,
    runtimeConfig,
    onSteps: (steps) => patchAssistantMessage(store, finalConvId, assistantMessage.id, { toolSteps: steps }),
    onActivity: (activity) => store.getState().setStreamingActivity(finalConvId, activity),
  });
  const toolStepsPatch = (): Partial<ChatMessage> => {
    const steps = session.steps();
    return steps.length > 0 ? { toolSteps: steps } : {};
  };

  let latestUsage: StreamUsage | undefined;
  let retrievalCost = 0;
  const unhandled: ProxyToolCall[] = [];

  // The failure block reads send-path facts from the model leg, so the tap lives outside the try.
  let additionalBodyRetryTap: ReturnType<typeof createAdditionalBodyRetryTap> | undefined;
  const done = (async () => {
    try {
      // Normalization (failed / interrupted markers, kept target) is done by the assembler; here we only build the outbound history.
      const outboundDraft = params.historyMessages
        ?? (params.userMessageAlreadyInHistory ? params.prevMessages : [...params.prevMessages, userMessage]);
      const attachmentScopeOptions = buildProviderStreamOptions(
        params.provider,
        buildStreamOptionsFromIntent(params.model, params.reasoningMode, false),
        params.model,
      );
      // Same vision criterion as the entry point (a relay with unknown vision support still sends images).
      const outbound = filterCurrentTurnAttachments(
        withoutUnreceivableImages(outboundDraft, params.provider, params.model, attachmentScopeOptions),
        userMessage.id, params.provider, params.model);
      // The assembler (purpose toolLoopLeg) produces the single system message with the MCP safety prompt at the end; every leg reuses it as is.
      const toolLoopContext = await prepareToolLoopContext(ctx, {
        conversation: effectiveConversation,
        conversationId: finalConvId,
        provider: params.provider,
        model: params.model,
        messages: outbound,
        ...(params.appendToAssistant ? { keepAssistantId: assistantMessage.id } : {}),
        latestUserText: params.text,
        streamOptions: attachmentScopeOptions,
        toolSafety: MCP_SAFETY_PROMPT,
      });
      const history = toolLoopContext.history;
      const promptContext = toolLoopContext.promptContext;
      retrievalCost = promptContext.retrievalCost;
      // Confirmation gate: after compaction and before the first leg, judge the estimated input of this plan; a cancel throws CapConfirmCancelledError.
      // Only a gate that actually asked the user makes a stop count as a cancel rollback; without a prompt, a stop is still received by the first leg as an abort and finishes as an interruption.
      let asked = false;
      await gateCapConfirm({
        store, conversationId: finalConvId, provider: params.provider, model: params.model,
        attempt: capConfirmAttemptOf(attemptKind),
        window: toolLoopContext.window,
        estimatedInput: toolLoopContext.planned.plan.budget.estimatedInput,
        signal: controller.signal,
        onAsk: () => { asked = true; },
      });
      if (asked && controller.signal.aborted) throw new CapConfirmCancelledError();
      sendConfirmed();

      const unresolvedGenerationParameters = resolveGenerationParameterOverrides({
        providerId: params.provider.id,
        modelId: params.model.id,
        profileFingerprint: generationParameterProfileFingerprint(params.provider, params.model),
        fallbackModelId: generationParameterFallbackModelId(params.provider, params.model),
        conversationId: finalConvId,
        transient: params.transientGenerationParameters,
        reasoningMode: params.reasoningMode,
      });
      const capabilityIdentity = capabilityRuntimeIdentity(params.provider, params.model);
      // A request carrying client-side tools does not enable web search as well (same as the library
      // agent): the loop does not consume web citations.
      const capabilityPreferences = capabilityIdentity ? resolveCapabilityPreferences({
        ...capabilityIdentity, conversationId: finalConvId,
        singleSend: { web: 'off' },
      }) : undefined;
      const preliminaryOptions = buildProviderStreamOptions(
        params.provider,
        buildStreamOptionsFromIntent(params.model, params.reasoningMode, false, unresolvedGenerationParameters, capabilityPreferences),
        params.model,
      );
      const requestIntent = filterRequestCapabilityIntent({
        provider: params.provider,
        model: params.model,
        reasoningMode: params.reasoningMode,
        webSearchEnabled: false,
        streamOptions: preliminaryOptions,
      });
      const generationParameters = filterGenerationParameterOverrides(params.provider, params.model, unresolvedGenerationParameters, preliminaryOptions);
      const rawOptions = buildStreamOptionsFromIntent(
        params.model,
        requestIntent.reasoning,
        requestIntent.supportsWebSearch,
        generationParameters,
        requestIntent.capabilityPreferences,
      );
      // The additional body is the last step of every chat request body, so every tool-call round of an MCP send carries it too.
      const streamOptions = withAdditionalBody(
        buildProviderStreamOptions(params.provider, rawOptions, params.model),
        { provider: params.provider, model: params.model, conversationId: finalConvId, omit: params.omitAdditionalBody },
      );
      const agentOutbound = await prepareAgentSubscriptionOutbound(store, params.provider, params.model, streamOptions);
      const retryTap = createAdditionalBodyRetryTap(agentOutbound.streamOptions);
      additionalBodyRetryTap = retryTap;
      const toolCallIdentity: ToolCallRecoveryIdentity = {
        accountId: sendingAccountId,
        connectionId: params.provider.id,
        authMode: params.provider.kind === 'relay'
          ? streamOptions?.relayAuthMode ?? 'unknown'
          : params.provider.authMode ?? 'apiKey',
        // A relay records tool-call observations under the literal model ID: a dated snapshot and its base
        // are two different models.
        canonicalModelId: normalizeModelFactsID(params.provider.kind === 'relay'
          ? params.model.id
          : params.model.canonicalModelId ?? params.model.id),
        finalTransport: effectiveCapabilityTransport(params.provider, params.model, undefined, agentOutbound.streamOptions),
      };
      // The upstream has explicitly rejected `tools` on this connection before, so tools are known to be
      // unsupported: send directly without them.
      const toolsEnabled = !toolCallRememberedUnsupported(params.provider, params.model, toolCallIdentity);
      // When tools are known to be unsupported, propose_memory cannot be sent: run the fallback for this round.
      if (!toolsEnabled && proposeTicket) generateMemoryCandidate(store, proposeTicket, userMessage);
      // The effective generation parameters carry json_schema: do not register propose this round and use the fallback for the candidate (same decision as a plain send).
      if (toolsEnabled && proposeTicket && !memoryToolsConnectionSupported(
        params.provider, params.model, params.freshUserSend?.webSearchEnabled, generationParameters,
      )) {
        generateMemoryCandidate(store, proposeTicket, userMessage);
        proposeEntry = undefined;
        proposeTicket = undefined;
      }
      // In tool mode search_memory is registered after propose_memory (retries and regenerations register it the same way).
      const searchEntry = resolveSearchMemoryMode({
        store, conversationId: finalConvId, provider: params.provider, model: params.model,
        webSearchEnabled: params.freshUserSend?.webSearchEnabled, generationParameters,
      }) === 'tool' ? toolLoopContext.searchMemoryEntry() : undefined;

      let legText = '';
      const onProgress = (event: ToolLoopProgressEvent): void => {
        switch (event.type) {
          case 'legStarted':
            legText = '';
            break;
          case 'textDelta':
            legText += event.text;
            // The activity line is cleared as soon as body text arrives.
            store.getState().setStreamingActivity(finalConvId, null);
            store.getState().setStreamingText(finalConvId, appendText(initialText, legText));
            break;
          case 'reasoningDelta':
            store.getState().appendStreamingReasoningText(finalConvId, event.text);
            break;
          case 'usage':
            latestUsage = event.usage;
            break;
          case 'toolCallsAccepted':
            // After a leg with tool calls the body is cleared and the next leg renders from scratch (same
            // semantics as the library loop).
            store.getState().setStreamingText(finalConvId, initialText);
            break;
          default:
            break;
        }
      };
      const loopOptions = (mode: 'enabled' | 'disabled'): ToolCallLoopOptions => ({
        registry: mode === 'enabled'
          ? new ToolRegistry([...session.entries, ...(proposeEntry ? [proposeEntry] : []), ...(searchEntry ? [searchEntry] : [])])
          : ToolRegistry.empty,
        runLeg: ({ messages, tools, toolChoice }) => {
          const transport = transportInput(toolLoopContext.planned, {
            options: agentOutbound.streamOptions,
            toolLeg: { messages, tools },
          });
          return retryTap.wrap(sendLibraryAgentLeg(
            params.provider.kind,
            agentOutbound.apiKey,
            params.model.id,
            transport.messages,
            transport.tools,
            requestBaseURLText(params.provider),
            transport.options,
            toolChoice,
          ));
        },
        signal: controller.signal,
        limits: mcpLoopLimits(runtimeConfig),
        prompts: MCP_LOOP_PROMPTS,
        stoppedErrorCode: MCP_LOOP_STOPPED_ERROR_CODE,
        toolsMode: mode,
        // Names outside the lookup table are never executed; they go through the existing "no executor"
        // notice card and its event.
        onUnhandledToolCalls: (calls) => { unhandled.push(...calls); },
      });

      let activeLegIndex = 0;
      const trackLeg = (event: ToolLoopProgressEvent): void => {
        if (event.type === 'legStarted') activeLegIndex = event.legIndex;
        onProgress(event);
      };
      let result: ToolLoopResult;
      let toolFallbackApplied = false;
      let toolFallbackRejection: ToolCallRejectionContext | undefined;
      try {
        result = await new ToolCallLoop(loopOptions(toolsEnabled ? 'enabled' : 'disabled')).run(history, trackLeg);
      } catch (error) {
        // The relay key verdict is written back exactly as in the normal send path. Having no access is not
        // a tools problem, so it is not resent.
        const keyAccess = error instanceof ToolLoopError && error.source === 'provider' && !error.streamStarted
          ? applyRelayToolRejection(store, params.provider, params.model, error.toolCallRejectionContext)
          : 'none';
        // Same criterion as the library path: resend once without tools only when it is the first leg and
        // the upstream deterministically rejected `tools` before emitting any text.
        const eligible = toolsEnabled
          && activeLegIndex === 0
          && error instanceof ToolLoopError
          && error.source === 'provider'
          && !error.streamStarted
          && isDeterministicToolCallUnsupported(error.toolCallRejectionContext)
          && keyAccess !== 'model_access_denied';
        if (!eligible) throw error;
        // `eligible` has confirmed this is a deterministic tool rejection context.
        toolFallbackRejection = (error as ToolLoopError).toolCallRejectionContext as ToolCallRejectionContext;
        store.getState().setStreamingText(finalConvId, initialText);
        // This send carried propose_memory: record the degradation and run the fallback for this round.
        if (proposeTicket) {
          markProposeMemoryDegraded(params.provider.id, params.model.id);
          generateMemoryCandidate(store, proposeTicket, userMessage);
        }
        result = await new ToolCallLoop(loopOptions('disabled')).run(history, trackLeg);
        toolFallbackApplied = true;
      }
      latestUsage = result.usage;
      if (toolFallbackApplied && getActiveUIDSync() === sendingAccountId) {
        recordToolCallFallback(params.provider, params.model, toolCallIdentity, toolFallbackRejection, agentOutbound.streamOptions?.relayTransport);
      }
      for (const call of unhandled) {
        trackEvent('tool_call_unhandled', {
          providerKind: telemetryProviderKind(params.provider.kind),
          transport: resolveCatalogModel(params.model.id, params.provider.kind)?.transport ?? params.model.transport ?? 'unknown',
          toolName: telemetryToolName(call.function.name),
        });
      }

      const costInfo = deriveCostFields(result.usage, params.model, params.provider.kind, params.provider.authMode);
      const reasoningText = (store.getState().streamingReasoningTexts[finalConvId] ?? '').trim();
      const deliveredText = appendText(initialText, result.text);
      const delivered: ChatMessage = withMemoryItemIds({
        ...assistantMessage,
        text: deliveredText,
        state: 'delivered',
        stopReason: stopReasonFromFinish(result.finish, deliveredText.trim() !== ''),
        ...(reasoningText ? { reasoningText } : {}),
        estimatedCost:
          (params.appendToAssistant ? assistantMessage.estimatedCost ?? 0 : 0) + costInfo.cost + promptContext.retrievalCost,
        costSource: costInfo.costSource,
        ...mergeMessageUsageFields(params.appendToAssistant ? assistantMessage : {}, costInfo),
        ...toolStepsPatch(),
        ...(result.stepLimitReached ? { toolStepLimitReached: true } : {}),
        ...(unhandled.length > 0
          ? { unhandledToolCalls: unhandled.map((call) => ({ id: call.id, name: call.function.name, arguments: call.function.arguments })) }
          : {}),
      }, toolLoopContext.memoryIds, Boolean(params.appendToAssistant));
      completeRound(store, finalConvId, effectiveConversation, params.prevMessages, userMessage, delivered);
      reportSent();
      reportSendCompletion({
        store,
        provider: params.provider,
        model: params.model,
        conversationId: finalConvId,
        effectiveConversation,
        skillId: effectiveConversation?.skillId,
        usage: result.usage,
        cost: costInfo.cost + promptContext.retrievalCost,
        costSource: costInfo.costSource,
        servedModelID: undefined,
        processedAttachments: [],
        promptContext,
        sendStartedAt,
        completedAt: new Date().toISOString(),
        attemptKind,
      });
    } catch (error) {
      if (error instanceof CapConfirmCancelledError) {
        // Cancel means rollback: delete this message pair locally (the user message has not been synced), report neither sent nor failed, and do not call onFailed.
        rollbackSendStart(store, finalConvId, params.persistUserMessage !== false && !params.userMessageAlreadyInHistory
          ? [userMessage.id, assistantMessage.id]
          : [assistantMessage.id]);
        return {
          rolledBack: {
            text: params.text,
            ...(params.attachments?.length ? { attachments: params.attachments } : {}),
            ...(params.quoteContext ? { quoteContext: params.quoteContext } : {}),
          },
        };
      }
      // Failed before the gate: do what normally happens after confirmation anyway (only a cancel at the confirmation skips it).
      sendConfirmed();
      // Exactly one sent event per attempt: a stop or a failure also reports it first, through the same helper as the plain send.
      reportSent();
      const partialCost = latestUsage
        ? deriveCostFields(latestUsage, params.model, params.provider.kind, params.provider.authMode)
        : undefined;
      const partialCostPatch: Partial<ChatMessage> = partialCost
        ? {
            estimatedCost: (params.appendToAssistant ? assistantMessage.estimatedCost ?? 0 : 0) + partialCost.cost + retrievalCost,
            costSource: partialCost.costSource,
            ...mergeMessageUsageFields(params.appendToAssistant ? assistantMessage : {}, partialCost),
          }
        : {};
      const state = store.getState();
      const currentAssistant = state.conversations
        .find((conversation) => conversation.id === finalConvId)
        ?.messages.find((message) => message.id === assistantMessage.id);
      const partialText = state.streamingTexts[finalConvId] || currentAssistant?.text || initialText;
      if (controller.signal.aborted) {
        // stop() may already have persisted this message as interrupted: only add the steps, do not rewrite the body.
        if (currentAssistant?.state !== 'interrupted') {
          patchAssistantMessage(store, finalConvId, assistantMessage.id, {
            ...assistantMessage,
            text: partialText,
            state: 'interrupted',
            stopReason: 'interrupted',
            ...toolStepsPatch(),
            ...partialCostPatch,
          });
        } else {
          patchAssistantMessage(store, finalConvId, assistantMessage.id, toolStepsPatch());
        }
        return;
      }
      const failure = describeFailure(error);
      // A provider-sourced title is stored as the English source string and translated at render time
      // (same as operations-send).
      const failureTitle = failure.source === 'provider' ? PROVIDER_REQUEST_FAILED_TITLE : te(`${mapErrorKindKey(failure.kind)}.title`);
      // A round whose tools already ran gets no retry affordance: resending would execute the tools twice.
      const additionalBodyRetry = additionalBodyRetryTap?.resolve({ sideEffects: session.steps().length > 0 });
      patchAssistantMessage(store, finalConvId, assistantMessage.id, {
        ...assistantMessage,
        text: partialText,
        state: 'failed',
        // Persist stopReason: hadContent only looks at the answer text, not reasoning.
        stopReason: stopReasonFromError(error, params.provider.kind, partialText.trim() !== ''),
        errorTitle: additionalBodyRetry?.eligible ? te('additionalBodyRejected.upstreamTitle') : failureTitle,
        ...(additionalBodyRetry?.eligible ? { additionalBodyRetryEligible: true } : {}),
        ...(additionalBodyRetry?.eligible && additionalBodyRetry.technicalDetail
          ? { errorTechnicalDetail: additionalBodyRetry.technicalDetail }
          : {}),
        errorDetail: failure.detail,
        errorKind: failure.kind,
        ...(failure.source ? { errorSource: failure.source } : {}),
        ...toolStepsPatch(),
        ...partialCostPatch,
      });
      const raw = error && typeof error === 'object' ? error as Record<string, unknown> : {};
      reportChatFailed({
        provider: params.provider,
        model: params.model,
        attemptKind,
        error: {
          ...raw,
          kind: failure.kind,
          ...(typeof raw.name === 'string' ? {} : error instanceof Error ? { name: error.name } : {}),
          ...(error instanceof TypeError && raw.networkDetail === undefined ? { networkDetail: 'fetch_failed' } : {}),
          outputStarted: partialText.trim() !== (initialText ?? '').trim()
            || (state.streamingReasoningTexts[finalConvId] ?? '').trim() !== '',
        },
        sendStartedAt,
      });
      params.onFailed?.(params.text);
    } finally {
      store.getState().clearStreamingForConversation(finalConvId);
    }
  })();

  return {
    convId: finalConvId,
    msgId: assistantMessage.id,
    abort: () => controller.abort(),
    done,
    attemptKind,
  };
}

/** Maps an error from a model leg, subscription outbound or the self-correction limit to the three fields the failure card needs. `kind` is a short code; `detail` is the sentence shown to the user. */
function describeFailure(error: unknown): { kind: string; detail: string; source?: NonNullable<ChatMessage['errorSource']> } {
  const source = readProviderErrorSource(error);
  const code = error && typeof error === 'object' ? (error as { code?: unknown; kind?: unknown }) : {};
  const kind = typeof code.kind === 'string' ? code.kind : typeof code.code === 'string' ? code.code : 'upstream';
  const isTransport = error instanceof TypeError;
  return {
    kind: isTransport ? 'network' : kind,
    // A locally generated error (the attachments of this turn do not fit) puts the user-facing sentence in detail; message carries only the stable code.
    detail: typeof (error as { detail?: unknown } | null)?.detail === 'string'
      ? (error as { detail: string }).detail
      : error instanceof Error ? error.message : String(error),
    ...(source ? { source } : isTransport ? { source: 'network' as const } : {}),
  };
}
