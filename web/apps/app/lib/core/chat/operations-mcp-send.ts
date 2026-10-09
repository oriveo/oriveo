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
import type { ProxyMessage, ProxyToolCall } from '@oriveo/core/providers/request-builders/runtime';
import type { GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import type { StreamUsage } from '@oriveo/core/providers/types';
import { ToolCallLoop, type ToolCallLoopOptions } from '@oriveo/core/tools/tool-call-loop';
import { ToolLoopError, type ToolLoopProgressEvent, type ToolLoopResult } from '@oriveo/core/tools/tool-loop-contracts';
import { ToolRegistry } from '@oriveo/core/tools/tool-registry';
import { MCP_LOOP_PROMPTS, MCP_LOOP_STOPPED_ERROR_CODE, mcpLoopLimits, mcpSystemPrompt, type McpToolPlan } from '@oriveo/core/mcp/index';
import { mapErrorKindKey, sanitizeOutboundMessages } from '../../utils/chat-stream-utils';
import { buildOutboundChatHistory } from './outbound-history';
import { filterCurrentTurnAttachments } from './attachment-policy';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { adoptMcpDraftServers, createMcpSendSession } from '../mcp/mcp-chat';
import { currentMcpRuntimeConfig } from '../mcp/mcp-store';
import { telemetryToolName } from '../mcp/mcp-telemetry';
import { normalizeModelFactsID, resolveCatalogModel } from '../metadata/metadata-client';
import { sendLibraryAgentLeg } from '../providers/proxy-client';
import { trackEvent, telemetryModelID, telemetryProviderKind } from '../telemetry';
import { relaySendTelemetryProperties } from '../telemetry/relay-properties';
import { withAdditionalBody } from './additional-body-settings';
import { createAdditionalBodyRetryTap } from './additional-body-retry-tap';
import {
  appendText,
  completeRound,
  patchAssistantMessage,
  prepareAgentSubscriptionOutbound,
  readProviderErrorSource,
} from './agent-send-shared';
import { effectiveCapabilityTransport, resolveModelCapabilityEvidence } from './capability-evidence';
import { capabilityRuntimeIdentity, resolveCapabilityPreferences } from './capability-preference-settings';
import {
  isDeterministicToolCallUnsupported,
  recordToolCallSupportFalse,
  toolCallSupportIsRememberedFalse,
  type ToolCallRecoveryIdentity,
} from './capability-recovery-runtime';
import { deriveCostFields, mergeMessageUsageFields } from './cost-fields';
import { migrateDraftScopedModelControls } from './draft-scope-migration';
import { generationParameterProfileFingerprint, resolveGenerationParameterOverrides } from './generation-parameter-settings';
import { createAssistantMessage, createUserMessage } from './message-factory';
import type { ChatOpCtx, SendHandle } from './operations';
import { buildPromptInjectionContext } from './prompt-injection';
import { reportSendCompletion } from './send-completion';
import { prepareSendStart } from './send-start';
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
  transientGenerationParameters?: GenerationParameterOverrides;
}

export function sendMcpToolMessage(ctx: ChatOpCtx, params: SendMcpToolMessageParams): SendHandle {
  const { store, te } = ctx;
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

  const { finalConvId, initialConversationSnapshot, sendStartedAt } = prepareSendStart({
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
      const sanitizedOutbound = sanitizeOutboundMessages(
        params.historyMessages
          ?? (params.userMessageAlreadyInHistory ? params.prevMessages : [...params.prevMessages, userMessage]),
        params.appendToAssistant ? assistantMessage.id : undefined,
      );
      const attachmentScopeOptions = buildProviderStreamOptions(
        params.provider,
        buildStreamOptionsFromIntent(params.model, params.reasoningMode, false),
        params.model,
      );
      const mayInjectVision = resolveModelCapabilityEvidence({
        key: 'vision_input', provider: params.provider, model: params.model, streamOptions: attachmentScopeOptions,
      }).support === 'supported';
      const outbound = filterCurrentTurnAttachments(mayInjectVision
        ? sanitizedOutbound
        : sanitizedOutbound.map((message) => ({
          ...message,
          attachments: message.attachments?.filter((attachment) => attachment.kind !== 'image'),
        })), userMessage.id, params.provider, params.model);
      const history = (await buildOutboundChatHistory(ctx, {
        messages: outbound, provider: params.provider, model: params.model,
        streamOptions: attachmentScopeOptions, toolLoop: true,
      })) as ProxyMessage[];
      const promptContext = await buildPromptInjectionContext(
        store,
        effectiveConversation,
        params.text,
        params.model,
        params.provider.kind,
      );
      retrievalCost = promptContext.retrievalCost;
      // The user's system prompt comes first; the safety prompt is appended after it.
      history.unshift({ role: 'system', content: mcpSystemPrompt(promptContext.systemContent) });
      if (promptContext.memoryInjected) store.getState().incrementMemoryUsageCount();

      const unresolvedGenerationParameters = resolveGenerationParameterOverrides({
        providerId: params.provider.id,
        modelId: params.model.id,
        profileFingerprint: generationParameterProfileFingerprint(params.provider, params.model),
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
      const rawOptions = buildStreamOptionsFromIntent(
        params.model,
        requestIntent.reasoning,
        requestIntent.supportsWebSearch,
        filterGenerationParameterOverrides(params.provider, params.model, unresolvedGenerationParameters, preliminaryOptions),
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
        canonicalModelId: normalizeModelFactsID(params.model.canonicalModelId ?? params.model.id),
        finalTransport: effectiveCapabilityTransport(params.provider, params.model, undefined, agentOutbound.streamOptions),
      };
      // The upstream has explicitly rejected `tools` on this connection before, so tools are known to be
      // unsupported: send directly without them.
      const toolsEnabled = !toolCallSupportIsRememberedFalse(toolCallIdentity);

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
        registry: mode === 'enabled' ? new ToolRegistry(session.entries) : ToolRegistry.empty,
        runLeg: ({ messages, tools, toolChoice }) => retryTap.wrap(sendLibraryAgentLeg(
          params.provider.kind,
          agentOutbound.apiKey,
          params.model.id,
          messages,
          tools,
          params.provider.baseURLText,
          agentOutbound.streamOptions,
          toolChoice,
        )),
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
      try {
        result = await new ToolCallLoop(loopOptions(toolsEnabled ? 'enabled' : 'disabled')).run(history, trackLeg);
      } catch (error) {
        // Same criterion as the library path: resend once without tools only when it is the first leg and
        // the upstream deterministically rejected `tools` before emitting any text.
        const eligible = toolsEnabled
          && activeLegIndex === 0
          && error instanceof ToolLoopError
          && error.source === 'provider'
          && !error.streamStarted
          && isDeterministicToolCallUnsupported(error.toolCallRejectionContext);
        if (!eligible) throw error;
        store.getState().setStreamingText(finalConvId, initialText);
        result = await new ToolCallLoop(loopOptions('disabled')).run(history, trackLeg);
        toolFallbackApplied = true;
      }
      latestUsage = result.usage;
      if (toolFallbackApplied && getActiveUIDSync() === sendingAccountId) {
        recordToolCallSupportFalse(toolCallIdentity);
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
      const delivered: ChatMessage = {
        ...assistantMessage,
        text: appendText(initialText, result.text),
        state: 'delivered',
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
      };
      completeRound(store, finalConvId, effectiveConversation, params.prevMessages, userMessage, delivered);
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
      });
    } catch (error) {
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
            ...toolStepsPatch(),
            ...partialCostPatch,
          });
        } else {
          patchAssistantMessage(store, finalConvId, assistantMessage.id, toolStepsPatch());
        }
        return;
      }
      const failure = describeFailure(error);
      const titleKey = failure.source === 'provider' ? 'requestFailed' : mapErrorKindKey(failure.kind);
      // A round whose tools already ran gets no retry affordance: resending would execute the tools twice.
      const additionalBodyRetry = additionalBodyRetryTap?.resolve({ sideEffects: session.steps().length > 0 });
      patchAssistantMessage(store, finalConvId, assistantMessage.id, {
        ...assistantMessage,
        text: partialText,
        state: 'failed',
        errorTitle: additionalBodyRetry?.eligible ? te('additionalBodyRejected.upstreamTitle') : te(`${titleKey}.title`),
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
      trackEvent('chat_message_failed', {
        provider_kind: telemetryProviderKind(params.provider.kind),
        model_id: telemetryModelID(params.provider.kind, params.model.id),
        // Report only the normalized short slug; the raw error body never goes into telemetry
        error_code: failure.kind,
        latency_ms: Date.now() - sendStartedAt,
        ...relaySendTelemetryProperties(params.provider),
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
