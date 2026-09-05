import { useCallback } from "react";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import type {
  ChatMessage,
  Conversation,
  AIModel,
  Provider,
  Attachment,
  ReasoningMode,
  QuoteContext,
} from "@oriveo/shared";
import type { StoreApi } from "zustand";
import { getVanillaStore } from "../../providers/StoreProvider";
import type { ChatOpCtx } from "../core/chat/operations";
import { loadChatOperations } from "../core/chat/operations-lazy";
import { initMetadata } from "../core/metadata/metadata-client";
import { stopStream } from "../core/chat/stop-stream";
import type { AppStore } from "../core/store/app-store";
import { createProviderSelectionSnapshot } from "../core/providers/provider-selection-snapshot";
import { sameNormalizedID } from "../utils/id-utils";
import {
  abortAllStreams,
  endStream,
  flushAndInterruptStream,
  getStream,
  hasStream,
  registerStream,
  type StreamingSession,
} from "../core/chat/active-streams";
import { extractLibrarySourceMentions } from "../core/library/source-mentions";
import { isLibraryFeatureEnabled } from "../core/library/feature-flag";
import type { LibraryDocumentRef } from "../core/library/types";
import {
  batchAppendStreaming,
  flushPendingStreaming as flushPendingForConv,
} from "../core/chat/stream-batcher";
import { markNewConversationRoutePromotion } from "../core/chat/route-transition";
import { clearStreamPartialBackup } from "../core/store/stream-partial-backup";

interface UseStreamChatParams {
  provider: Provider | undefined;
  currentModel: AIModel | undefined;
  conversation: Conversation | undefined;
  messages: ChatMessage[];
  reasoningMode: ReasoningMode;
  webSearchEnabled?: boolean;
  libraryResearchEnabled?: boolean;
  generationParameterDraftSessionId?: string;
  onSendFailed: (text: string) => void;
  onLibraryContextFailed?: (documents: LibraryDocumentRef[]) => void;
}

/**
 * Sentinel msgId used while a send is being set up: the assistant message is only created inside
 * sendMessage, so there is no real id yet. It matches no message, which makes stop / lifecycle
 * flush / pagehide backups against this session safe no-ops.
 */
const RESERVED_MSG_ID = "__reserved__";

interface StreamReservation {
  /** Reservation timestamp, reused by registerStream on the real handle so elapsed_ms counts from the user's click. */
  startedAt: number;
  /** Whether stop() already fired an abort during the reservation window, when the real handle does not exist yet and only a flag can be recorded. */
  readonly aborted: boolean;
  /** Clears the reservation when the stream fails to start or is stopped early, otherwise the composer stays locked forever. */
  release: () => void;
}

/**
 * Reserve a stream synchronously: beginStreamingForConversation + setStreamingText +
 * registerStream must all complete within the same synchronous tick.
 *
 * Writing only to the store without registering the session leaves a window where streamingTexts
 * has the key but the sessions Map does not. During that window (the await on the dynamic import
 * of the chat operations) stop() is turned away by the hasStream guard and returns early, the
 * pagehide backup does not see the stream, and flushAndInterruptStream does nothing, so the stop
 * button appears dead to the user.
 */
function reserveStream(options: {
  conversationId: string;
  msgId: string;
  initialText?: string;
  initialReasoning?: string;
  isRecovery?: boolean;
}): StreamReservation {
  const {
    conversationId,
    msgId,
    initialText,
    initialReasoning,
    isRecovery,
  } = options;
  const store = getVanillaStore();
  const startedAt = Date.now();
  let aborted = false;

  const session: StreamingSession = {
    conversationId,
    msgId,
    abort: () => {
      aborted = true;
    },
    startedAt,
    ...(initialReasoning ? { initialReasoning } : {}),
    ...(isRecovery ? { isRecovery } : {}),
  };
  store.getState().beginStreamingForConversation(conversationId, msgId);
  if (initialText)
    store.getState().setStreamingText(conversationId, initialText);
  registerStream(session);

  return {
    startedAt,
    get aborted() {
      return aborted;
    },
    release: () => {
      // Only clear this reservation: if an overwriting send in the same conversation has taken over,
      // or the real handle already has, an indiscriminate endStream would clear someone else's live
      // stream too.
      if (getStream(conversationId) !== session) return;
      endStream(conversationId);
      store.getState().clearStreamingForConversation(conversationId);
    },
  };
}

function resolveLatestSendSelection(
  store: StoreApi<AppStore>,
  conversation: Conversation | undefined,
  fallbackProvider: Provider,
  fallbackModel: AIModel,
): {
  conversation: Conversation | undefined;
  provider: Provider;
  model: AIModel;
} {
  if (!conversation) {
    return { conversation, provider: fallbackProvider, model: fallbackModel };
  }

  const state = store.getState();
  const latestConversation =
    state.conversations.find((candidate) =>
      sameNormalizedID(candidate.id, conversation.id),
    ) ?? conversation;
  const latestProvider =
    state.providers.find((candidate) =>
      sameNormalizedID(candidate.id, latestConversation.providerID),
    ) ??
    (sameNormalizedID(fallbackProvider.id, latestConversation.providerID)
      ? fallbackProvider
      : undefined);
  const latestSnapshot = createProviderSelectionSnapshot(latestProvider, {
    requestedModelId: latestConversation.modelID,
  });

  if (!latestSnapshot?.currentModel) {
    return {
      conversation: latestConversation,
      provider: fallbackProvider,
      model: fallbackModel,
    };
  }

  return {
    conversation: latestConversation,
    provider: latestSnapshot.provider,
    model: latestSnapshot.currentModel,
  };
}

/**
 * Mark the partial of every active stream as interrupted and abort it.
 * Used only for sign-out and workspace switches, not as a guard on the new-message entry point.
 */
export function flushAndInterruptActiveStream(): void {
  abortAllStreams();
  // Clear every sessionStorage backup in one go.
  clearStreamPartialBackup();
}

/**
 * Core streaming chat hook, kept thin.
 * The business logic lives in core/chat/operations; this hook only handles:
 *   - the chunk to batcher to store wiring
 *   - the same-conversation guard on the send/retry/continue/edit entry points
 *   - stop (current conversation only)
 *
 * Note: lifecycle flush (visibilitychange / pagehide) lives in the module-level
 * lifecycle-listeners.ts and does not depend on the ChatView lifecycle; isStreaming /
 * streamingText are subscribed to by ChatView itself.
 */
export function useStreamChat({
  provider,
  currentModel,
  conversation,
  messages,
  reasoningMode,
  webSearchEnabled,
  libraryResearchEnabled,
  generationParameterDraftSessionId,
  onSendFailed,
  onLibraryContextFailed,
}: UseStreamChatParams) {
  const router = useRouter();
  const te = useTranslations("errors");
  const tLibrary = useTranslations("library");
  const libraryFeatureEnabled = isLibraryFeatureEnabled();

  // -- Interrupt only when the same conversation is being overwritten --
  const guardSameConversation = useCallback(
    (targetConvId: string | undefined) => {
      if (!targetConvId) return;
      if (hasStream(targetConvId)) {
        flushAndInterruptStream(targetConvId);
      }
    },
    [],
  );

  // ── Send ──
  const send = useCallback(
    async (
      text: string,
      prevMessages: ChatMessage[],
      conv: Conversation | undefined,
      msgAttachments?: Attachment[],
      pinnedNoteIds?: string[],
      libraryContextDocuments?: LibraryDocumentRef[],
      quoteContext?: QuoteContext,
    ) => {
      if (!text || !provider || !currentModel) return;
      // Interrupt only when the target conversation already has an unfinished stream (an overwrite
      // within the same conversation); sending in a different conversation does not abort it.
      guardSameConversation(conv?.id);

      // Reserve synchronously for an existing conversation to close the window where the store has
      // a stream but sessions does not during the dynamic import. A new conversation gets its
      // convId inside sendMessage, so it cannot be reserved and has to wait for the real handle.
      const reservation = conv?.id
        ? reserveStream({ conversationId: conv.id, msgId: RESERVED_MSG_ID })
        : undefined;
      try {
        const { sendMessage } = await loadChatOperations();
        if (reservation?.aborted) {
          // Stopped while still reserved: no stream ever started, so there is no message to mark interrupted and this can just wind down.
          reservation.release();
          return;
        }
        const store = getVanillaStore();
        const sendSelection = resolveLatestSendSelection(
          store,
          conv,
          provider,
          currentModel,
        );
        // For a new conversation the convId is generated inside sendMessage, so start with a
        // placeholder ctx and rebuild it with the real convId once the handle is available. The
        // onChunk closure must point at finalConvId, so wrap the batcher in a mutable closure.
        let resolvedConvId = conv?.id;
        const ctx: ChatOpCtx = {
          store,
          appendChunk: (chunk: string) => {
            if (!resolvedConvId) return;
            batchAppendStreaming(resolvedConvId, chunk);
          },
          te: (key: string) => te(key),
        };
        const effectiveLibraryContextDocuments = libraryFeatureEnabled
          ? libraryContextDocuments
          : undefined;
        const commonParams = {
          text,
          prevMessages,
          conversation: sendSelection.conversation,
          provider: sendSelection.provider,
          model: sendSelection.model,
          reasoningMode,
          attachments: msgAttachments,
          pinnedNoteIds,
          quoteContext,
          libraryContextDocuments: effectiveLibraryContextDocuments,
          libraryContextCancelledText: tLibrary("contextReadCancelled"),
          libraryFailurePresentation: libraryFailurePresentation(tLibrary),
          generationParameterDraftSessionId,
          onNewConversation: (convId: string) => {
            resolvedConvId = convId;
            markNewConversationRoutePromotion(convId);
            router.replace(`/chat/${convId}`);
          },
          onFailed: (failedText: string) => {
            onSendFailed(failedText);
            if (effectiveLibraryContextDocuments?.length) {
              onLibraryContextFailed?.(effectiveLibraryContextDocuments);
            }
          },
        };
        const usesLibraryResearch = libraryFeatureEnabled &&
          !effectiveLibraryContextDocuments?.length &&
          (libraryResearchEnabled || extractLibrarySourceMentions(text).length > 0);
        // Everything the library routing decision rests on (libraryAgentic / transport /
        // serverResearchEnabled) lives in the metadata snapshot. When it is absent, "not fetched
        // yet" reads as "the model does not support it" and silently falls back to plain chat, so
        // the user has retrieval switched on but gets an answer with no citations.
        // sendLibraryMessage has to return a SendHandle synchronously and cannot wait internally,
        // so readiness is ensured here. With a local cache initMetadata returns immediately and
        // the normal path waits for nothing.
        if (usesLibraryResearch) {
          await initMetadata();
        }
        const handle = usesLibraryResearch
          ? (
              await import("../core/chat/operations-library-send")
            ).sendLibraryMessage(ctx, {
              ...commonParams,
              ...libraryMessagePresentation(tLibrary),
            })
          : sendMessage(ctx, {
              ...commonParams,
              webSearchEnabled: effectiveLibraryContextDocuments?.length ? false : webSearchEnabled,
            });
        resolvedConvId = handle.convId;

        // The real handle replaces the reservation (registerStream already writes by conversationId).
        registerStream({
          conversationId: handle.convId,
          msgId: handle.msgId,
          abort: handle.abort,
          startedAt: reservation?.startedAt ?? Date.now(),
        });

        try {
          await handle.done;
        } finally {
          endStream(handle.convId);
          clearStreamPartialBackup(handle.convId);
        }
      } catch (err) {
        // The dynamic import or the transaction function threw on startup: the reserved stream state must be cleared or the composer stays locked forever.
        reservation?.release();
        throw err;
      }
    },
    [
      provider,
      currentModel,
      reasoningMode,
      webSearchEnabled,
      libraryResearchEnabled,
      libraryFeatureEnabled,
      generationParameterDraftSessionId,
      te,
      tLibrary,
      router,
      onSendFailed,
      onLibraryContextFailed,
      guardSameConversation,
    ],
  );

  // -- Stop (only the conversation currently shown in ChatView) --
  const stop = useCallback(() => {
    if (!conversation) return;
    const convId = conversation.id;
    if (!hasStream(convId)) return;
    flushPendingForConv(convId);
    const store = getVanillaStore();
    const partial = store.getState().streamingTexts[convId] ?? "";
    const session = getStream(convId);
    // Same handling as stopStream (metadata derive is preserved): abort, then mark the message interrupted.
    stopStream(store, conversation, messages, partial, session?.abort ?? null, {
      streamStartedAt: session?.startedAt ?? null,
      initialReasoning: session?.initialReasoning,
      // Locate the message bound to the session rather than assuming the last one is this stream's target (retry and continue can target a message in the middle).
      msgId: session?.msgId,
      isRecovery: session?.isRecovery,
    });
    endStream(convId);
    store.getState().clearStreamingForConversation(convId);
    clearStreamPartialBackup(convId);
  }, [conversation, messages]);

  // ── Retry ──
  const retry = useCallback(
    async (messageId: string, options?: {
      excludeCustomFragments?: boolean;
      excludeCustomFragmentOwners?: Array<'web' | 'reasoning' | 'generation'>;
      capabilityRecipeOmissions?: Array<{ recipeRef: string; locatedPointers: string[] }>;
      capabilityRecipeResendOwners?: Array<'web' | 'reasoning' | 'generation'>;
      excludeCapabilityOwners?: Array<'web' | 'reasoning' | 'generation'>;
    }) => {
      if (!conversation || !provider || !currentModel) return;
      guardSameConversation(conversation.id);
      const targetMsg = messages.find((message) => message.id === messageId);
      const libraryRecovery = isLibraryResearchMessage(targetMsg);
      let resolvedConvId: string | undefined = conversation.id;
      const ctx: ChatOpCtx = {
        store: getVanillaStore(),
        appendChunk: (chunk: string) => {
          if (!resolvedConvId) return;
          batchAppendStreaming(resolvedConvId, chunk);
        },
        te: (key: string) => te(key),
      };
      const commonParams = {
        messageId,
        conversation,
        messages,
        provider,
        model: currentModel,
        reasoningMode,
        webSearchEnabled,
        onNewConversation: (convId: string) => {
          resolvedConvId = convId;
          router.replace(`/chat/${convId}`);
        },
        onFailed: onSendFailed,
        libraryContextCancelledText: tLibrary("contextReadCancelled"),
        libraryFailurePresentation: libraryFailurePresentation(tLibrary),
      };
      const handle = libraryRecovery
        ? (
            await import("../core/chat/operations-library-send")
          ).retryLibraryMessage(ctx, {
            ...commonParams,
            ...libraryMessagePresentation(tLibrary),
          })
        : (await loadChatOperations()).retryMessage(ctx, {
          ...commonParams,
          ...(options?.excludeCustomFragments ? { excludeCustomFragments: true } : {}),
          ...(options?.excludeCustomFragmentOwners?.length ? { excludeCustomFragmentOwners: options.excludeCustomFragmentOwners } : {}),
          ...(options?.capabilityRecipeOmissions?.length ? { capabilityRecipeOmissions: options.capabilityRecipeOmissions } : {}),
          ...(options?.capabilityRecipeResendOwners?.length ? { capabilityRecipeResendOwners: options.capabilityRecipeResendOwners } : {}),
          ...(options?.excludeCapabilityOwners?.length ? { excludeCapabilityOwners: options.excludeCapabilityOwners } : {}),
        });
      if (!handle) return;
      resolvedConvId = handle.convId;

      registerStream({
        conversationId: handle.convId,
        msgId: handle.msgId,
        abort: handle.abort,
        startedAt: Date.now(),
      });
      void handle.done.finally(() => {
        endStream(handle.convId);
        clearStreamPartialBackup(handle.convId);
      });
    },
    [
      conversation,
      messages,
      provider,
      currentModel,
      reasoningMode,
      webSearchEnabled,
      te,
      tLibrary,
      router,
      onSendFailed,
      guardSameConversation,
    ],
  );

  // ── Continue Answering ──
  const continueAnswering = useCallback(
    async (messageId: string) => {
      if (!conversation || !provider || !currentModel) return;
      guardSameConversation(conversation.id);
      const targetMsg = messages.find((m) => m.id === messageId);
      const libraryRecovery = isLibraryResearchMessage(targetMsg);
      // Continue: capture the previous reasoning snapshot and pass it to the session, which uses it for idempotent concatenation during partial flush.
      const initialReasoning = targetMsg?.reasoningText;
      const reservation = reserveStream({
        conversationId: conversation.id,
        msgId: messageId,
        // The already-persisted text becomes the initial partial, so a stop during the reservation window writes back the full text instead of an empty string.
        ...(targetMsg?.text ? { initialText: targetMsg.text } : {}),
        isRecovery: true,
        ...(initialReasoning ? { initialReasoning } : {}),
      });

      try {
        const libraryOperations = libraryRecovery
          ? await import("../core/chat/operations-library-send")
          : undefined;
        const chatOperations = libraryRecovery
          ? undefined
          : await loadChatOperations();
        if (reservation.aborted) {
          // The user pressed stop during the reservation window: stop() already marked the message
          // interrupted and sent a cancel, and starting the stream now would flip it back to
          // generating, which looks like it cannot be stopped.
          reservation.release();
          return;
        }
        let resolvedConvId: string | undefined = conversation.id;
        const ctx: ChatOpCtx = {
          store: getVanillaStore(),
          appendChunk: (chunk: string) => {
            if (!resolvedConvId) return;
            batchAppendStreaming(resolvedConvId, chunk);
          },
          te: (key: string) => te(key),
        };
        const commonParams = {
          messageId,
          conversation,
          messages,
          provider,
          model: currentModel,
          reasoningMode,
          webSearchEnabled,
          libraryContextCancelledText: tLibrary("contextReadCancelled"),
          libraryFailurePresentation: libraryFailurePresentation(tLibrary),
        };
        const handle = libraryOperations
          ? libraryOperations.continueLibraryAnswering(ctx, {
              ...commonParams,
              ...libraryMessagePresentation(tLibrary),
            })
          : chatOperations!.continueAnswering(ctx, commonParams);
        resolvedConvId = handle.convId;

        // The real handle replaces the reservation.
        registerStream({
          conversationId: handle.convId,
          msgId: handle.msgId,
          abort: handle.abort,
          startedAt: reservation.startedAt,
          isRecovery: true,
          ...(initialReasoning ? { initialReasoning } : {}),
        });

        try {
          await handle.done;
        } finally {
          endStream(handle.convId);
          clearStreamPartialBackup(handle.convId);
        }
      } catch (err) {
        // The dynamic import or the transaction function threw on startup: the reserved stream state must be cleared or the composer stays locked forever.
        reservation.release();
        throw err;
      }
    },
    [
      conversation,
      messages,
      provider,
      currentModel,
      reasoningMode,
      webSearchEnabled,
      te,
      tLibrary,
      guardSameConversation,
    ],
  );

  // ── Edit and Resend ──
  const editAndResend = useCallback(
    async (messageId: string, newText: string) => {
      if (!conversation || !provider || !currentModel) return;
      guardSameConversation(conversation.id);
      const { editAndResend: editAndResendOp } = await loadChatOperations();
      let resolvedConvId: string | undefined = conversation.id;
      const ctx: ChatOpCtx = {
        store: getVanillaStore(),
        appendChunk: (chunk: string) => {
          if (!resolvedConvId) return;
          batchAppendStreaming(resolvedConvId, chunk);
        },
        te: (key: string) => te(key),
      };
      const handle = editAndResendOp(ctx, {
        messageId,
        newText,
        conversation,
        messages,
        provider,
        model: currentModel,
        reasoningMode,
        webSearchEnabled,
        libraryContextCancelledText: tLibrary("contextReadCancelled"),
        onNewConversation: (convId) => {
          resolvedConvId = convId;
          router.replace(`/chat/${convId}`);
        },
        onFailed: onSendFailed,
      });
      if (!handle) return;
      resolvedConvId = handle.convId;

      registerStream({
        conversationId: handle.convId,
        msgId: handle.msgId,
        abort: handle.abort,
        startedAt: Date.now(),
      });
      void handle.done.finally(() => {
        endStream(handle.convId);
        clearStreamPartialBackup(handle.convId);
      });
    },
    [
      conversation,
      messages,
      provider,
      currentModel,
      reasoningMode,
      webSearchEnabled,
      te,
      router,
      onSendFailed,
      guardSameConversation,
    ],
  );

  return { send, continueAnswering, retry, editAndResend, stop };
}

/**
 * Whether a recovery (retry or continue) should take the library research path. The only test is
 * the `libraryResearchEnabled` switch.
 *
 * A message carrying researchSteps used to count as research mode as well, which misclassified
 * messages where **the user named a document** and quietly rerouted the retry through the agent /
 * server retrieval path, so the previous turn's citations were treated as fresh evidence. All
 * three paths now show the step list; it is progress display, not a path marker.
 */
function isLibraryResearchMessage(message: ChatMessage | undefined): boolean {
  return Boolean(
    isLibraryFeatureEnabled() && message?.libraryResearchEnabled,
  );
}

/**
 * Localized copy for library_* failures, shared by all three paths: the agent path uses it in
 * operations-library-send, and the "named document" and "server-side retrieval" paths use it in
 * the generic catch in operations-send / operations-continue. Without it those two paths could
 * only show the raw English server text.
 */
function libraryFailurePresentation(translate: (key: string) => string) {
  return {
    errorTitle: translate("researchErrorTitle"),
    errorDetail: translate("genericError"),
    errorDetails: {
      library_needs_reauth: translate("error.needsReauth"),
      library_quota_exceeded: translate("error.quotaExceeded"),
      library_rate_limited: translate("error.rateLimited"),
      library_research_step_limit: translate("error.stepLimit"),
      library_not_connected: translate("error.notConnected"),
      library_unavailable: translate("error.unavailable"),
    },
    // messageKey to copy: only sourceForbidden exists so far, and an unknown messageKey falls back
    // to the code-based copy above.
    messageKeys: {
      "library.error.sourceForbidden": translate("error.sourceForbidden"),
    },
  };
}

function libraryMessagePresentation(
  translate: (key: string) => string,
) {
  return {
    cancelledText: translate("researchCancelled"),
    ...libraryFailurePresentation(translate),
  };
}
