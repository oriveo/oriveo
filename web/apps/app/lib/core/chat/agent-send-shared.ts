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
import { upsertMessages } from "./message-merge";
import {
  deriveConversationMetadata,
  computeConversationActivityAt,
} from "../conversation-metadata";
import { recalculateConversationCost } from "./usage-tracking";
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

export async function prepareAgentSubscriptionOutbound(
  store: ChatOpCtx["store"],
  provider: Provider,
  model: AIModel,
  streamOptions: StreamOptions | undefined,
): Promise<{ apiKey: string; streamOptions: StreamOptions | undefined }> {
  if (provider.authMode !== "subscription") {
    return { apiKey: provider.apiKey, streamOptions };
  }
  await ensureModelFacts();
  const reasoningLevels = subscriptionDeclaredReasoningLevels(provider.kind, model);
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
        grokSubscriptionAuth: true,
        grokSubscriptionWebSearchDeclared: model.capabilities.includes("web"),
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
        openAISubscriptionWebSearchDeclared: model.capabilities.includes("web"),
        ...(reasoningLevels.length ? { upstreamReasoningLevels: reasoningLevels } : {}),
      },
    };
  }
  return { apiKey: provider.apiKey, streamOptions };
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
  const cost = recalculateConversationCost(messages);
  store.getState().updateConversation(conversationID, {
    messages,
    ...deriveConversationMetadata(base, messages),
    estimatedCost: cost,
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
  store.getState().updateConversation(conversationID, {
    messages,
    ...deriveConversationMetadata(conversation, messages),
    estimatedCost: recalculateConversationCost(messages),
    updatedAt: computeConversationActivityAt(messages, conversation.createdAt),
  });
}
