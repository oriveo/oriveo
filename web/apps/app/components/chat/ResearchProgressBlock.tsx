'use client';

import { useState } from 'react';
import { useTranslations } from 'next-intl';
import { Check, ChevronDown, FileText, ListTree, LoaderCircle, Search, Sparkles, X } from 'lucide-react';
import type { ChatMessage } from '@oriveo/shared';
import styles from './ResearchProgressBlock.module.css';

type ResearchStep = NonNullable<ChatMessage['researchSteps']>[number];

export function ResearchProgressBlock({ steps, isStreaming }: { steps: ResearchStep[]; isStreaming: boolean }) {
  const t = useTranslations('library');
  const [expanded, setExpanded] = useState(true);
  if (steps.length === 0) return null;
  const completed = steps.filter((step) => step.status === 'completed').length;

  return (
    <section className={styles.block} aria-label={t('progress.title')}>
      <button type="button" className={styles.header} onClick={() => setExpanded((value) => !value)} aria-expanded={expanded}>
        <span>{isStreaming ? t('progress.running') : t('progress.complete')}</span>
        <span className={styles.count}>{completed}/{steps.length}</span>
        <ChevronDown size={14} data-expanded={expanded} aria-hidden="true" />
      </button>
      {expanded ? (
        <ol className={styles.steps} aria-live="polite" aria-atomic="false">
          {steps.map((step, index) => (
            <li key={`${step.tool}:${index}`} data-status={step.status}>
              <span className={styles.toolIcon} aria-hidden="true">{toolIcon(step.tool)}</span>
              <span className={styles.label}>
                <strong>{t(`progress.tool.${toolKey(step.tool)}`)}</strong>
                <span>{step.label}</span>
              </span>
              <span className={styles.stateIcon} aria-label={t(`progress.status.${step.status}`)}>
                {statusIcon(step.status)}
              </span>
            </li>
          ))}
        </ol>
      ) : null}
    </section>
  );
}

function toolKey(tool: string): 'search' | 'list' | 'read' | 'synthesize' {
  if (tool === 'library_search') return 'search';
  if (tool === 'library_list') return 'list';
  if (tool === 'library_read') return 'read';
  return 'synthesize';
}

function toolIcon(tool: string) {
  const props = { size: 14, strokeWidth: 2.1 };
  if (tool === 'library_search') return <Search {...props} />;
  if (tool === 'library_list') return <ListTree {...props} />;
  if (tool === 'library_read') return <FileText {...props} />;
  return <Sparkles {...props} />;
}

function statusIcon(status: ResearchStep['status']) {
  if (status === 'running' || status === 'pending') return <LoaderCircle size={13} className={styles.spinner} aria-hidden="true" />;
  if (status === 'failed') return <X size={13} aria-hidden="true" />;
  return <Check size={13} aria-hidden="true" />;
}
