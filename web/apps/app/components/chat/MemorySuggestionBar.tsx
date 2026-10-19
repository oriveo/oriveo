'use client';

import { useEffect, useState, useSyncExternalStore } from 'react';
import { useTranslations } from 'next-intl';
import type { MemoryCandidateRecord } from '@oriveo/core/context/memory-intent';
import { getVanillaStore } from '../../providers/StoreProvider';
import { getActiveUIDSync } from '../../lib/infra/storage/partition';
import { reportSilentError } from '../../lib/sentry/report-silent';
import {
  createMemoryItemRepository,
  type MemoryItemRepository,
} from '../../lib/core/memory/memory-item-repository';
import { createMemoryCandidateRepository } from '../../lib/core/memory/memory-candidate-repository';
import {
  MemoryItemEditor,
  categoryOfKind,
  kindForCategory,
  type MemoryCategory,
  type MemoryEditorSession,
} from '../../app/settings/memory/MemoryItemEditor';
import {
  clearMemorySuggestion,
  clearMemorySuggestionOutside,
  getPendingMemorySuggestion,
  subscribeMemorySuggestion,
  type MemorySuggestion,
} from '../../lib/core/chat/conversation-instructions/memory-suggestion';
import { showToast } from '../Toast';
import styles from './MemorySuggestionBar.module.css';

const serverSuggestion = (): MemorySuggestion | null => null;

/**
 * P6·U3: the pending "save to memory?" suggestion for this conversation, or null.
 * Switching away drops it (and any in-flight generate result) without counting as an ignore.
 */
export function useMemorySuggestion(conversationId: string | null | undefined): MemorySuggestion | null {
  const suggestion = useSyncExternalStore(subscribeMemorySuggestion, getPendingMemorySuggestion, serverSuggestion);
  useEffect(() => {
    clearMemorySuggestionOutside(conversationId);
  }, [conversationId]);
  if (!suggestion || !conversationId || suggestion.conversationId !== conversationId) return null;
  return suggestion;
}

// Repositories are built per write: the active partition may have changed (same as MemoryPage runWrite).
async function memoryRepositories() {
  // Lazy import: bootstrap pulls in the chat modules, a static import would form a cycle.
  const { getOrCreateStableWebDeviceId } = await import('../../lib/core/bootstrap');
  const uid = getActiveUIDSync();
  const items = createMemoryItemRepository({ store: getVanillaStore(), uid, deviceId: getOrCreateStableWebDeviceId() });
  return { items, candidates: createMemoryCandidateRepository({ uid, items }) };
}

/** Undo of a save: remove the just-created item through the normal item delete path. */
function undoSave(items: MemoryItemRepository, itemId: string): void {
  items.remove(itemId).catch((error: unknown) => reportSilentError('memory-suggestion.undo', error));
}

/** P6·U3 bar rendered under the user message that produced a memory candidate (or the memory-off hint). */
export function MemorySuggestionBar({ suggestion }: { suggestion: MemorySuggestion }) {
  const t = useTranslations('pages.chat.memorySuggestion');
  const tCommon = useTranslations('common');
  const [editor, setEditor] = useState<MemoryEditorSession | null>(null);

  // Contract items 4 and 5: the bar goes away first, then accept; a failure only shows the failed toast.
  const accept = (candidate: MemoryCandidateRecord, edit?: { content: string; kind?: MemoryCandidateRecord['proposedKind'] }) => {
    clearMemorySuggestion();
    void (async () => {
      const { items, candidates } = await memoryRepositories();
      const outcome = await candidates.accept(candidate.id, edit ?? null);
      if ('error' in outcome) throw new Error(`memory candidate accept failed: ${outcome.error}`);
      const itemId = outcome.item.id;
      showToast(t('saved'), 5000, () => undoSave(items, itemId), 'warning', tCommon('undo'));
    })().catch((error: unknown) => {
      reportSilentError('memory-suggestion.accept', error);
      showToast(t('failed'), 3000, undefined, 'error');
    });
  };

  // Contract item 6: reject, the bar goes away; a failure is silent.
  const ignore = (candidate: MemoryCandidateRecord) => {
    clearMemorySuggestion();
    void (async () => {
      const { candidates } = await memoryRepositories();
      await candidates.reject(candidate.id);
    })().catch((error: unknown) => reportSilentError('memory-suggestion.reject', error));
  };

  if (suggestion.status === 'memoryOff') {
    return (
      <div className={styles.bar} role="status" data-testid="memory-suggestion-bar">
        <span className={styles.text}>{t('memoryOff')}</span>
      </div>
    );
  }

  const { candidate } = suggestion;
  const proposedCategory: MemoryCategory = categoryOfKind(candidate.proposedKind) ?? 'about';

  // Edited save: content always, kind only when the category was changed; scope is kept.
  const handleEditorSave = (category: MemoryCategory, content: string) => {
    accept(candidate, {
      content,
      ...(category !== proposedCategory ? { kind: kindForCategory(category) } : {}),
    });
  };

  return (
    <div className={styles.bar} role="status" data-testid="memory-suggestion-bar">
      <div className={styles.body}>
        <span className={styles.text}>{t('prompt')}</span>
        <span className={styles.content}>{suggestion.candidate.content}</span>
      </div>
      <div className={styles.actions}>
        <button type="button" className={styles.secondary} onClick={() => ignore(candidate)}>
          {t('ignore')}
        </button>
        <button
          type="button"
          className={styles.secondary}
          onClick={() => setEditor({ itemId: null, category: proposedCategory, content: candidate.content })}
        >
          {t('edit')}
        </button>
        <button type="button" className={styles.primary} onClick={() => accept(candidate)}>
          {t('save')}
        </button>
      </div>
      {editor && (
        <MemoryItemEditor session={editor} saving={false} onCancel={() => setEditor(null)} onSave={handleEditorSave} />
      )}
    </div>
  );
}
