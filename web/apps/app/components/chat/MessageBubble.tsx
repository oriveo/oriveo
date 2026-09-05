"use client";

import { memo, useState, useCallback, useEffect, useMemo } from "react";
import { useRouter } from "next/navigation";
import { useTranslations } from "next-intl";
import type { ChatMessage, Attachment, Conversation, Provider } from "@oriveo/shared";
import { MarkdownRenderer } from "./MarkdownRenderer";
import { MessageActions } from "./MessageActions";
import { TypingIndicator } from "./TypingIndicator";
import { MessageRecoveryCard } from "./MessageRecoveryCard";
import {
  ContextMenu,
  useContextMenu,
  type ContextMenuItem,
} from "../ContextMenu";
import { ProviderIcon } from "../ProviderIcon";
import { loadFilePreviewUtils } from "../../lib/utils/file-preview-utils-lazy";
import { stripMarkdownForClipboard } from "../../lib/utils/markdown-preview";
import { copyToClipboard } from "../../lib/utils/clipboard";
import { useMessageEdit } from "../../lib/hooks/useMessageEdit";
import { UserAvatar } from "../common/UserAvatar";
import { useAppStore } from "../../providers/StoreProvider";
import { CitationsBlock } from "./CitationsBlock";
import { ResearchProgressBlock } from "./ResearchProgressBlock";
import { ReasoningBlock } from "./ReasoningBlock";
import { MessageMeta } from "./MessageMeta";
import { CrosscheckSheet } from "./CrosscheckSheet";
import {
  UserImageAttachments,
  UserFileChips,
  GeneratedImages,
} from "./MessageAttachments";
import {
  makeSelectStreamingReasoningText,
  makeSelectStreamingReasoningActive,
  makeSelectStreamingConvIdForMessage,
} from "../../lib/core/store/selectors";
import { createModelDisplayLookup } from "../../lib/core/providers/model-display-lookup";
import { getProviderInstanceDisplayName } from "../../lib/core/providers/provider-display";
import { isRateLimitError } from "../../lib/utils/error-classify";
import { getVanillaStore } from "../../providers/StoreProvider";
import { createNote } from "../../lib/core/note-ops";
import {
  buildMessageNoteInputFromSnapshot,
  buildSelectionNoteInputFromSnapshot,
} from "../../lib/core/notes/capture";
import { showToast } from "../Toast";
import { showSavedNoteToast } from "../notes/note-toast";
import { SavedNoteRefs } from "./SavedNoteRefs";


import { isLibraryFeatureEnabled } from "../../lib/core/library/feature-flag";
import { CUSTOM_FRAGMENT_ERROR_KIND } from "../../lib/core/chat/custom-fragment-rejection";
import { QuoteContextChip } from "./QuoteContextChip";
import { UnhandledToolCallCard } from "./UnhandledToolCallCard";
import styles from "./MessageBubble.module.css";

function hasActiveTextSelectionInside(element: HTMLElement): boolean {
  const selection = window.getSelection?.();
  if (
    !selection ||
    selection.rangeCount === 0 ||
    selection.isCollapsed ||
    !selection.toString().trim()
  ) {
    return false;
  }
  const containsNode = (node: Node | null) =>
    Boolean(node && (node === element || element.contains(node)));
  if (containsNode(selection.anchorNode) || containsNode(selection.focusNode)) {
    return true;
  }
  for (let i = 0; i < selection.rangeCount; i += 1) {
    if (containsNode(selection.getRangeAt(i).commonAncestorContainer))
      return true;
  }
  return false;
}

export interface SavedNoteRef {
  id: string;
  title: string;
}

interface MessageBubbleProps {
  message: ChatMessage;
  /** Resolved single provider (extracted by MessageList) instead of the whole providers array */
  provider?: Provider;
  streamingText?: string;
  interactionLocked?: boolean;
  sameSpeaker?: boolean;
  onRetry?: () => void;
  onRetryWithoutCustom?: () => void;
  onEditAndResend?: (newText: string) => void;
  onContinue?: () => void;
  onSwitchModel?: () => void;
  conversationId?: string;
  /**
   * Owning conversation, subscribed once by MessageList and passed down. Do **not** go back to a
   * per-bubble `useAppStore(s => s.conversations.find(...))`: zustand runs every selector on each store
   * write, which makes every streaming frame cost O(messages x conversations).
   */
  conversation?: Conversation;
  sourcePrompt?: string;
  savedNoteRefs?: SavedNoteRef[];
  /** Last message of the conversation: recovery cards (continue / retry) only render here, so middle messages cannot be continued or retried */
  isLastMessage?: boolean;
}

export const MessageBubble = memo(function MessageBubble({
  message,
  provider: resolvedProviderProp,
  streamingText,
  interactionLocked = false,
  sameSpeaker,
  onRetry,
  onRetryWithoutCustom,
  onEditAndResend,
  onContinue,
  onSwitchModel,
  conversationId,
  conversation,
  sourcePrompt,
  savedNoteRefs = [],
  isLastMessage = false,
}: MessageBubbleProps) {
  const router = useRouter();
  const isStreaming =
    message.state === "generating" && streamingText !== undefined;
  const displayText = isStreaming ? streamingText : message.text;
  const isFailed = message.state === "failed";
  const isInterrupted = message.state === "interrupted";
  const isWaitingForResponse = message.state === "generating" && !displayText;

  // While streaming, resolve the conversation id from message.id so MessageBubble can subscribe to
  // streamingReasoningText from the store itself, with no prop drilling.
  const streamingConvId = useAppStore(
    makeSelectStreamingConvIdForMessage(message.id, isStreaming),
  );
  const streamingReasoningText = useAppStore(
    makeSelectStreamingReasoningText(streamingConvId),
  );
  // Explicit "thinking has started" signal. During a long think the upstream only sends empty-string
  // heartbeats, so streamingReasoningText stays '' and a text-only check would render nothing for
  // minutes, leaving the user unable to tell thinking from a hang.
  const streamingReasoningActive = useAppStore(
    makeSelectStreamingReasoningActive(streamingConvId),
  );
  // The streaming partial only holds this round's chunks (prev is never injected), so continuations must
  // join message.reasoningText to keep the reasoning block from vanishing before the next chunk arrives.
  // On a first round message.reasoningText is empty and the result is identical.
  const effectiveReasoningText = isStreaming
    ? [message.reasoningText, streamingReasoningText]
        .filter(Boolean)
        .join("\n\n")
    : (message.reasoningText ?? "");

  const account = useAppStore((s) => s.account);
  const hasSeenNoteCaptureHint = useAppStore(
    (s) => s.preferences.hasSeenNoteCaptureHint === true,
  );
  const setPreferences = useAppStore((s) => s.setPreferences);
  const t = useTranslations("pages.chat");
  const tLibrary = useTranslations("library");
  const tCommon = useTranslations("common");
  const tCtx = useTranslations("contextMenu");
  const libraryFeatureEnabled = isLibraryFeatureEnabled();
  const {
    editing,
    editText,
    setEditText,
    handleStartEdit,
    handleCancelEdit,
    handleSubmitEdit,
    handleEditKeyDown,
  } = useMessageEdit(message.text, onEditAndResend);
  const {
    menu,
    handleContextMenu: onContextMenu,
    closeMenu,
  } = useContextMenu();

  const resolvedProvider = resolvedProviderProp;
  const modelDisplayLookup = useMemo(
    () => createModelDisplayLookup(resolvedProvider),
    [resolvedProvider],
  );
  const resolvedModel = useMemo(
    () => modelDisplayLookup.resolve(message.modelID),
    [modelDisplayLookup, message.modelID],
  );
  const resolvedProviderName = resolvedProvider
    ? getProviderInstanceDisplayName(resolvedProvider)
    : message.providerName;
  const resolvedProviderKind = resolvedProvider?.kind ?? message.providerKind;
  const resolvedModelName = resolvedModel?.displayName ?? message.modelName;
  const originModel = useMemo(() => {
    const modelId = message.modelID ?? resolvedModel?.modelId;
    const found = resolvedProvider?.models.find(
      (model) => model.id === modelId || model.canonicalModelId === modelId,
    );
    if (found) return found;
    if (!modelId) return undefined;
    return {
      id: modelId,
      name: resolvedModelName || modelId,
      capabilities: ["text"],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: false,
      priceTier: "",
    };
  }, [
    message.modelID,
    resolvedModel?.modelId,
    resolvedModelName,
    resolvedProvider?.models,
  ]);
  const showMeta =
    message.role === "assistant" &&
    message.state !== "generating" &&
    (resolvedModelName || resolvedProviderName);
  const showAssistantHeader = message.role === "assistant" && resolvedModelName;
  const managedNotice = useMemo(() => {
    if (message.role !== "assistant" || message.providerMode !== "managed")
      return null;
    if (message.managedPartialErrorMessage) {
      return {
        tone: "warning" as const,
        text: message.managedPartialErrorMessage,
      };
    }
    if (message.managedSettlementStatus === "pending") {
      return {
        tone: "info" as const,
        text: message.managedSettlementMessage || t("managedSettlementPending"),
      };
    }
    return null;
  }, [
    message.managedPartialErrorMessage,
    message.managedSettlementMessage,
    message.managedSettlementStatus,
    message.providerMode,
    message.role,
    t,
  ]);
  const [downloadingFileId, setDownloadingFileId] = useState<string | null>(
    null,
  );
  const [metaCopied, setMetaCopied] = useState(false);
  const [crosscheckOpen, setCrosscheckOpen] = useState(false);

  const handleMetaCopy = useCallback(async () => {
    if (!message.text) return;
    const ok = await copyToClipboard(message.text, {
      failureToast: tCtx("copyFailed"),
    });
    if (ok) {
      setMetaCopied(true);
      setTimeout(() => setMetaCopied(false), 2000);
    }
  }, [message.text, tCtx]);

  const handleFilePreview = useCallback((att: Attachment) => {
    loadFilePreviewUtils().then(({ previewFileAttachment }) =>
      previewFileAttachment(att, setDownloadingFileId, () =>
        setDownloadingFileId(null),
      ),
    );
  }, []);

  const handleManagedAcknowledgePrivacy = useCallback(async () => {
    onRetry?.();
  }, [onRetry]);

  const libraryRecoveryAction = useMemo(() => {
    if (!libraryFeatureEnabled) return null;
    // Never connected and connection expired share one retry action: for the user both mean the
    // document source has to be reconnected before the answer can be produced.
    if (
      message.errorKind === "library_needs_reauth" ||
      message.errorKind === "library_not_connected"
    ) {
      return {
        label: tLibrary("error.retry"),
        run: () => onRetry?.(),
      };
    }
    return null;
  }, [libraryFeatureEnabled, message.errorKind, onRetry, tLibrary]);

  const rateLimited = useMemo(
    () =>
      isRateLimitError(
        message.errorKind,
        message.errorTitle,
        message.errorDetail,
      ),
    [message.errorKind, message.errorTitle, message.errorDetail],
  );

  // Recovery card precondition: the title is translated at render time from errorKind, so besides older
  // rows that persisted errorTitle, messages carrying errorKind must produce a card too (otherwise the
  // whole card disappears once errorTitle stops being written).
  const hasFailureCopy = Boolean(message.errorTitle || message.errorKind);

  // Regenerate is disabled while a managed settlement is pending: the contract forbids a second request
  // for the same message during pending (a resend creates a new clientRequestId and a new hold, so a
  // pending request that later settles would double-charge).
  const deliveredRetryAction =
    interactionLocked || message.managedSettlementStatus === "pending"
      ? undefined
      : onRetry;
  const canSaveNote = Boolean(
    conversationId && message.text.trim() && message.state !== "generating",
  );
  const allProviders = useAppStore((s) => s.providers);
  const canCrosscheck = Boolean(
    conversation &&
    resolvedProvider &&
    originModel &&
    message.role === "assistant" &&
    message.state === "delivered" &&
    message.text.trim(),
  );

  useEffect(() => {
    if (!canSaveNote || message.role !== "assistant" || hasSeenNoteCaptureHint)
      return;
    showToast(t("noteCaptureHint"), 4000, undefined, "success");
    setPreferences({ hasSeenNoteCaptureHint: true });
  }, [canSaveNote, hasSeenNoteCaptureHint, message.role, setPreferences, t]);

  const handleSaveNote = useCallback(() => {
    if (!conversationId || !message.text.trim()) return;
    const note = createNote(
      getVanillaStore(),
      buildMessageNoteInputFromSnapshot({
        conversationId,
        message,
        provider: resolvedProvider,
        sourcePrompt,
      }),
    );
    showSavedNoteToast({
      note,
      fallbackTitle: t("savedNoteUntitled"),
      viewLabel: t("viewNote"),
      onView: () => router.push(`/notes/${note.id}`),
    });
  }, [conversationId, message, resolvedProvider, router, sourcePrompt, t]);

  const handleSaveCodeBlock = useCallback(
    (markdown: string) => {
      if (!conversationId || !markdown.trim()) return;
      const note = createNote(
        getVanillaStore(),
        buildSelectionNoteInputFromSnapshot({
          conversationId,
          message,
          provider: resolvedProvider,
          selectedText: markdown,
          sourcePrompt,
        }),
      );
      showSavedNoteToast({
        note,
        fallbackTitle: t("savedNoteUntitled"),
        viewLabel: t("viewNote"),
        onView: () => router.push(`/notes/${note.id}`),
      });
    },
    [conversationId, message, resolvedProvider, router, sourcePrompt, t],
  );

  const contextMenuItems = useMemo<ContextMenuItem[]>(() => {
    if (message.role === "user") {
      const items: ContextMenuItem[] = [];
      items.push({
        label: tCtx("copy"),
        onAction: () =>
          copyToClipboard(message.text, {
            successToast: tCtx("copied"),
            failureToast: tCtx("copyFailed"),
          }),
      });
      if (conversationId)
        items.push({
          label: tCtx("saveAsNote"),
          onAction: () => handleSaveNote(),
        });
      if (onEditAndResend)
        items.push({ label: tCtx("editAndResend"), onAction: handleStartEdit });
      return items;
    }
    const items: ContextMenuItem[] = [
      ...(conversationId
        ? [{ label: tCtx("saveAsNote"), onAction: () => handleSaveNote() }]
        : []),
      {
        label: tCtx("copy"),
        onAction: () =>
          copyToClipboard(stripMarkdownForClipboard(message.text), {
            successToast: tCtx("copied"),
            failureToast: tCtx("copyFailed"),
          }),
      },
      {
        label: tCtx("copyMarkdown"),
        onAction: () =>
          copyToClipboard(message.text, {
            successToast: tCtx("copied"),
            failureToast: tCtx("copyFailed"),
          }),
      },
    ];
    if (deliveredRetryAction)
      items.push({ label: tCtx("regenerate"), onAction: deliveredRetryAction });
    return items;
  }, [
    message,
    tCtx,
    onEditAndResend,
    deliveredRetryAction,
    handleStartEdit,
    conversationId,
    handleSaveNote,
  ]);

  const handleRightClick = useCallback(
    (e: React.MouseEvent<HTMLElement>) => {
      if (!displayText) return;
      if (hasActiveTextSelectionInside(e.currentTarget)) {
        e.preventDefault();
        closeMenu();
        return;
      }
      onContextMenu(e, contextMenuItems);
    },
    [closeMenu, onContextMenu, contextMenuItems, displayText],
  );

  return (
    <div
      className={`${styles.row} ${isFailed ? styles.failed : ""} ${isInterrupted ? styles.interrupted : ""}`}
      data-role={message.role}
      data-same-speaker={sameSpeaker ? "true" : undefined}
      role="article"
      onContextMenu={handleRightClick}
    >
      {message.role === "assistant" ? (
        <div className={styles.avatar} aria-hidden="true">
          <ProviderIcon
            kind={resolvedProviderKind}
            size={28}
            bare
            relayKind={resolvedProvider?.relayKind}
          />
        </div>
      ) : (
        <UserAvatar
          size={36}
          avatarURL={account?.avatarURL}
          fallbackName={account?.name || account?.email || ""}
          className={styles.avatarUser}
        />
      )}

      <div className={styles.container}>
        {editing ? (
          <div className={styles.editWrap}>
            <textarea
              className={styles.editTextarea}
              value={editText}
              onChange={(e) => setEditText(e.target.value)}
              onKeyDown={handleEditKeyDown}
              autoFocus
              rows={3}
            />
            <div className={styles.editActions}>
              <button
                type="button"
                className={styles.editCancel}
                onClick={handleCancelEdit}
              >
                {tCommon("cancel")}
              </button>
              <button
                type="button"
                className={styles.editSubmit}
                onClick={handleSubmitEdit}
                disabled={!editText.trim() || editText.trim() === message.text}
              >
                {tCommon("confirm")}
              </button>
            </div>
          </div>
        ) : (
          <>
            {message.role === "user" && message.attachments && (
              <UserImageAttachments attachments={message.attachments} />
            )}
            {showAssistantHeader && (
              <div className={styles.assistantHeader}>
                <span className={styles.assistantModelName}>
                  {resolvedModelName}
                </span>
              </div>
            )}
            {message.role === "assistant" &&
              (effectiveReasoningText.trim() !== "" || streamingReasoningActive) && (
              <ReasoningBlock
                reasoningText={effectiveReasoningText}
                isStreaming={isStreaming}
                durationMs={message.reasoningDurationMs}
                messageId={message.id}
              />
            )}
            {message.role === "assistant" &&
              libraryFeatureEnabled &&
              message.researchSteps &&
              message.researchSteps.length > 0 && (
                <ResearchProgressBlock
                  steps={message.researchSteps}
                  isStreaming={isStreaming}
                />
              )}
            <div className={styles.bubble}>
              {message.role === "user" && message.quoteContext ? (
                <QuoteContextChip quoteContext={message.quoteContext} presentation="sent" />
              ) : null}
              {message.role === "user" && message.attachments && (
                <UserFileChips
                  attachments={message.attachments}
                  downloadingFileId={downloadingFileId}
                  onPreview={handleFilePreview}
                />
              )}
              {isWaitingForResponse ? (
                <TypingIndicator />
              ) : message.role === "assistant" && displayText ? (
                <MarkdownRenderer
                  content={displayText}
                  isStreaming={isStreaming}
                  onSaveCodeBlock={
                    !isStreaming && conversationId
                      ? handleSaveCodeBlock
                      : undefined
                  }
                />
              ) : (
                <span data-quote-block="prose">{displayText}</span>
              )}
              {message.role === "assistant" && (message.unhandledToolCalls?.length || message.toolFallbackNotice) ? (
                <UnhandledToolCallCard
                  calls={message.unhandledToolCalls}
                  notice={message.toolFallbackNotice}
                />
              ) : null}
            </div>
            {message.role === "assistant" && message.attachments && (
              <GeneratedImages attachments={message.attachments} />
            )}
            {/*
               Not rendered while generating with no body text yet: the specified-documents path writes
               the document identity into message.citations before the request goes out, so without this
               guard the sources read as fully listed while the body is still blank.
               The data itself is kept, since retry and message editing resolve documents back from citations. */}
            {message.role === "assistant" &&
              libraryFeatureEnabled &&
              message.citations &&
              message.citations.length > 0 &&
              (!isStreaming || message.text.length > 0) && (
                <CitationsBlock
                  citations={message.citations}
                  isStreaming={isStreaming}
                />
              )}
            {message.role === "assistant" &&
              libraryFeatureEnabled &&
              message.researchSteps &&
              message.researchSteps.length > 0 &&
              !isStreaming && (
                <p className={styles.researchDisclaimer}>
                  {tLibrary("disclaimer")}
                </p>
              )}
            {managedNotice && (
              <div
                className={styles.managedNotice}
                data-tone={managedNotice.tone}
              >
                {managedNotice.text}
              </div>
            )}
            {/* errorKind also counts as failure copy: the title is translated at render time from kind rather than read from a persisted errorTitle */}
            {isFailed && hasFailureCopy && isLastMessage && (
              <div className={styles.inlineError}>
                <MessageRecoveryCard
                  state="failed"
                  errorTitle={message.errorTitle}
                  errorDetail={message.errorDetail}
                  errorKind={message.errorKind}
                  errorSource={message.errorSource}
                  // Transport failures persist raw technical text into errorDetail: a dropped
                  // connection gives `Failed to fetch`. The body is localized by kind and the
                  // original text stays under technical details. Custom request field rejections are
                  // the exception: what they persist is already a localized sentence chosen by
                  // rejection reason.
                  detailIsInternalTechnicalText={
                    (message.errorSource === "oriveo" ||
                      message.errorSource === "network") &&
                    message.errorKind !== CUSTOM_FRAGMENT_ERROR_KIND
                  }
                  onRetry={onRetry}
                  onEdit={onEditAndResend ? handleStartEdit : undefined}
                  onSwitchModel={rateLimited ? onSwitchModel : undefined}
                  // Way out of a custom request field fail-closed: a plain retry gets rejected the same way,
                  // so the only action that can send the message right now is "send without custom fields".
                  primaryActionLabel={message.errorKind === CUSTOM_FRAGMENT_ERROR_KIND
                    ? tCommon('retryWithoutCustomRequestFields')
                    : message.capabilityRecovery?.action === 'user_confirmed_resend_without_located_setting'
                      ? tCommon('resendWithoutSetting') : libraryRecoveryAction?.label}
                  onPrimaryAction={message.errorKind === CUSTOM_FRAGMENT_ERROR_KIND
                    || message.capabilityRecovery?.action === 'user_confirmed_resend_without_located_setting'
                    ? onRetryWithoutCustom : libraryRecoveryAction?.run}
                  disabled={interactionLocked}
                />
              </div>
            )}
            {isInterrupted && message.role === "assistant" && isLastMessage && (
              <div className={styles.inlineError}>
                <MessageRecoveryCard
                  state="interrupted"
                  onContinue={onContinue}
                  onRetry={deliveredRetryAction}
                  disabled={interactionLocked}
                />
              </div>
            )}
            {!isStreaming &&
              displayText &&
              !isFailed &&
              !isInterrupted &&
              message.role === "user" && (
                <MessageActions
                  role={message.role}
                  text={message.text}
                  onEdit={handleStartEdit}
                  onSaveNote={handleSaveNote}
                />
              )}
            {showMeta && (
              <MessageMeta
                providerName={resolvedProviderName}
                modelName={resolvedModelName}
                estimatedCost={message.estimatedCost}
                copied={metaCopied}
                onCopy={handleMetaCopy}
                onRetry={deliveredRetryAction}
                onSaveNote={canSaveNote ? handleSaveNote : undefined}
                onCrosscheck={
                  canCrosscheck ? () => setCrosscheckOpen(true) : undefined
                }
                tokenUsage={{
                  inputTokens: message.inputTokens,
                  outputTokens: message.outputTokens,
                  cachedInputTokens: message.cachedInputTokens,
                  cacheCreationInputTokens: message.cacheCreationInputTokens,
                }}
                capabilityResults={message.capabilityResults}
              />
            )}
            <SavedNoteRefs
              refs={savedNoteRefs}
              onOpen={(id) => router.push(`/notes/${id}`)}
            />
          </>
        )}
      </div>

      {menu && (
        <ContextMenu
          items={menu.items}
          position={menu.position}
          onClose={closeMenu}
        />
      )}
      {canCrosscheck && conversation && resolvedProvider && originModel ? (
        <CrosscheckSheet
          open={crosscheckOpen}
          conversation={conversation}
          originMessage={message}
          originalPrompt={sourcePrompt ?? ""}
          originalAnswer={message.text}
          originProvider={resolvedProvider}
          originModel={originModel}
          providers={allProviders}
          onClose={() => setCrosscheckOpen(false)}
        />
      ) : null}
    </div>
  );
});
