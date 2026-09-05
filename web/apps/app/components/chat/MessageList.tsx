'use client';

import { useEffect, useMemo, useRef, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import type { ChatMessage, Provider, QuoteContext } from '@oriveo/shared';
import { captureQuoteContext } from '@oriveo/shared';
import { normalizeUUID } from '../../lib/utils/id-utils';
import { usePinToTopScroll } from '../../lib/hooks/usePinToTopScroll';
import { useTextSelectionAnchor } from '../../lib/hooks/useTextSelectionAnchor';
import { useFocusMessage } from '../../lib/hooks/useFocusMessage';
import { getVanillaStore, useAppStore } from '../../providers/StoreProvider';
import { selectStreamingTextFor } from '../../lib/core/store/selectors';
import { createNote, replaceNote, type CreateNoteInput } from '../../lib/core/note-ops';
import { buildSelectionNoteInputFromSnapshot, normalizeSelectedText } from '../../lib/core/notes/capture';
import { extractSelectionMarkdown } from '../../lib/core/notes/selection-source';
import { copyToClipboard } from '../../lib/utils/clipboard';
import { showSavedNoteToast } from '../notes/note-toast';
import { showToast } from '../Toast';
import { MessageListItem } from './MessageListItem';
import type { SavedNoteRef } from './MessageBubble';
import { ChatOutlineRail, OUTLINE_MIN_USER_TURNS } from './ChatOutlineRail';
import { SelectionNoteToolbar } from './SelectionNoteToolbar';
import styles from './MessageList.module.css';

interface MessageListProps {
  messages: ChatMessage[];
  providers: Provider[];
  isStreaming: boolean;
  conversationId?: string | null;
  searchQuery?: string;
  focusMessageId?: string | null;
  replaceCurrentNoteId?: string | null;
  savedNoteRefsByMessageId?: Record<string, SavedNoteRef[]>;
  emptyState?: ReactNode;
  onRetry?: (messageId: string) => void;
  onRetryWithoutCustom?: (messageId: string) => void;
  onEditAndResend?: (messageId: string, newText: string) => void;
  onContinueAnswering?: (messageId: string) => void;
  onSwitchModel?: () => void;
  onAskSelection?: (quoteContext: QuoteContext) => void;
}

export function MessageList({
  messages,
  providers,
  isStreaming,
  conversationId,
  searchQuery,
  focusMessageId,
  replaceCurrentNoteId,
  savedNoteRefsByMessageId,
  emptyState,
  onRetry,
  onRetryWithoutCustom,
  onEditAndResend,
  onContinueAnswering,
  onSwitchModel,
  onAskSelection,
}: MessageListProps) {
  const router = useRouter();
  const t = useTranslations('pages.chat');
  const selectionAnchor = useTextSelectionAnchor();
  useFocusMessage(focusMessageId, { conversationId });

  // The streaming partial is subscribed here rather than passed down from ChatView: the writer is
  // the stream-batcher rAF, one store write per frame, and holding it in ChatView would re-render
  // the top bar, composer and model switcher every frame even though none of them consume it.
  // The value is identical either way, since selectStreamingTextFor returns '' for both null and
  // undefined.
  const streamingText = useAppStore(selectStreamingTextFor(conversationId ?? undefined));

  // The pinned anchor is the most recent user message; the trigger is the assistant message being generated at the tail
  const anchorMessageId = useMemo(() => {
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role === 'user') return messages[i].id;
    }
    return null;
  }, [messages]);
  const tail = messages[messages.length - 1];
  const streamingAssistantId =
    tail && tail.role === 'assistant' && tail.state === 'generating' ? tail.id : null;

  const { areaRef, spacerRef, showJumpToLatest, handleJumpToLatest } = usePinToTopScroll({
    conversationId,
    anchorMessageId,
    streamingAssistantId,
    streamingText,
    searchActive: Boolean(searchQuery?.trim()),
  });
  const handledSearchKeyRef = useRef<string | null>(null);

  const searchTargetMessageId = useMemo(() => {
    const query = searchQuery?.trim().toLowerCase();
    if (!query) return null;
    return messages.find((message) => message.text.toLowerCase().includes(query))?.id ?? null;
  }, [messages, searchQuery]);

  useEffect(() => {
    const query = searchQuery?.trim();
    if (!query) return;
    const searchKey = `${query}:${searchTargetMessageId ?? 'none'}`;
    if (handledSearchKeyRef.current === searchKey) return;
    handledSearchKeyRef.current = searchKey;

    const area = areaRef.current;
    if (!area) return;
    if (!searchTargetMessageId) {
      area.scrollTop = 0;
      return;
    }
    const target = Array.from(area.querySelectorAll<HTMLElement>('[data-message-id]'))
      .find((element) => element.dataset.messageId === searchTargetMessageId);
    target?.scrollIntoView({ block: 'start', behavior: 'auto' });
  }, [areaRef, searchQuery, searchTargetMessageId]);

  // Index providers by normalized ID so each message avoids an O(n) lookup and the sameNormalizedID fallback
  const providerMap = useMemo(() => {
    const map = new Map<string, Provider>();
    for (const p of providers) map.set(normalizeUUID(p.id), p);
    return map;
  }, [providers]);

  // The conversation object is subscribed once here and passed down to every bubble. With each
  // MessageBubble running `s.conversations.find(...)` itself, zustand runs every selector on every
  // store write, so streaming costs O(messages x conversations) per frame. The comparison stays an
  // exact id match with no UUID normalization, so ids differing only in case do not suddenly start
  // matching and change crosscheck visibility.
  const conversation = useAppStore((s) =>
    s.conversations.find((candidate) => candidate.id === conversationId),
  );

  const sourcePromptsByMessageId = useMemo(() => {
    const map = new Map<string, string>();
    for (let idx = 0; idx < messages.length; idx += 1) {
      const msg = messages[idx];
      if (msg.role !== 'assistant') continue;
      for (let i = idx - 1; i >= 0; i -= 1) {
        if (messages[i].role === 'user' && messages[i].text.trim()) {
          map.set(msg.id, messages[i].text);
          break;
        }
      }
    }
    return map;
  }, [messages]);

  const selectedMessage = selectionAnchor
    ? messages.find((candidate) => candidate.id === selectionAnchor.messageId)
    : undefined;
  const selectedMessageSavedNoteRefs = selectedMessage
    ? savedNoteRefsByMessageId?.[normalizeUUID(selectedMessage.id)] ?? savedNoteRefsByMessageId?.[selectedMessage.id] ?? []
    : [];
  const replaceTargetNoteId = replaceCurrentNoteId ?? selectedMessageSavedNoteRefs[0]?.id ?? null;
  const canReplaceSelection = Boolean(
    replaceTargetNoteId &&
    selectedMessage?.role === 'assistant' &&
    selectedMessage.state === 'delivered',
  );

  const buildSelectionInput = (): CreateNoteInput | null => {
    if (!selectionAnchor || !conversationId) return null;
    const message = selectedMessage;
    if (!message) return null;
    // A selection yields rendered plain text, with tables and code flattened. Try mapping it back to
    // the source markdown first and store the raw markdown when the block has structure, since the
    // body is rendered by MarkdownRenderer; otherwise fall back to plain text.
    const sourceMarkdown = extractSelectionMarkdown(message.text, selectionAnchor.text);
    const selectedText = sourceMarkdown ?? normalizeSelectedText(selectionAnchor.text);
    if (!selectedText) return null;
    const provider = message.providerID ? providerMap.get(normalizeUUID(message.providerID)) : undefined;
    return buildSelectionNoteInputFromSnapshot({
      conversationId,
      message,
      provider,
      selectedText,
      sourcePrompt: sourcePromptsByMessageId.get(message.id),
    });
  };

  const handleSaveSelection = () => {
    const input = buildSelectionInput();
    if (!input) return;
    const note = createNote(getVanillaStore(), input);
    window.getSelection()?.removeAllRanges();
    showSavedNoteToast({
      note,
      fallbackTitle: t('savedNoteUntitled'),
      viewLabel: t('viewNote'),
      onView: () => router.push(`/notes/${note.id}`),
    });
  };

  const handleCopySelection = () => {
    if (!selectionAnchor) return;
    const text = normalizeSelectedText(selectionAnchor.text);
    if (!text) return;
    void copyToClipboard(text, { successToast: t('copied'), failureToast: t('copyFailed') }).then((ok) => {
      if (ok) window.getSelection()?.removeAllRanges();
    });
  };

  const handleReplaceSelection = () => {
    if (!replaceTargetNoteId || !canReplaceSelection) return;
    const input = buildSelectionInput();
    if (!input) return;
    const note = replaceNote(getVanillaStore(), replaceTargetNoteId, input);
    if (!note) return;
    window.getSelection()?.removeAllRanges();
    showToast(t('noteReplaced'), 2500, undefined, 'success');
  };

  const handleAskSelection = () => {
    if (!selectionAnchor || !selectedMessage || !onAskSelection) return;
    const captured = captureQuoteContext({
      sourceMessageId: selectedMessage.id,
      sourceRole: selectedMessage.role,
      contentKind: selectionAnchor.contentKind,
      leadingText: selectionAnchor.contextReliable ? selectionAnchor.leadingText : '',
      selectedText: selectionAnchor.text,
      trailingText: selectionAnchor.contextReliable ? selectionAnchor.trailingText : '',
    });
    if (!captured.ok) {
      if (captured.error === 'selection_too_long') showToast(t('quoteSelectionTooLong'), 3000, undefined, 'warning');
      return;
    }
    onAskSelection(captured.quoteContext);
    window.getSelection()?.removeAllRanges();
  };

  if (messages.length === 0 && !isStreaming) {
    return <div className={`${styles.area} ${styles.areaEmpty}`}>{emptyState}</div>;
  }

  // Right-hand message navigation rail: shown only with more than 3 user turns and outside search mode
  const userTurnCount = messages.reduce((n, m) => (m.role === 'user' ? n + 1 : n), 0);
  const showOutline = userTurnCount > OUTLINE_MIN_USER_TURNS && !searchQuery?.trim();

  return (
    <div className={styles.areaWrap}>
    <div className={styles.area} ref={areaRef} role="log" aria-live="polite">
      <div className={styles.list}>
        {messages.map((msg, idx) => {
          // Only the message being generated gets streamingText, always live and never frozen; once pinned the user scrolls themselves and nothing follows the tail
          const msgStreamingText = msg.state === 'generating' ? streamingText : undefined;
          // Resolve the single provider for each message by direct lookup on the normalized key, with no O(n) fallback
          const msgProvider = msg.providerID ? providerMap.get(normalizeUUID(msg.providerID)) : undefined;
          // Reuse the memo above rather than repeating the same lookup inside the render loop
          const sourcePrompt = sourcePromptsByMessageId.get(msg.id);
          return (
            <MessageListItem
              key={msg.id}
              messageId={msg.id}
              message={msg}
              provider={msgProvider}
              streamingText={msgStreamingText}
              interactionLocked={isStreaming}
              prevRole={idx > 0 ? messages[idx - 1].role : undefined}
              onRetry={onRetry}
              onRetryWithoutCustom={onRetryWithoutCustom}
              onEditAndResend={onEditAndResend}
              onContinueAnswering={onContinueAnswering}
              onSwitchModel={onSwitchModel}
              conversationId={conversationId}
              conversation={conversation}
              sourcePrompt={sourcePrompt}
              savedNoteRefs={savedNoteRefsByMessageId?.[normalizeUUID(msg.id)] ?? savedNoteRefsByMessageId?.[msg.id]}
              isLastMessage={idx === messages.length - 1}
            />
          );
        })}
        {/* Pin-to-top bottom spacer: usePinToTopScroll writes the height, giving short answers room to scroll and collapsing to 0 for long ones */}
        <div ref={spacerRef} className={styles.spacer} aria-hidden="true" />
      </div>

    </div>
      {/* Jump to latest: a round icon in the bottom-right corner. The earlier text pill was sticky
          inside the list flow and centred, which made it hard to find.
          Shown once scrolled past the threshold; positioned absolute on the areaWrap layer so it
          stays out of the list flow. */}
      {showJumpToLatest && messages.length > 0 && (
        <button
          className={styles.jumpToBottomBtn}
          onClick={handleJumpToLatest}
          aria-label={t('newMessages')}
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <polyline points="6 9 12 15 18 9" />
          </svg>
        </button>
      )}
      {showOutline && (
        <ChatOutlineRail messages={messages} areaRef={areaRef} conversationId={conversationId} />
      )}
      {selectionAnchor && conversationId ? (
        <SelectionNoteToolbar
          anchor={selectionAnchor}
          onAsk={onAskSelection && selectedMessage && selectedMessage.state !== 'generating'
            ? handleAskSelection
            : undefined}
          onCopy={handleCopySelection}
          onSave={handleSaveSelection}
          onReplace={canReplaceSelection ? handleReplaceSelection : undefined}
        />
      ) : null}
    </div>
  );
}
