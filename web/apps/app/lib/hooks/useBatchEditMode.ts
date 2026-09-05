import { useState, useCallback } from 'react';
import type { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { getVanillaStore } from '../../providers/StoreProvider';
import * as conversationOps from '../core/conversation-ops';

/**
 * Sidebar batch edit mode: enter and leave, select, select all and invert, and batch delete
 * (deleting the current conversation navigates to /chat).
 */
export function useBatchEditMode(
  allVisibleIds: string[],
  activeId: string | null,
  router: ReturnType<typeof useRouter>,
) {
  const t = useTranslations('sidebar');
  const [editMode, setEditMode] = useState(false);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [showBatchConfirm, setShowBatchConfirm] = useState(false);

  const handleToggleSelect = useCallback((convId: string) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(convId)) next.delete(convId); else next.add(convId);
      return next;
    });
  }, []);

  const handleSelectAll = useCallback(() => setSelectedIds(new Set(allVisibleIds)), [allVisibleIds]);
  const handleDeselectAll = useCallback(() => setSelectedIds(new Set()), []);

  const handleBatchDelete = useCallback(() => {
    const ids = Array.from(selectedIds);
    const referenceCount = ids.reduce(
      (sum, id) => sum + conversationOps.getConversationNoteReferenceCount(getVanillaStore(), id),
      0,
    );
    if (referenceCount > 0 && typeof window !== 'undefined') {
      const ok = window.confirm(t('deleteConversationsReferencedByNotes', { count: referenceCount }));
      if (!ok) return;
    }
    conversationOps.deleteConversations(getVanillaStore(), ids);
    if (activeId && selectedIds.has(activeId)) router.push('/chat');
    setSelectedIds(new Set());
    setEditMode(false);
    setShowBatchConfirm(false);
  }, [selectedIds, activeId, router, t]);

  const handleExitEditMode = useCallback(() => {
    setEditMode(false); setSelectedIds(new Set()); setShowBatchConfirm(false);
  }, []);

  return {
    editMode,
    setEditMode,
    selectedIds,
    showBatchConfirm,
    setShowBatchConfirm,
    handleToggleSelect,
    handleSelectAll,
    handleDeselectAll,
    handleBatchDelete,
    handleExitEditMode,
  };
}
