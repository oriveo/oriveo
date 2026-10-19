'use client';

import { useEffect, useState } from 'react';
import { useTranslations } from 'next-intl';
import { Button, Dialog } from '@oriveo/ui';
import { MemoryItems, type MemoryItem, type MemoryOrganizedEntry } from '@oriveo/core/context/memory-items';
import {
  requestMemoryOrganize,
  type MemoryModelCandidate,
} from '../../../lib/core/memory/memory-organize';
import { categoryOfKind, categoryTitleKey } from './MemoryItemEditor';
import type { MemoryRunWrite } from './MemoryRawView';
import styles from './MemoryPage.module.css';

type OrganizePhase =
  | { kind: 'noModel' }
  | { kind: 'loading' }
  | { kind: 'failed' }
  | { kind: 'empty' }
  | { kind: 'ready'; entries: MemoryOrganizedEntry[] };

interface MemoryOrganizeDialogProps {
  item: MemoryItem;
  /** The one candidate confirmed in the disclosure dialog (only the first is used); empty = no usable model, shows organizeNoModel. */
  candidates: readonly MemoryModelCandidate[];
  runWrite: MemoryRunWrite;
  onClose: () => void;
}

export function MemoryOrganizeDialog({ item, candidates, runWrite, onClose }: MemoryOrganizeDialogProps) {
  const t = useTranslations('pages.memory');
  const tCommon = useTranslations('common');
  // The original text and candidate are fixed on open; later store changes do not resend the request.
  const [request] = useState(() => ({ content: item.content, candidate: candidates[0] ?? null }));
  const [phase, setPhase] = useState<OrganizePhase>(() => (
    request.candidate === null ? { kind: 'noModel' } : { kind: 'loading' }
  ));
  const [selected, setSelected] = useState<boolean[]>([]);
  const [keepOriginal, setKeepOriginal] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    const candidate = request.candidate;
    if (candidate === null) return;
    let cancelled = false;
    void (async () => {
      // Request only this one candidate; a failure is failed, with no switching to another provider; a reply that is empty after trim also counts as failed;
      // a non-empty reply is decided by the parse result (parsed empty = no items split out).
      try {
        const reply = await requestMemoryOrganize({
          provider: candidate.provider,
          model: candidate.model,
          content: request.content,
        });
        if (cancelled) return;
        if (!reply.trim()) {
          setPhase({ kind: 'failed' });
          return;
        }
        const entries = MemoryItems.organizeParse(reply);
        if (entries.length === 0) {
          setPhase({ kind: 'empty' });
        } else {
          setSelected(entries.map(() => true));
          setPhase({ kind: 'ready', entries });
        }
      } catch {
        if (!cancelled) setPhase({ kind: 'failed' });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [request]);

  const entries = phase.kind === 'ready' ? phase.entries : [];
  const chosen = entries.filter((_, index) => selected[index]);

  const handleSave = async () => {
    if (chosen.length === 0) return;
    setSaving(true);
    const ok = await runWrite('organize', async (repository) => {
      for (const entry of chosen) {
        await repository.create({ kind: entry.kind, content: entry.content });
      }
      if (!keepOriginal) await repository.remove(item.id);
    });
    setSaving(false);
    if (ok) onClose();
  };

  const statusLine = (() => {
    switch (phase.kind) {
      case 'noModel':
        return t('organizeNoModel');
      case 'loading':
        return t('organizeLoading');
      case 'failed':
        return t('organizeFailed');
      case 'empty':
        return t('organizeEmpty');
      default:
        return null;
    }
  })();

  return (
    <Dialog open onClose={onClose}>
      <h2 className={styles.dialogTitle}>{t('actionOrganize')}</h2>
      {statusLine !== null && (
        <p
          className={`${styles.dialogMessage} ${styles.organizeStatus}`}
          role={phase.kind === 'loading' ? 'status' : 'alert'}
        >
          {phase.kind === 'loading' && <span className={styles.organizeSpinner} aria-hidden />}
          <span>{statusLine}</span>
        </p>
      )}
      {phase.kind === 'ready' && (
        <>
          <ul className={styles.organizeList}>
            {entries.map((entry, index) => (
              <li key={entry.content} className={styles.organizeRow}>
                <label className={styles.organizeLabel}>
                  <input
                    type="checkbox"
                    checked={selected[index] ?? false}
                    onChange={(e) => {
                      const checked = e.target.checked;
                      setSelected((prev) => prev.map((value, k) => (k === index ? checked : value)));
                    }}
                  />
                  <span className={styles.organizeCategory}>
                    {t(categoryTitleKey(categoryOfKind(entry.kind) ?? 'about'))}
                  </span>
                  <span className={styles.organizeContent}>{entry.content}</span>
                </label>
              </li>
            ))}
          </ul>
          <label className={styles.organizeKeep}>
            <input
              type="checkbox"
              role="switch"
              checked={keepOriginal}
              onChange={(e) => setKeepOriginal(e.target.checked)}
            />
            <span>{t('organizeKeepOriginal')}</span>
          </label>
        </>
      )}
      <div className={styles.dialogActions}>
        <Button tone="secondary" size="sm" onClick={onClose}>
          {tCommon('cancel')}
        </Button>
        {phase.kind === 'ready' && (
          <Button size="sm" disabled={saving || chosen.length === 0} onClick={() => void handleSave()}>
            {t('organizeSave')}
          </Button>
        )}
      </div>
    </Dialog>
  );
}
