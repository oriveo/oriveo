import { useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { useAppStore, getVanillaStore } from '../../providers/StoreProvider';
import * as conversationOps from '../core/conversation-ops';

/**
 * Conversation actions: rename, delete (navigating to /chat when the current conversation is
 * deleted) and pin. Shared by ConversationList and FolderItem. Selection is deliberately not here:
 * the two callers differ, one routes directly and the other calls back through a prop.
 */
export function useConversationActions() {
  const router = useRouter();
  const t = useTranslations('sidebar');
  const activeId = useAppStore((s) => s.activeConversationId);
  const togglePinStore = useAppStore((s) => s.togglePinConversation);
  const togglePin = useCallback(
    (convId: string) => {
      togglePinStore(convId, Number.POSITIVE_INFINITY);
    },
    [togglePinStore],
  );

  const rename = useCallback((convId: string, newTitle: string) => {
    conversationOps.updateConversationTitle(getVanillaStore(), convId, newTitle);
  }, []);

  const remove = useCallback(
    (convId: string) => {
      const referenceCount = conversationOps.getConversationNoteReferenceCount(getVanillaStore(), convId);
      if (referenceCount > 0 && typeof window !== 'undefined') {
        const ok = window.confirm(t('deleteConversationReferencedByNotes', { count: referenceCount }));
        if (!ok) return;
      }
      conversationOps.deleteConversation(getVanillaStore(), convId);
      if (convId === activeId) router.push('/chat');
    },
    [activeId, router, t],
  );

  return { rename, remove, togglePin };
}
