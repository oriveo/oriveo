'use client';

import { memo, useCallback, useMemo } from 'react';
import { useTranslations, useLocale } from 'next-intl';
import type { Conversation } from '@oriveo/shared';
import { useAppStore } from '../../providers/StoreProvider';
import { ContextMenu } from '../ContextMenu';
import { MoveToFolderMenu } from './MoveToFolderMenu';
import { ProviderIcon } from '../ProviderIcon';
import { StreamingPulseDot } from './StreamingPulseDot';
import { formatRelativeTime } from '../../lib/utils/format-utils';
import { stripMarkdownForPreview } from '../../lib/utils/markdown-preview';
import { sameNormalizedID } from '../../lib/utils/id-utils';
import { useInlineRename } from '../../lib/hooks/useInlineRename';
import { useConversationContextMenu } from './useConversationContextMenu';
import type { PinnedReorderMove } from '../../lib/utils/pinned-reorder';
import {
  resolveConversationItemModelName,
  resolveConversationItemProviderKind,
} from '../../lib/utils/conversation-item-meta';
import styles from './ConversationItem.module.css';

export {
  resolveConversationItemModelName,
  resolveConversationItemProviderKind,
} from '../../lib/utils/conversation-item-meta';

interface ConversationItemProps {
  conversation: Conversation;
  active: boolean;
  onSelect: (id: string) => void;
  onRename: (id: string, newTitle: string) => void;
  onDelete: (id: string) => void;
  isPinned?: boolean;
  onTogglePin?: (id: string) => void;
  /** Position of this conversation in the pinned list plus the total, passed down only by the pinned group, for the keyboard reorder menu items */
  pinnedIndex?: number;
  pinnedCount?: number;
  onReorderPinned?: (id: string, move: PinnedReorderMove) => void;
  draggable?: boolean;
  onDragStart?: (e: React.DragEvent, id: string) => void;
  onDragOver?: (e: React.DragEvent) => void;
  onDrop?: (e: React.DragEvent, id: string) => void;
  isDragging?: boolean;
  editMode?: boolean;
  selected?: boolean;
  onToggleSelect?: (id: string) => void;
  /** Whether this conversation is streaming, passed down by ConversationGroup so each item does not select it separately */
  isStreaming?: boolean;
  variant?: 'sidebar' | 'mobileHome';
}

export const ConversationItem = memo(function ConversationItem({
  conversation,
  active,
  onSelect,
  onRename,
  onDelete,
  isPinned,
  onTogglePin,
  pinnedIndex,
  pinnedCount,
  onReorderPinned,
  draggable: draggableProp,
  onDragStart,
  onDragOver,
  onDrop,
  isDragging,
  editMode,
  selected,
  onToggleSelect,
  isStreaming = false,
  variant = 'sidebar',
}: ConversationItemProps) {
  const t = useTranslations('sidebar');
  const tChat = useTranslations('pages.chat');
  const locale = useLocale();
  const {
    editing,
    value: editTitle,
    setValue: setEditTitle,
    inputRef,
    start: handleStartRename,
    submit: handleSubmitRename,
    handleKeyDown: handleRenameKeyDown,
  } = useInlineRename({
    initialValue: conversation.title || '',
    onSubmit: (title) => onRename(conversation.id, title),
  });
  const {
    menu,
    closeMenu,
    showMoveMenu,
    moveMenuPos,
    setShowMoveMenu,
    handleRightClick,
    handleMoreClick,
  } = useConversationContextMenu({
    conversation,
    isPinned,
    onTogglePin,
    onDelete,
    onStartRename: handleStartRename,
    pinnedIndex,
    pinnedCount,
    onReorderPinned,
  });
  const previewText = stripMarkdownForPreview(conversation.previewText);
  const providers = useAppStore((s) => s.providers);
  const resolvedProvider = useMemo(
    () => providers.find((provider) => sameNormalizedID(provider.id, conversation.providerID)),
    [conversation.providerID, providers],
  );

  const catalogSkills = useAppStore((s) => s.catalogSkills);
  const userSkills = useAppStore((s) => s.userSkills);
  const skillIcon = useMemo(() => {
    if (!conversation.skillId) return null;
    const skill =
      (userSkills ?? []).find((s) => s.id === conversation.skillId) ??
      (catalogSkills ?? []).find((s) => s.id === conversation.skillId);
    return skill?.icon ?? null;
  }, [conversation.skillId, catalogSkills, userSkills]);

  const modelName = useMemo(() => {
    return resolveConversationItemModelName(conversation, resolvedProvider);
  }, [conversation, resolvedProvider]);

  const providerKind = useMemo(
    () => resolveConversationItemProviderKind(conversation),
    [conversation],
  );

  const timeStr = conversation.updatedAt ? formatRelativeTime(conversation.updatedAt, locale) : '';

  // Messages load lazily: a conversation that has not been warmed has no messages, so fall back to remoteMessageCount
  const messageCount = conversation.messages.length || conversation.remoteMessageCount || 0;

  const handleClick = useCallback(() => {
    if (editMode) {
      onToggleSelect?.(conversation.id);
    } else {
      onSelect(conversation.id);
    }
  }, [editMode, onToggleSelect, onSelect, conversation.id]);

  const handleDragStart = useMemo(
    () => draggableProp && onDragStart ? (e: React.DragEvent) => onDragStart(e, conversation.id) : undefined,
    [draggableProp, onDragStart, conversation.id],
  );

  const handleDrop = useMemo(
    () => draggableProp && onDrop ? (e: React.DragEvent) => onDrop(e, conversation.id) : undefined,
    [draggableProp, onDrop, conversation.id],
  );

  if (editing) {
    return (
      <div className={styles.item} data-active={active}>
        <input
          ref={inputRef}
          className={styles.editInput}
          value={editTitle}
          onChange={(e) => setEditTitle(e.target.value)}
          onKeyDown={handleRenameKeyDown}
          onBlur={handleSubmitRename}
        />
      </div>
    );
  }

  const title = conversation.title || t('untitled');
  return (
    <div className={styles.itemWrap}>
      <div
        role="button"
        tabIndex={0}
        className={`${styles.item} ${variant === 'mobileHome' ? styles.mobileHomeItem : ''} ${isDragging ? styles.dragging : ''}`}
        data-active={active}
        onClick={handleClick}
        onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); handleClick(); } }}
        onContextMenu={handleRightClick}
        draggable={draggableProp}
        onDragStart={handleDragStart}
        onDragOver={onDragOver}
        onDrop={handleDrop}
      >
        {/* Edit mode: selection checkbox */}
        {editMode && (
          <button
            type="button"
            role="checkbox"
            aria-checked={selected ?? false}
            className={styles.checkbox}
            data-checked={selected}
            onClick={(e) => { e.stopPropagation(); onToggleSelect?.(conversation.id); }}
            aria-label={selected ? t('deselectAll') : t('selectAll')}
          >
            {selected && (
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
                <polyline points="20 6 9 17 4 12" />
              </svg>
            )}
          </button>
        )}

        {providerKind && (
          <div className={styles.avatar}>
            <ProviderIcon
              kind={providerKind}
              relayKind={conversation.relayKind ?? resolvedProvider?.relayKind}
              size={22}
              bare
            />
          </div>
        )}

        <div className={styles.content}>
          {/* Title row: pin / skill icon / title / streaming dot */}
          <div className={styles.titleRow}>
            <span className={styles.titleText}>
              {isPinned && <svg className={styles.pinIcon} width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M16 12V4h1V2H7v2h1v8l-2 2v2h5.2v6h1.6v-6H18v-2l-2-2z"/></svg>}
              {skillIcon && <span className={styles.skillIcon}>{skillIcon}</span>}
              {title}
            </span>
            {isStreaming && <StreamingPulseDot ariaLabel={tChat('generating')} />}
          </div>

          {/* Two-line preview */}
          {previewText && (
            <div className={styles.previewLine}>{previewText}</div>
          )}

          {/* Bottom meta row: model name on the left, message count and time on the right */}
          {(modelName || timeStr || messageCount > 0) && (
            <div className={styles.metaRow}>
              {modelName && <span className={styles.metaModel}>{modelName}</span>}
              <span className={styles.metaTrailing}>
                {messageCount > 0 && (
                  <span className={styles.metaCount}>
                    <svg className={styles.metaCountIcon} width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                      <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                    </svg>
                    {messageCount}
                  </span>
                )}
                {timeStr && <span className={styles.metaTime}>{timeStr}</span>}
              </span>
            </div>
          )}
        </div>

        {!editMode && (
          <button
            type="button"
            className={styles.moreBtn}
            onClick={handleMoreClick}
            aria-label={t('more')}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
              <circle cx="12" cy="5" r="1.5" />
              <circle cx="12" cy="12" r="1.5" />
              <circle cx="12" cy="19" r="1.5" />
            </svg>
          </button>
        )}
      </div>

      {menu && (
        <ContextMenu items={menu.items} position={menu.position} onClose={closeMenu} />
      )}
      {showMoveMenu && (
        <MoveToFolderMenu
          position={moveMenuPos}
          convIds={[conversation.id]}
          currentFolderId={conversation.folderID}
          onClose={() => setShowMoveMenu(false)}
        />
      )}
    </div>
  );
});
