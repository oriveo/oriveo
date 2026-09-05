'use client';

import { useMemo, useCallback } from 'react';
import { useTranslations } from 'next-intl';
import type { Conversation, Folder } from '@oriveo/shared';
import { getFolderColorPair } from '@oriveo/shared';
import { useAppStore } from '../../providers/StoreProvider';
import { getVanillaStore } from '../../providers/StoreProvider';
import { ContextMenu } from '../ContextMenu';
import { ConversationGroup } from './ConversationGroup';
import * as folderOps from '../../lib/core/folder-ops';
import { warmConversationInStore } from '../../lib/core/chat/conversation-bootstrap';
import { sortConversationsByActivity } from '../../lib/utils/conversation-list';
import { useInlineRename } from '../../lib/hooks/useInlineRename';
import { useConversationActions } from '../../lib/hooks/useConversationActions';
import { useFolderActions } from './useFolderActions';
import { useFolderDragTarget } from './useFolderDragTarget';
import { FolderColorPicker } from './FolderColorPicker';
import { ConfirmDialog } from '../dialogs/ConfirmDialog';
import styles from './FolderItem.module.css';

interface FolderItemProps {
  folder: Folder;
  conversations: Conversation[];
  onSelectConversation: (id: string) => void;
  editMode: boolean;
  selectedIds: Set<string>;
  onToggleSelect: (id: string) => void;
  variant?: 'sidebar' | 'mobileHome';
}

export function FolderItem({
  folder,
  conversations,
  onSelectConversation,
  editMode,
  selectedIds,
  onToggleSelect,
  variant = 'sidebar',
}: FolderItemProps) {
  const expanded = useAppStore((s) => s.expandedFolderIds.includes(folder.id));
  const toggleExpand = useAppStore((s) => s.toggleFolderExpand);
  const activeId = useAppStore((s) => s.activeConversationId);
  const t = useTranslations('sidebar');

  const { rename: handleRename, remove: handleDeleteConv, togglePin: handleTogglePin } = useConversationActions();

  const {
    editing: renaming,
    value: renameName,
    setValue: setRenameName,
    inputRef: renameInputRef,
    start: startRename,
    submit: handleFinishRename,
    handleKeyDown: handleRenameKeyDown,
  } = useInlineRename({
    initialValue: folder.name,
    maxLength: 30,
    onSubmit: (name) => folderOps.renameFolder(getVanillaStore(), folder.id, name),
  });

  const { dragOver, handleDragOver, handleDragLeave, handleDrop } = useFolderDragTarget(conversations, folder);

  const {
    menu,
    closeMenu,
    onContextMenu,
    showDeleteConfirm,
    setShowDeleteConfirm,
    handleConfirmDelete,
    showColorPicker,
    setShowColorPicker,
    handleSelectColor,
    handleNewChat,
  } = useFolderActions({ folder, onStartRename: startRename });

  const [folderMain, folderDark] = getFolderColorPair(folder.colorTag);

  const sorted = useMemo(() => sortConversationsByActivity(conversations), [conversations]);

  const handleSelectConversation = useCallback((conversationId: string) => {
    void warmConversationInStore(conversationId);
    onSelectConversation(conversationId);
  }, [onSelectConversation]);

  return (
    <div>
      {/*   */}
      <button
        type="button"
        className={`${styles.folderHeader} ${variant === 'mobileHome' ? styles.mobileHomeFolderHeader : ''} ${dragOver ? styles.folderHeaderDragOver : ''}`}
        onClick={() => toggleExpand(folder.id)}
        onContextMenu={onContextMenu}
        onDragOver={handleDragOver}
        onDragLeave={handleDragLeave}
        onDrop={handleDrop}
        aria-expanded={expanded}
        role="button"
      >
        {/*   —   folder.colorTag   */}
        <span
          className={styles.folderIconWrap}
          style={{
            background: `linear-gradient(135deg, ${folderMain}, ${folderDark})`,
            boxShadow: `0 2px 6px ${folderMain}40`,
          }}
        >
          <svg viewBox="0 0 24 24" fill="currentColor" stroke="none">
            {expanded ? (
              <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2v11z" />
            ) : (
              <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
            )}
          </svg>
        </span>

        {/*   /   */}
        {renaming ? (
          <input
            ref={renameInputRef}
            className={styles.renameInput}
            value={renameName}
            onChange={(e) => setRenameName(e.target.value)}
            onBlur={handleFinishRename}
            onKeyDown={handleRenameKeyDown}
            onClick={(e) => e.stopPropagation()}
            maxLength={30}
          />
        ) : (
          <span className={styles.folderName}>{folder.name}</span>
        )}

        {conversations.length > 0 && (
          <span className={styles.folderCount}>{conversations.length}</span>
        )}

        {/* Chevron */}
        <svg className={`${styles.chevron} ${expanded ? styles.chevronExpanded : ''}`} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <polyline points="9 18 15 12 9 6" />
        </svg>
      </button>

      {/*   */}
      {menu && (
        <ContextMenu items={menu.items} position={menu.position} onClose={closeMenu} />
      )}

      {/*   */}
      {showColorPicker && (
        <div style={{ position: 'relative' }}>
          <FolderColorPicker
            currentColor={folder.colorTag}
            onSelect={handleSelectColor}
            onClose={() => setShowColorPicker(false)}
          />
        </div>
      )}

      {/*   */}
      <div className={`${styles.folderContent} ${expanded ? styles.folderContentExpanded : ''}`}>
        <div className={styles.folderContentInner}>
          {conversations.length === 0 ? (
            <div className={styles.emptyFolder}>
              <p>{t('emptyFolder')}</p>
              <button type="button" className={styles.newChatInFolder} onClick={handleNewChat}>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
                </svg>
                {t('newChatInFolder')}
              </button>
            </div>
          ) : (
            <>
              <div className={styles.folderGroupedCard}>
                <ConversationGroup
                  conversations={sorted}
                  activeId={activeId}
                  editMode={editMode}
                  selectedIds={selectedIds}
                  isPinned={false}
                  onSelect={(id) => editMode ? onToggleSelect(id) : handleSelectConversation(id)}
                  onRename={handleRename}
                  onDelete={handleDeleteConv}
                  onTogglePin={handleTogglePin}
                  onToggleSelect={onToggleSelect}
                  variant={variant}
                />
              </div>
              <button type="button" className={styles.newChatInFolder} onClick={handleNewChat}>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
                </svg>
                {t('newChatInFolder')}
              </button>
            </>
          )}
        </div>
      </div>

      {/*   */}
      <ConfirmDialog
        open={showDeleteConfirm}
        title={t('deleteFolder')}
        message={t('deleteFolderConfirm', { name: folder.name })}
        confirmLabel={t('deleteFolder')}
        cancelLabel={t('cancel')}
        destructive
        onConfirm={handleConfirmDelete}
        onCancel={() => setShowDeleteConfirm(false)}
      />
    </div>
  );
}
