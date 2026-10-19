'use client';

import { useMemo, useState } from 'react';
import { useTranslations } from 'next-intl';
import { CircleAlert } from 'lucide-react';
import { MemoryItems, type MemoryItem, type MemoryRawOp } from '@oriveo/core/context/memory-items';
import type { MemoryItemRepository } from '../../../lib/core/memory/memory-item-repository';
import styles from './MemoryPage.module.css';

export type MemoryRunWrite = (
  context: string,
  op: (repository: MemoryItemRepository) => Promise<unknown>,
) => Promise<boolean>;

/** Hands rawApply's ops to the repository in order (automatic dual write / sync). */
export async function applyMemoryRawOps(repository: MemoryItemRepository, ops: readonly MemoryRawOp[]): Promise<void> {
  for (const op of ops) {
    if (op.op === 'update') {
      await repository.update(op.id, { content: op.content });
    } else if (op.op === 'create') {
      await repository.create({ kind: op.kind, content: op.content });
    } else {
      await repository.remove(op.id);
    }
  }
}

/** rawApply needs an id for every newly created segment: the segment count is at most the number of separator lines + 1. */
function placeholderIds(text: string): string[] {
  const separator = MemoryItems.constants.rawViewSeparator;
  const separators = text.split('\n').filter((line) => line.replace(/\r$/, '') === separator).length;
  return Array.from({ length: separators + 1 }, () => globalThis.crypto.randomUUID().toLowerCase());
}

interface RawLine {
  text: string;
  separator: boolean;
  /** Index among non-empty segments (rawApply's tooLong index); null for separators and blank segments. */
  segment: number | null;
}

/** Splits the text into lines and tags each with the non-empty segment it belongs to. */
function rawLines(text: string): RawLine[] {
  const separator = MemoryItems.constants.rawViewSeparator;
  const lines = text.split('\n');
  const result: RawLine[] = [];
  let segmentLines: RawLine[] = [];
  let nextSegment = 0;
  const closeSegment = () => {
    const blank = segmentLines.every((line) => line.text.trim() === '');
    if (!blank) {
      for (const line of segmentLines) line.segment = nextSegment;
      nextSegment += 1;
    }
    segmentLines = [];
  };
  for (const raw of lines) {
    if (raw.replace(/\r$/, '') === separator) {
      closeSegment();
      result.push({ text: raw, separator: true, segment: null });
      continue;
    }
    const line: RawLine = { text: raw, separator: false, segment: null };
    segmentLines.push(line);
    result.push(line);
  }
  closeSegment();
  return result;
}

interface MemoryRawViewProps {
  /** All items in the slice; only active semantic items are rendered. */
  items: readonly MemoryItem[];
  runWrite: MemoryRunWrite;
  /** Called after a successful save (including no changes). */
  onSaved: () => void;
  /** Cancel: write nothing and go back to the list (same handler as pressing "Raw" again). */
  onCancel: () => void;
}

export function MemoryRawView({ items, runWrite, onSaved, onCancel }: MemoryRawViewProps) {
  const t = useTranslations('pages.memory');
  const tCommon = useTranslations('common');
  const [text, setText] = useState(() => MemoryItems.rawRender([...items]));
  const [tooLongIndex, setTooLongIndex] = useState<number | null>(null);
  const [saving, setSaving] = useState(false);
  const lines = useMemo(() => rawLines(text), [text]);

  const handleSave = async () => {
    const result = MemoryItems.rawApply({ items: [...items], text, newIds: placeholderIds(text) });
    if ('error' in result) {
      // One segment is too long: nothing is written, and the hint names which segment (counted from 1 for the user).
      setTooLongIndex(result.index);
      return;
    }
    setTooLongIndex(null);
    if (result.ops.length === 0) {
      onSaved();
      return;
    }
    setSaving(true);
    const ok = await runWrite('rawApply', (repository) => applyMemoryRawOps(repository, result.ops));
    setSaving(false);
    if (ok) onSaved();
  };

  return (
    <div className={styles.rawView}>
      <p className={styles.rawViewHint}>
        <code className={styles.rawViewHintCode} aria-hidden>
          {MemoryItems.constants.rawViewSeparator}
        </code>
        <span>{t('rawViewHint')}</span>
      </p>
      <div className={styles.rawViewEditor}>
        {/* Mirror under the textarea: same wrapping, draws the line-number gutter and the too-long highlight. */}
        <div className={styles.rawViewMirror} aria-hidden>
          {lines.map((line, index) => (
            <div
              key={index}
              className={[
                styles.rawViewLine,
                line.separator ? styles.rawViewLineSeparator : '',
                tooLongIndex !== null && line.segment === tooLongIndex ? styles.rawViewLineError : '',
              ].filter(Boolean).join(' ')}
            >
              <span className={styles.rawViewLineNo}>{index + 1}</span>
              <span className={styles.rawViewLineText}>{line.text === '' ? '\u200b' : line.text}</span>
            </div>
          ))}
        </div>
        <textarea
          className={styles.rawViewTextarea}
          aria-label={t('rawView')}
          data-testid="memory-raw-textarea"
          value={text}
          onChange={(e) => {
            setText(e.target.value);
            setTooLongIndex(null);
          }}
          spellCheck={false}
        />
      </div>
      <div className={styles.rawViewFooter}>
        {tooLongIndex !== null && (
          <span className={styles.rawViewError} role="alert">
            <CircleAlert size={15} strokeWidth={2} aria-hidden />
            {t('rawViewTooLong', { index: tooLongIndex + 1 })}
          </span>
        )}
        <span className={styles.itemEditorFooterSpacer} />
        <button type="button" className={styles.btnSecondary} onClick={onCancel}>
          {tCommon('cancel')}
        </button>
        <button
          type="button"
          className={styles.btnPrimary}
          data-testid="memory-raw-save"
          disabled={saving}
          onClick={() => void handleSave()}
        >
          {t('rawViewSave')}
        </button>
      </div>
    </div>
  );
}
