/**
 * Outbound preparation and finalization shared by the two send paths that run a tool loop (the library
 * agent and remote MCP).
 *
 * Covers the outbound credentials of subscription connections, persisting a whole turn together with
 * its sync notification, and partial updates of the assistant message. It lives in its own module so
 * that operations-send.ts can delegate a send to the MCP path without the MCP and library send modules
 * importing each other.
 */
import type { AIModel, ChatMessage, Conversation, Provider, ProviderErrorSource } from "@oriveo/shared";
import type { StreamOptions } from "@oriveo/core/providers/types";
import { unbilledSkillRetrievalUsage } from "./prompt-injection";
import { resolveProviderAPIKey } from "@oriveo/core/providers/provider-credential";
import { upsertMessages } from "./message-merge";
import {
  deriveConversationMetadata,
  computeConversationActivityAt,
} from "../conversation-metadata";
import { recalculateConversationCostTotals } from "./usage-tracking";
import { getSyncAdapter } from "../sync-port";
import {
  ensureModelFacts,
  subscriptionDeclaredReasoningLevels,
} from "../metadata/metadata-client";
import { LibraryAgentError } from "./library-agent-loop";
import {
  grokSubscriptionErrorKindToProviderErrorKind,
  prepareGrokSubscriptionRequest,
  refreshMetadataOnClientVersionRejected,
} from "../providers/grok-subscription";
import {
  openAISubscriptionErrorKindToProviderErrorKind,
  prepareOpenAISubscriptionRequest,
  refreshMetadataOnCodexClientVersionRejected,
} from "../providers/openai-subscription";
import {
  persistGrokSubscriptionCredential,
  persistOpenAISubscriptionCredential,
} from "../provider-ops";
import type { ChatOpCtx } from "./operations";
import { resolveModelCapabilityEvidence } from "./capability-evidence";
import type { ProxyMessage } from "@oriveo/core/providers/request-builders/runtime";
import type { AssembleDynamic } from "@oriveo/core/context/assemble";
import { recallForTurn } from "../memory/memory-recall-runtime";
import { CONTEXT_BUDGET_CONSTANTS } from "@oriveo/core/context/budget";
import type { ToolRegistryEntry } from "@oriveo/core/tools/tool-loop-contracts";
import { createSearchMemoryEntry, createSearchMemoryTurn, planRecallIds, planRecallMax, type SearchMemoryTurn } from "./search-memory-runtime";
import { buildOutboundChatHistory } from "./outbound-history";
import {
  assembleChatPlan,
  chatPlanWindowOf,
  compactChatContextAssembly,
  latestValidChatCheckpoint,
  prepareChatContextAssembly,
  type ChatContextAssembly,
  type ChatPlanWindow,
} from "./context-pipeline/chat-context";
import {
  projectPlanMessages,
  transportInput,
  type PlannedChatRequest,
} from "./context-pipeline/transport-input";

export async function prepareAgentSubscriptionOutbound(
  store: ChatOpCtx["store"],
  provider: Provider,
  model: AIModel,
  streamOptions: StreamOptions | undefined,
): Promise<{ apiKey: string; streamOptions: StreamOptions | undefined }> {
  if (provider.authMode !== "subscription") {
    return { apiKey: resolveProviderAPIKey(provider, model.id), streamOptions };
  }
  await ensureModelFacts();
  const reasoningLevels = subscriptionDeclaredReasoningLevels(provider.kind, model);
  // Upstream declares web search for this model: go through the capability facade instead of reading the capability array in the consumer.
  const webSearchDeclared = resolveModelCapabilityEvidence({ key: "web_search", provider, model }).support === "supported";
  if (provider.kind === "grok") {
    const prepared = await prepareGrokSubscriptionRequest(provider);
    if (!prepared.ok) {
      refreshMetadataOnClientVersionRejected(prepared.error);
      throw new LibraryAgentError(
        "Grok subscription sign-in is unavailable right now.",
        grokSubscriptionErrorKindToProviderErrorKind(prepared.error),
        "oriveo",
      );
    }
    if (prepared.value.refreshed) {
      await persistGrokSubscriptionCredential(store, provider.id, prepared.value.refreshed);
    }
    return {
      apiKey: prepared.value.accessToken,
      streamOptions: {
        ...streamOptions,
        // Same as stream-runner: when no tier is selected, fill in automatic so the route sends the default tier declared upstream.
        reasoning: streamOptions?.reasoning ?? "automatic",
        grokSubscriptionAuth: true,
        grokSubscriptionWebSearchDeclared: webSearchDeclared,
        ...(model.upstreamDefaultReasoningLevel
          ? { upstreamDefaultReasoningLevel: model.upstreamDefaultReasoningLevel }
          : {}),
        ...(model.upstreamApiBackend ? { upstreamApiBackend: model.upstreamApiBackend } : {}),
        ...(reasoningLevels.length ? { upstreamReasoningLevels: reasoningLevels } : {}),
      },
    };
  }
  if (provider.kind === "openAI") {
    const prepared = await prepareOpenAISubscriptionRequest(provider);
    if (!prepared.ok) {
      refreshMetadataOnCodexClientVersionRejected(prepared.error);
      throw new LibraryAgentError(
        "ChatGPT subscription sign-in is unavailable right now.",
        openAISubscriptionErrorKindToProviderErrorKind(prepared.error),
        "oriveo",
      );
    }
    if (prepared.value.refreshed) {
      await persistOpenAISubscriptionCredential(store, provider.id, prepared.value.refreshed);
    }
    return {
      apiKey: prepared.value.accessToken,
      streamOptions: {
        ...streamOptions,
        openAISubscriptionAuth: true,
        openAISubscriptionAccountID: prepared.value.accountID,
        openAISubscriptionWebSearchDeclared: webSearchDeclared,
        ...(reasoningLevels.length ? { upstreamReasoningLevels: reasoningLevels } : {}),
      },
    };
  }
  return { apiKey: resolveProviderAPIKey(provider, model.id), streamOptions };
}

export function readProviderErrorSource(error: unknown): ProviderErrorSource | undefined {
  if (!error || typeof error !== "object") return undefined;
  const source = (error as { source?: unknown }).source;
  return source === "provider"
    || source === "network"
    || source === "oriveo"
    || source === "desktop"
    || source === "unknown"
    ? source
    : undefined;
}

export function appendText(existing: string, next: string): string {
  if (!existing) return next;
  if (!next) return existing;
  return `${existing}\n\n${next}`;
}

export function completeRound(
  store: ChatOpCtx["store"],
  conversationID: string,
  fallbackConversation: Conversation | undefined,
  fallbackMessages: ChatMessage[],
  userMessage: ChatMessage,
  assistantMessage: ChatMessage,
): void {
  const current = store
    .getState()
    .conversations.find((conversation) => conversation.id === conversationID);
  const base = current ?? fallbackConversation;
  if (!base) return;
  const currentUser =
    current?.messages.find((message) => message.id === userMessage.id) ??
    userMessage;
  const messages = upsertMessages(current?.messages ?? fallbackMessages, [
    currentUser,
    assistantMessage,
  ]);
  const costTotals = recalculateConversationCostTotals(messages, {
    conversation: base,
    previousMessages: current?.messages ?? fallbackMessages,
  });
  const cost = costTotals.estimatedCost;
  store.getState().updateConversation(conversationID, {
    messages,
    ...deriveConversationMetadata(base, messages),
    estimatedCost: cost,
    nonUsdCostTotals: costTotals.nonUsdCostTotals,
    updatedAt: computeConversationActivityAt(messages, base.createdAt),
  });
  const snapshot = store
    .getState()
    .conversations.find((conversation) => conversation.id === conversationID);
  getSyncAdapter()?.didCompleteRound(
    currentUser,
    assistantMessage,
    conversationID,
    snapshot,
    cost,
  );
}

export function patchAssistantMessage(
  store: ChatOpCtx["store"],
  conversationID: string,
  messageID: string,
  patch: Partial<ChatMessage>,
): void {
  const conversation = store
    .getState()
    .conversations.find((candidate) => candidate.id === conversationID);
  if (!conversation) return;
  const messages = conversation.messages.map((message) =>
    message.id === messageID ? { ...message, ...patch } : message,
  );
  const costTotals = recalculateConversationCostTotals(messages, {
    conversation,
    previousMessages: conversation.messages,
  });
  store.getState().updateConversation(conversationID, {
    messages,
    ...deriveConversationMetadata(conversation, messages),
    estimatedCost: costTotals.estimatedCost,
    nonUsdCostTotals: costTotals.nonUsdCostTotals,
    updatedAt: computeConversationActivityAt(messages, conversation.createdAt),
  });
}

/**
 * Outbound messages of the tool loop (MCP, library Agent): purpose toolLoopLeg makes the assembler produce the single system message (toolSafety at the end),
 * reused as is by every leg; the first-leg downgrade re-answer assembles one more request with purpose chat, with the evidence going into [D].
 */
export interface ToolLoopContext {
  readonly promptContext: ChatContextAssembly["promptContext"];
  /** The complete messages of the tool loop's first leg. */
  readonly history: ProxyMessage[];
  /** Assembles one request from the same context as chat (library first-leg downgrade re-answer); afterwards every leg's planned is replaced with this one. */
  chatRequest(dynamic: AssembleDynamic): Promise<ProxyMessage[]>;
  /** The projection every leg currently belongs to: each leg's runLeg calls transportInput with it (toolLeg form). */
  readonly planned: PlannedChatRequest;
  /** Ids of the memory items injected by the plan every leg currently belongs to, plus the ids search_memory handed to the model this turn; replaced by those of the re-answer after a first-leg downgrade. */
  readonly memoryIds: string[];
  /**
   * The search_memory registry entry (memory-search.v1 legRules 4): the only one this turn, excludeIds taken from the [D] recall of the current plan,
   * and results trimmed by the current plan's recallMax / rhoHi. Used only in tool mode.
   */
  searchMemoryEntry(): ToolRegistryEntry;
  /** The window input used by the first-leg plan (the pre-send confirmation gate decides by it). */
  readonly window: ChatPlanWindow;
  /** Budget basis for external search: the same context budget B as memory-recall scaling (window unknown = null) and this turn's ρ_hi. */
  readonly searchBudget: { B: number | null; rhoHi: number };
}

export async function prepareToolLoopContext(ctx: ChatOpCtx, input: {
  conversation: Conversation | undefined;
  conversationId: string;
  provider: Provider;
  model: AIModel;
  /** Outbound history (including this turn's user message, attachments already filtered by the current model's capabilities). */
  messages: ChatMessage[];
  keepAssistantId?: string;
  latestUserText: string;
  streamOptions?: StreamOptions;
  toolSafety: string;
  /**
   * Pre-search / resend reuse for external search: runs with the first plan's B and ρ and returns deliver.content,
   * placed verbatim in [D] right after <oriveo-library>; returning null places nothing.
   */
  webDynamic?: (budget: { B: number | null; rhoHi: number }) => Promise<string | null>;
}): Promise<ToolLoopContext> {
  const assembly = await prepareChatContextAssembly({
    store: ctx.store,
    conversation: input.conversation,
    conversationId: input.conversationId,
    provider: input.provider,
    model: input.model,
    messages: input.messages,
    ...(input.keepAssistantId ? { keepAssistantId: input.keepAssistantId } : {}),
    latestUserText: input.latestUserText,
    purpose: "toolLoopLeg",
  });
  // system and [D] are written into the messages only by transportInput.
  const wire = async (planned: PlannedChatRequest, toolLoop: boolean): Promise<ProxyMessage[]> => {
    const history = await buildOutboundChatHistory(ctx, {
      messages: planned.messages,
      provider: input.provider,
      model: input.model,
      streamOptions: input.streamOptions,
      toolLoop,
    });
    const transport = transportInput(planned, { options: input.streamOptions, history });
    return transport.messages as ProxyMessage[];
  };
  // L3 recall: every leg of the same turn and the first-leg downgrade re-answer reuse this one copy.
  const recall = recallForTurn({
    items: ctx.store.getState().memoryItems,
    useMemory: assembly.input.conversation.useMemory,
    query: input.latestUserText,
    conversationId: input.conversationId,
    folderId: input.conversation?.folderID ?? null,
  });
  const recallDynamic: AssembleDynamic = recall.length > 0 ? { recall } : {};
  const planOptions = { provider: input.provider, model: input.model };
  // When still over 0.90, take the deterministic fallback (same as the main send; only this request changes, nothing is persisted);
  // the tool loop does not use library rows as a prefix, and the fallback still carries the non-empty summary of the current checkpoint winner.
  const stored = await latestValidChatCheckpoint(input.conversationId, assembly);
  const oldSummary = stored?.summary?.trim() || null;
  const planWithFallback = (base: ChatContextAssembly, dynamic: AssembleDynamic) => {
    const options = { ...planOptions, dynamic };
    const plan = assembleChatPlan(base, options);
    const compacted = compactChatContextAssembly(base, plan, oldSummary);
    return compacted ? assembleChatPlan(compacted, options) : plan;
  };
  const toolAssembly = { ...assembly, input: { ...assembly.input, toolSafety: input.toolSafety } };
  let toolPlan = planWithFallback(toolAssembly, recallDynamic);
  const searchBudget = { B: toolPlan.budget.B ?? null, rhoHi: assembly.input.rhoHi ?? CONTEXT_BUDGET_CONSTANTS.rho0 };
  // A rejected plan is not searched (preflight failed, the request will not be sent).
  const web = input.webDynamic && !toolPlan.reject ? await input.webDynamic(searchBudget) : null;
  if (web) {
    recallDynamic.web = web;
    toolPlan = planWithFallback(toolAssembly, recallDynamic);
  }
  let currentPlan = toolPlan;
  let planned = projectPlanMessages(toolPlan, input.messages);
  const window = chatPlanWindowOf(assembly, planOptions);
  let searchTurn: SearchMemoryTurn | undefined;
  // The first-leg downgrade re-answer carries no tool results: ids returned by an earlier search do not count as used.
  let searchIdsDropped = 0;
  return {
    window,
    searchBudget,
    // A real send takes the retrieval usage: a retrieval that hit the cache or was already billed by a successful send is not counted again.
    promptContext: unbilledSkillRetrievalUsage(assembly.promptContext),
    history: await wire(planned, true),
    chatRequest: async (dynamic) => {
      currentPlan = planWithFallback({ ...assembly, input: { ...assembly.input, purpose: "chat" } }, { ...recallDynamic, ...dynamic });
      searchIdsDropped = searchTurn?.returnedIds.length ?? 0;
      planned = projectPlanMessages(currentPlan, input.messages);
      return wire(planned, false);
    },
    get planned() {
      return planned;
    },
    get memoryIds() {
      return [...new Set([...currentPlan.memoryIds, ...(searchTurn?.returnedIds.slice(searchIdsDropped) ?? [])])];
    },
    searchMemoryEntry() {
      searchTurn ??= createSearchMemoryTurn({
        store: ctx.store,
        conversationId: input.conversationId,
        folderId: input.conversation?.folderID ?? null,
        recallIds: () => planRecallIds(currentPlan, recall),
        recallMax: () => planRecallMax(currentPlan),
        rhoHi: () => assembly.input.rhoHi ?? CONTEXT_BUDGET_CONSTANTS.rho0,
      });
      return createSearchMemoryEntry(searchTurn);
    },
  };
}
