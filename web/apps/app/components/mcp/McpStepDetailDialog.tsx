'use client';

import { useEffect, useState } from 'react';
import { useTranslations } from 'next-intl';
import { Dialog } from '@oriveo/ui';
import type { McpToolStep, McpToolStepStatus } from '@oriveo/shared';
import { fetchMcpStepPayload, type McpStepPayload } from '../../lib/core/mcp/mcp-idb';
import { mcpDurationParts } from '../../lib/core/mcp/mcp-presentation';
import { useMcpStore } from '../../lib/core/mcp/mcp-store';
import { mcpToolStepDisplayTitle } from '../../lib/core/mcp/mcp-tool-steps';
import { McpServerIcon } from './McpServerIcon';
import styles from './Mcp.module.css';

const STATUS_KEYS: Record<McpToolStepStatus, 'statusDone' | 'statusRunning' | 'statusFailed' | 'statusNeedsAuth' | 'statusDeclined' | 'statusInterrupted'> = {
  done: 'statusDone',
  running: 'statusRunning',
  failed: 'statusFailed',
  needsAuth: 'statusNeedsAuth',
  denied: 'statusDeclined',
  interrupted: 'statusInterrupted',
};

/** Canonical JSON to a readable indented form; shown unchanged when it cannot be parsed. */
function prettyArguments(raw: string): string {
  try {
    return JSON.stringify(JSON.parse(raw), null, 2);
  } catch {
    return raw;
  }
}

/**
 * Details of a single step. Arguments and result are the step payload, which is stored only on the
 * device that ran the step: when this device does not have it, a one-line note replaces the code blocks
 * instead of showing them empty. Only the first 2 KB of the result is kept, and "Copy" copies exactly
 * the part that is shown.
 */
export function McpStepDetailDialog({
  step,
  status,
  messageId,
  onClose,
}: {
  step: McpToolStep;
  status: McpToolStepStatus;
  messageId: string;
  onClose: () => void;
}) {
  const t = useTranslations('mcp.chat');
  const uid = useMcpStore((state) => state.uid);
  const iconServer = useMcpStore((state) => state.servers.find((server) => server.id === step.serverId) ?? null);
  const [payload, setPayload] = useState<McpStepPayload | null | undefined>(undefined);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    let cancelled = false;
    if (!uid) {
      setPayload(null);
      return;
    }
    fetchMcpStepPayload(uid, messageId, step.id)
      .then((value) => {
        if (!cancelled) setPayload(value);
      })
      .catch(() => {
        if (!cancelled) setPayload(null);
      });
    return () => {
      cancelled = true;
    };
  }, [messageId, step.id, uid]);

  const duration = step.durationMs != null ? mcpDurationParts(step.durationMs) : null;
  const statusLabel = t(`steps.${STATUS_KEYS[status]}`);
  const subtitle = duration
    ? t('detail.subtitle', {
        server: step.serverName,
        duration: duration.unit === 'ms' ? t('detail.durationMs', { value: duration.value }) : t('detail.durationS', { value: duration.value }),
        status: statusLabel,
      })
    : t('detail.subtitleNoDuration', { server: step.serverName, status: statusLabel });

  const copy = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard unavailable (permission or insecure context): do not report success.
    }
  };

  return (
    <Dialog open onClose={onClose} size="lg" ariaLabelledBy="mcp-step-detail-title" className={styles.dialog} lockBodyScroll>
      <div className={styles.dialogHead}>
        <McpServerIcon name={step.serverName} iconURL={iconServer?.iconURL} serverURL={iconServer?.url} size={44} />
        <div className={styles.dialogHeadText}>
          <h2 id="mcp-step-detail-title" className={styles.dialogTitle}>{mcpToolStepDisplayTitle(step)}</h2>
          <p className={styles.dialogSubtitle}>{subtitle}</p>
        </div>
      </div>

      {payload === undefined ? null : payload === null ? (
        <p className={styles.noticeBlock} data-tone="neutral" data-mcp-state="payload-missing">{t('detail.localOnly')}</p>
      ) : (
        <>
          <div className={styles.codeSection}>
            <div className={styles.codeSectionHead}><span>{t('detail.sent')}</span></div>
            {payload.arguments ? <pre className={styles.codeBlock}>{prettyArguments(payload.arguments)}</pre> : <p className={styles.footnote}>{t('detail.nothingSent')}</p>}
          </div>
          <div className={styles.codeSection}>
            <div className={styles.codeSectionHead}>
              <span>{t('detail.returned')}</span>
              {payload.resultPrefix ? (
                <button type="button" className={styles.linkButton} onClick={() => void copy(payload.resultPrefix ?? '')}>
                  {copied ? t('detail.copied') : t('detail.copy')}
                </button>
              ) : null}
            </div>
            {/* Third-party content is shown as plain text only: no Markdown rendering, no link detection. */}
            {payload.resultPrefix ? <pre className={styles.codeBlock}>{payload.resultPrefix}</pre> : <p className={styles.footnote}>{t('detail.nothingReturned')}</p>}
          </div>
          <p className={styles.footnote}>{t('detail.notice')}</p>
        </>
      )}

      <div className={styles.dialogActions}>
        <button type="button" className={styles.quietButton} onClick={onClose}>{t('detail.close')}</button>
      </div>
    </Dialog>
  );
}
