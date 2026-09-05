'use client';

import { useState, useMemo, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import type { Conversation } from '@oriveo/shared';
import { useAppStore } from '../../providers/StoreProvider';
import { useMediaQuery } from '../../lib/hooks/useMediaQuery';
import { getVanillaStore } from '../../providers/StoreProvider';
import * as conversationOps from '../../lib/core/conversation-ops';
import { ConversationGroup } from './ConversationGroup';
import { FolderSection } from './FolderSection';
import { CreateFolderDialog } from './CreateFolderDialog';
import { ConfirmDialog } from '../dialogs/ConfirmDialog';
import { SyncStatusIndicator } from './SyncStatusIndicator';
import { ConflictCopyGroup } from '../conversations/ConflictCopyGroup';
import { SidebarToolbar } from './SidebarToolbar';
import { TimeGroupSection, EARLIER_PAGE_SIZE } from './TimeGroupSection';
import { groupConversations } from '../../lib/utils/conversation-grouping';
import {
  isVisibleConversation,
  partitionSidebarConversations,
} from '../../lib/utils/conversation-list';
import { warmConversationInStore } from '../../lib/core/chat/conversation-bootstrap';
import { useConversationActions } from '../../lib/hooks/useConversationActions';
import { useSidebarSearch } from '../../lib/hooks/useSidebarSearch';
import { useBatchEditMode } from '../../lib/hooks/useBatchEditMode';
import { usePinnedReorder } from '../../lib/hooks/usePinnedReorder';
import styles from './ConversationList.module.css';

export { EARLIER_PAGE_SIZE, resolveConversationGroupDisplay } from './TimeGroupSection';

interface ConversationListProps {
  variant?: 'sidebar' | 'mobileHome';
}

export function ConversationList({ variant = 'sidebar' }: ConversationListProps) {
  const router = useRouter();
  const t = useTranslations('sidebar');

  const conversations = useAppStore((s) => s.conversations);
  const activeId = useAppStore((s) => s.activeConversationId);
  const pinnedIds = useAppStore((s) => s.pinnedConversationIds);
  const setConversationOrder = useAppStore((s) => s.setConversationOrder);
  const folders = useAppStore((s) => s.folders);
  const isDesktop = useMediaQuery('(pointer: fine)');

  const [showCreateFolder, setShowCreateFolder] = useState(false);
  const [earlierDisplayCount, setEarlierDisplayCount] = useState(EARLIER_PAGE_SIZE);

  const sortedFolders = useMemo(
    () => [...folders].sort((a, b) => a.sortOrder - b.sortOrder),
    [folders],
  );

  const visibleConversations = useMemo(
    () => conversations.filter(isVisibleConversation),
    [conversations],
  );

  // Merge conflict copies: filtered out of the main list and broken out separately here, but not filtered out of search hits
  const conflictCopies = useMemo(
    () => conversations.filter((c) => c.isConflictCopy === true),
    [conversations],
  );

  const { searchQuery, setSearchQuery, filtered } = useSidebarSearch(
    conversations,
    visibleConversations,
  );

  const sidebarBuckets = useMemo(
    () => partitionSidebarConversations(filtered, pinnedIds),
    [filtered, pinnedIds],
  );
  const pinned = sidebarBuckets.pinned;
  const unpinned = sidebarBuckets.unpinned;
  const groups = useMemo(() => groupConversations(unpinned), [unpinned]);
  const allVisibleIds = useMemo(() => [...pinned, ...unpinned].map((c) => c.id), [pinned, unpinned]);

  const { rename: handleRename, remove: handleDelete, togglePin: handleTogglePin } = useConversationActions();

  const {
    editMode,
    selectedIds,
    showBatchConfirm,
    setShowBatchConfirm,
    handleToggleSelect,
    handleSelectAll,
    handleDeselectAll,
    handleBatchDelete,
    handleExitEditMode,
    setEditMode,
  } = useBatchEditMode(allVisibleIds, activeId, router);

  const { draggedId, handleDragStart, handleDragOver, handleDrop, reorderByKeyboard } = usePinnedReorder(
    pinnedIds,
    setConversationOrder,
  );

  const handleSelectConversation = useCallback((convId: string) => {
    void warmConversationInStore(convId);
    const query = searchQuery.trim();
    if (query) {
      router.push(`/chat/${convId}?q=${encodeURIComponent(query)}`);
      return;
    }
    router.push(`/chat/${convId}`);
  }, [router, searchQuery]);

  return (
    <div
      className={`${styles.wrapper} ${variant === 'mobileHome' ? styles.mobileHome : ''}`}
      data-variant={variant}
    >
      <SidebarToolbar
        editMode={editMode}
        selectedIds={selectedIds}
        allVisibleIds={allVisibleIds}
        searchQuery={searchQuery}
        onSearchChange={setSearchQuery}
        hasVisibleConversations={visibleConversations.length > 0}
        onSelectAll={handleSelectAll}
        onDeselectAll={handleDeselectAll}
        onShowBatchConfirm={() => setShowBatchConfirm(true)}
        onExitEditMode={handleExitEditMode}
        onShowCreateFolder={() => setShowCreateFolder(true)}
        onEnterEditMode={() => setEditMode(true)}
      />

      <ConfirmDialog
        open={showBatchConfirm}
        title={t('batchDeleteConfirm', { count: selectedIds.size })}
        confirmLabel={t('batchDelete')}
        cancelLabel={t('exitEditMode')}
        destructive
        onConfirm={handleBatchDelete}
        onCancel={() => setShowBatchConfirm(false)}
      />

      {pinned.length === 0 && groups.length === 0 && sortedFolders.length === 0 ? (
        <div className={styles.empty}>
          {searchQuery.trim() ? (
            <p className={styles.emptyText}>{t('noResults')}</p>
          ) : (
            <><p className={styles.emptyText}>{t('noConversations')}</p><p className={styles.emptyHint}>{t('startPrompt')}</p></>
          )}
        </div>
      ) : (
        <div className={styles.list}>
          {/* Folders (containers first, above pinned items) */}
          {sortedFolders.length > 0 && (
            <div className={styles.folderSection}>
              <FolderSection
                folders={sortedFolders}
                conversationsByFolder={sidebarBuckets.byFolder}
                onSelectConversation={handleSelectConversation}
                editMode={editMode}
                selectedIds={selectedIds}
                onToggleSelect={handleToggleSelect}
                variant={variant}
              />
            </div>
          )}

          {/* Pinned conversations */}
          {pinned.length > 0 && (
            <div>
              <div className={styles.groupLabel}>
                <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" aria-hidden style={{marginRight: 4}}>
                  <path d="M16 12V4h1V2H7v2h1v8l-2 2v2h5.2v6h1.6v-6H18v-2l-2-2z"/>
                </svg>
                {t('pinned')}
              </div>
              <div className={styles.groupedCard}>
                <ConversationGroup conversations={pinned} activeId={activeId} editMode={editMode}
                  selectedIds={selectedIds} isPinned={true} onSelect={handleSelectConversation}
                  onRename={handleRename} onDelete={handleDelete} onTogglePin={handleTogglePin}
                  onToggleSelect={handleToggleSelect} draggable={isDesktop && !editMode}
                  variant={variant}
                  onDragStart={handleDragStart} onDragOver={handleDragOver} onDrop={handleDrop} draggedId={draggedId}
                  onReorderPinned={reorderByKeyboard} />
              </div>
            </div>
          )}

          {/* Time groups */}
          {groups.map((group) => (
            <TimeGroupSection
              key={group.key}
              group={group}
              activeId={activeId}
              editMode={editMode}
              selectedIds={selectedIds}
              earlierDisplayCount={earlierDisplayCount}
              onSelect={handleSelectConversation}
              onRename={handleRename}
              onDelete={handleDelete}
              onTogglePin={handleTogglePin}
              onToggleSelect={handleToggleSelect}
              variant={variant}
              onShowMore={() => setEarlierDisplayCount((prev) => prev + EARLIER_PAGE_SIZE)}
            />
          ))}
        </div>
      )}

      {!searchQuery.trim() && conflictCopies.length > 0 ? (
        <ConflictCopyGroup
          conversations={conflictCopies}
          onOpen={(conversation) => handleSelectConversation(conversation.id)}
          onCopyAsNew={(conversation) => {
            const newId = conversationOps.cloneConversationFromConflictCopy(getVanillaStore(), conversation);
            router.push(`/chat/${newId}`);
          }}
          onCleanup={async () => {
            // TODO: the exportBeforeCleanup hook is a placeholder; filtering copies out of backup-export comes later
            conversationOps.cleanupConflictCopies(getVanillaStore());
          }}
        />
      ) : null}

      <SyncStatusIndicator />
      <CreateFolderDialog open={showCreateFolder} onClose={() => setShowCreateFolder(false)} />
    </div>
  );
}
