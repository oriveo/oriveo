'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { Smartphone } from 'lucide-react';
import { BackButton } from '@oriveo/ui';
import type { MemoryCandidateRecord } from '@oriveo/core/context/memory-intent';
import { getVanillaStore } from '../../../providers/StoreProvider';
import { getActiveUIDSync } from '../../../lib/infra/storage/partition';
import { getOrCreateStableWebDeviceId } from '../../../lib/core/bootstrap';
import {
  createMemoryItemRepository,
  type MemoryItemRepository,
} from '../../../lib/core/memory/memory-item-repository';
import { createMemoryCandidateRepository } from '../../../lib/core/memory/memory-candidate-repository';
import { reportSilentError } from '../../../lib/sentry/report-silent';
import { showToast } from '../../../components/Toast';
import {
  MemoryItemEditor,
  categoryOfKind,
  categoryTitleKey,
  kindForCategory,
  type MemoryCategory,
  type MemoryEditorSession,
} from './MemoryItemEditor';
import { MemoryCategoryGlyph, MemoryEpisodicGlyph, categoryHueClass } from './MemoryGlyphs';
import styles from './MemoryPage.module.css';

type CandidateEdit = { content: string; kind?: MemoryCandidateRecord['proposedKind'] };

// Build the repository fresh on every action: the partition may have switched (same as MemoryPage runWrite).
function memoryRepositories() {
  const uid = getActiveUIDSync();
  const items = createMemoryItemRepository({ store: getVanillaStore(), uid, deviceId: getOrCreateStableWebDeviceId() });
  return { items, candidates: createMemoryCandidateRepository({ uid, items }) };
}

/** Undo of save: the item repository deletes the just-created item normally. */
function undoSave(items: MemoryItemRepository, itemId: string): void {
  items.remove(itemId).catch((error: unknown) => reportSilentError('memory-inbox.undo', error));
}

/** A kind that maps to no group goes to "About me". */
function proposedCategory(candidate: MemoryCandidateRecord): MemoryCategory {
  return categoryOfKind(candidate.proposedKind) ?? 'about';
}

/** Suggestions inbox: lists pending candidates, which can be saved / edited / ignored. */
export function MemoryInboxPage() {
  const t = useTranslations('pages.memory');
  const tSuggestion = useTranslations('pages.chat.memorySuggestion');
  const tCommon = useTranslations('common');
  const router = useRouter();

  // null until the first fetch completes, so the empty state does not flash.
  const [pending, setPending] = useState<MemoryCandidateRecord[] | null>(null);
  const [editing, setEditing] = useState<{ candidate: MemoryCandidateRecord; session: MemoryEditorSession } | null>(null);
  const [appeared, setAppeared] = useState(false);
  // Auto-suggest toggle: a local preference partitioned by account, on by default; turning it off does not delete existing pending.
  const [autoSuggest, setAutoSuggest] = useState(() => memoryRepositories().candidates.autoSuggestEnabled());
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    const id = requestAnimationFrame(() => setAppeared(true));
    return () => {
      mountedRef.current = false;
      cancelAnimationFrame(id);
    };
  }, []);

  const reload = useCallback(async () => {
    try {
      const list = await memoryRepositories().candidates.pending();
      if (mountedRef.current) setPending(list);
    } catch (error) {
      reportSilentError('memory-inbox.pending', error);
      if (mountedRef.current) setPending((current) => current ?? []);
    }
  }, []);

  useEffect(() => {
    void reload();
  }, [reload]);

  const toggleAutoSuggest = (on: boolean) => {
    memoryRepositories().candidates.setAutoSuggestEnabled(on);
    setAutoSuggest(on);
  };

  const dropRow = (id: string) => setPending((current) => current?.filter((c) => c.id !== id) ?? current);

  // Actions are not bound to the page lifecycle: if the user leaves midway, save / ignore still finish writing.
  const accept = (candidate: MemoryCandidateRecord, edit?: CandidateEdit) => {
    dropRow(candidate.id);
    void (async () => {
      const { items, candidates } = memoryRepositories();
      const outcome = await candidates.accept(candidate.id, edit ?? null);
      if ('error' in outcome) throw new Error(`memory candidate accept failed: ${outcome.error}`);
      const itemId = outcome.item.id;
      showToast(tSuggestion('saved'), 5000, () => undoSave(items, itemId), 'warning', tCommon('undo'));
    })().catch((error: unknown) => {
      reportSilentError('memory-inbox.accept', error);
      showToast(tSuggestion('failed'), 3000, undefined, 'error');
      void reload();
    });
  };

  const ignore = (candidate: MemoryCandidateRecord) => {
    dropRow(candidate.id);
    void (async () => {
      await memoryRepositories().candidates.reject(candidate.id);
    })().catch((error: unknown) => reportSilentError('memory-inbox.reject', error));
  };

  // Save after editing: the body is always given, kind is given only if the group changed; the scope is unchanged.
  const handleEditorSave = (category: MemoryCategory, content: string) => {
    if (!editing) return;
    const { candidate } = editing;
    setEditing(null);
    accept(candidate, {
      content,
      ...(category !== proposedCategory(candidate) ? { kind: kindForCategory(category) } : {}),
    });
  };

  return (
    <div className={`${styles.page} ${appeared ? styles.pageAppeared : ''}`}>
      <BackButton className={styles.backLink} label={tCommon('back')} onClick={() => router.push('/settings/memory')} />

      <header className={styles.header}>
        <div className={styles.headerTitleRow}>
          <h1 className={styles.title}>{t('inboxTitle')}</h1>
          {pending !== null && pending.length > 0 && (
            <span className={styles.titleCount} aria-hidden>
              {pending.length}
            </span>
          )}
        </div>
      </header>

      <div className={styles.pageGrid}>
        {/* Toggle stays above the list in DOM order (narrow layout); wide layout moves it to the side column. */}
        <aside className={`${styles.sidebar} ${styles.inboxSidebar}`}>
          <section className={`${styles.card} ${styles.inboxToggleCard}`}>
            <label className={styles.inboxToggle}>
              <span className={styles.inboxToggleTitle}>{t('inboxAutoSuggest')}</span>
              <input
                type="checkbox"
                role="switch"
                className={styles.inboxSwitch}
                aria-describedby="memory-inbox-auto-suggest-footnote"
                checked={autoSuggest}
                onChange={(e) => toggleAutoSuggest(e.target.checked)}
              />
            </label>
            <p id="memory-inbox-auto-suggest-footnote" className={styles.inboxToggleFootnote}>
              {t('inboxAutoSuggestFootnote')}
            </p>
          </section>
          <p className={styles.footnote}>
            <Smartphone size={13} strokeWidth={1.8} aria-hidden />
            <span>{t('inboxFootnote')}</span>
          </p>
        </aside>
        {pending === null ? null : pending.length === 0 ? (
          <section className={`${styles.card} ${styles.inboxMain}`}>
            <p className={styles.inboxEmpty}>{t('inboxEmpty')}</p>
          </section>
        ) : (
          <section className={`${styles.card} ${styles.inboxMain}`}>
            <ul className={styles.inboxList}>
              {pending.map((candidate) => {
                const category = proposedCategory(candidate);
                // episodic candidates (decision / event) go to "Events and decisions", grouped by layer.
                const episodic = candidate.proposedLayer === 'episodic';
                return (
                  <li
                    key={candidate.id}
                    className={`${styles.inboxRow} ${episodic ? styles.hueEpisodic : categoryHueClass(category)}`}
                    data-testid="memory-inbox-row"
                  >
                    <div className={styles.inboxRowBody}>
                      <span className={styles.inboxGroup}>
                        <span className={styles.inboxGroupGlyph} aria-hidden>
                          {episodic ? <MemoryEpisodicGlyph size={13} /> : <MemoryCategoryGlyph category={category} size={13} />}
                        </span>
                        {episodic ? t('groupEpisodic') : t(categoryTitleKey(category))}
                      </span>
                      <span className={styles.inboxQuote}>
                        <span className={styles.inboxQuoteMark} aria-hidden>“</span>
                        <span data-testid="memory-inbox-content">{candidate.content}</span>
                      </span>
                    </div>
                    <div className={styles.inboxActions}>
                      <button type="button" className={styles.inboxSecondary} onClick={() => ignore(candidate)}>
                        {tSuggestion('ignore')}
                      </button>
                      <button
                        type="button"
                        className={styles.inboxSecondary}
                        onClick={() => setEditing({
                          candidate,
                          session: { itemId: null, category, content: candidate.content },
                        })}
                      >
                        {tSuggestion('edit')}
                      </button>
                      <button type="button" className={styles.inboxPrimary} onClick={() => accept(candidate)}>
                        {tSuggestion('save')}
                      </button>
                    </div>
                  </li>
                );
              })}
            </ul>
          </section>
        )}

      </div>

      {editing && (
        <MemoryItemEditor
          key={editing.candidate.id}
          session={editing.session}
          saving={false}
          onCancel={() => setEditing(null)}
          onSave={handleEditorSave}
        />
      )}
    </div>
  );
}
