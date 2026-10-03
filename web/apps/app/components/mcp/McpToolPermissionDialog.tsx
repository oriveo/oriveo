'use client';

import { useTranslations } from 'next-intl';
import { Check } from 'lucide-react';
import { Button, Dialog } from '@oriveo/ui';
import type { McpServerRecord, McpToolPermission, McpToolSnapshot } from '@oriveo/core/mcp/index';
import styles from './Mcp.module.css';

/**
 * Permission for a single tool. The description is the server's own text and is not translated. For a
 * tool that modifies data, the caption of the "run automatically" option is itself the warning; the
 * default option is labelled "Recommended".
 */
export function McpToolPermissionDialog({
  server,
  tool,
  permission,
  onChange,
  onClose,
}: {
  server: McpServerRecord;
  tool: McpToolSnapshot | null;
  permission: McpToolPermission;
  onChange: (permission: McpToolPermission) => void;
  onClose: () => void;
}) {
  const t = useTranslations('mcp.permission');
  if (!tool) return null;
  const recommended: McpToolPermission = tool.readOnly ? 'auto' : 'ask';
  const options: Array<{ value: McpToolPermission; title: string; hint: string; warning?: boolean }> = [
    {
      value: 'auto',
      title: t('auto'),
      hint: tool.readOnly ? t('autoHintRead') : t('autoHintWrite', { server: server.name }),
      warning: !tool.readOnly,
    },
    { value: 'ask', title: t('ask'), hint: t('askHint') },
    { value: 'off', title: t('off'), hint: t('offHint') },
  ];
  return (
    <Dialog open onClose={onClose} ariaLabelledBy="mcp-permission-title" className={styles.dialog} lockBodyScroll>
      <div className={styles.dialogHeadText}>
        <h2 id="mcp-permission-title" className={styles.dialogTitle}>{tool.title}</h2>
      </div>
      <div className={styles.codeSection} style={{ marginBlockStart: 14 }}>
        <div className={styles.codeSectionHead}><span>{t('descriptionTitle')}</span></div>
        <p className={styles.codeBlock} style={{ fontFamily: 'inherit', fontSize: 13.5 }}>{tool.description || t('noDescription')}</p>
      </div>
      <div className={styles.radioCards} role="radiogroup" aria-labelledby="mcp-permission-title">
        {options.map((option) => (
          <button
            key={option.value}
            type="button"
            role="radio"
            aria-checked={permission === option.value}
            className={styles.radioCard}
            data-mcp-permission={option.value}
            onClick={() => onChange(option.value)}
          >
            <span className={styles.radioMark} aria-hidden="true"><Check size={12} strokeWidth={3} /></span>
            <span className={styles.radioText}>
              <span className={styles.radioTitle}>
                {option.title}
                {option.value === recommended ? <span className={styles.recommended}>{t('recommended')}</span> : null}
              </span>
              <span className={styles.radioHint} data-tone={option.warning ? 'warning' : undefined}>{option.hint}</span>
            </span>
          </button>
        ))}
      </div>
      <div className={styles.dialogActions}>
        <Button data-mcp-primary onClick={onClose}>{t('done')}</Button>
      </div>
    </Dialog>
  );
}
