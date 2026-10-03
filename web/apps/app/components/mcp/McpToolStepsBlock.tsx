'use client';

import { useEffect, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import { AlertCircle, Ban, Check, ChevronDown, LoaderCircle, Wrench } from 'lucide-react';
import type { McpToolStep, McpToolStepStatus } from '@oriveo/shared';
import { resolveMcpReauthorization, useMcpReauthorizationStore } from '../../lib/core/mcp/mcp-confirmation';
import { useMcpStore } from '../../lib/core/mcp/mcp-store';
import { buildMcpStepsPresentation, mcpStepFailureKey, type McpStepRow } from '../../lib/core/mcp/mcp-steps-presentation';
import { mcpToolStepDisplayTitle } from '../../lib/core/mcp/mcp-tool-steps';
import { McpReauthDialog } from './McpReauthDialog';
import { McpStepDetailDialog } from './McpStepDetailDialog';
import styles from './Mcp.module.css';

const STATUS_KEYS: Record<McpToolStepStatus, 'statusDone' | 'statusRunning' | 'statusFailed' | 'statusNeedsAuth' | 'statusDeclined' | 'statusInterrupted'> = {
  done: 'statusDone',
  running: 'statusRunning',
  failed: 'statusFailed',
  needsAuth: 'statusNeedsAuth',
  denied: 'statusDeclined',
  interrupted: 'statusInterrupted',
};

function StatusIcon({ status }: { status: McpToolStepStatus }) {
  if (status === 'running') return <LoaderCircle size={16} className={styles.spinner} aria-hidden="true" />;
  if (status === 'done') return <Check size={11} strokeWidth={3} aria-hidden="true" />;
  if (status === 'failed' || status === 'needsAuth') return <AlertCircle size={16} aria-hidden="true" />;
  return <Ban size={15} aria-hidden="true" />;
}

/**
 * The block of MCP tool steps inside a message. Expanded while running and collapsed automatically
 * once the reply completes; after the user expands or collapses it by hand it no longer changes on
 * its own.
 */
export function McpToolStepsBlock({
  steps,
  isStreaming,
  messageId,
  conversationId,
  limitReached = false,
}: {
  steps: readonly McpToolStep[];
  isStreaming: boolean;
  messageId: string;
  conversationId?: string;
  limitReached?: boolean;
}) {
  const t = useTranslations('mcp.chat.steps');
  const pendingReauth = useMcpReauthorizationStore((state) =>
    state.pending.find((item) => item.request.conversationId === conversationId && steps.some((step) => step.id === item.request.stepId)) ?? null,
  );
  const reauthServer = useMcpStore((state) =>
    pendingReauth ? state.servers.find((server) => server.id === pendingReauth.request.serverId) ?? null : null,
  );
  const presentation = buildMcpStepsPresentation({ steps, isGenerating: isStreaming, limitReached, pausedStepId: pendingReauth?.request.stepId });

  const touched = useRef(false);
  const [expanded, setExpanded] = useState(presentation.isActive);
  const [showEarlier, setShowEarlier] = useState(false);
  const [detailStep, setDetailStep] = useState<McpStepRow | null>(null);
  const [reauthOpen, setReauthOpen] = useState(false);

  useEffect(() => {
    if (touched.current) return;
    setExpanded(presentation.isActive);
  }, [presentation.isActive]);

  if (steps.length === 0) return null;

  const title =
    presentation.header === 'running'
      ? t('running')
      : presentation.header === 'waitingAuth'
        ? t('waitingAuth')
        : t('used', { count: presentation.header.finished });
  const trailing =
    presentation.trailing.kind === 'step'
      ? t('step', { step: presentation.trailing.step })
      : presentation.trailing.kind === 'failed'
        ? t('failed', { count: presentation.trailing.count })
        : presentation.trailing.kind === 'declined'
          ? t('declined', { count: presentation.trailing.count })
          : // Server names are third-party text, so they are joined with a language-neutral separator (as the library confirmation dialog does).
            presentation.trailing.names.join(' · ');

  const hidden = showEarlier ? 0 : presentation.hiddenEarlierCount;
  const visibleRows = hidden > 0 ? presentation.rows.slice(hidden) : presentation.rows;

  const detailText = (row: McpStepRow): { text: string; tone?: 'danger' | 'warning' } => {
    switch (row.detail.kind) {
      case 'args':
        return { text: row.detail.text };
      case 'declined':
        return { text: t('stepDeclined') };
      case 'interrupted':
        return { text: t('stepInterrupted') };
      case 'authExpired':
        return { text: t('stepAuthExpired', { server: row.detail.server }), tone: 'warning' };
      case 'failure':
        return { text: t(mcpStepFailureKey(row.detail.code)), tone: 'danger' };
    }
  };

  return (
    <section className={styles.stepsBlock} aria-label={title} data-mcp-steps data-state={typeof presentation.header === 'string' ? presentation.header : 'finished'}>
      <button
        type="button"
        className={styles.stepsHeader}
        aria-expanded={expanded}
        onClick={() => {
          touched.current = true;
          setExpanded((value) => !value);
        }}
      >
        <Wrench size={15} className={styles.stepsHeaderIcon} aria-hidden="true" />
        <span className={styles.stepsTitle}>{title}</span>
        <span className={styles.stepsTrailing}>{trailing}</span>
        <ChevronDown size={15} className={styles.stepsChevron} data-expanded={expanded || undefined} aria-hidden="true" />
      </button>

      {expanded ? (
        <div className={styles.stepsBody}>
          {hidden > 0 ? (
            <button type="button" className={styles.linkButton} onClick={() => setShowEarlier(true)}>
              {t('showEarlier', { count: hidden })}
            </button>
          ) : null}
          <ol className={styles.stepRows} aria-live="polite" aria-atomic="false">
            {visibleRows.map((row) => {
              const detail = detailText(row);
              const content = (
                <>
                  <span className={styles.stepText}>
                    {/* Server name and tool title are third-party text and are not translated. */}
                    <strong>{row.step.serverName ? `${row.step.serverName} · ` : ''}{mcpToolStepDisplayTitle(row.step)}</strong>
                    {detail.text ? <span data-tone={detail.tone}>{detail.text}</span> : null}
                  </span>
                  <span className={styles.stepStatus} data-status={row.status} role="img" aria-label={t(STATUS_KEYS[row.status])}>
                    <StatusIcon status={row.status} />
                  </span>
                </>
              );
              return (
                <li key={row.step.id} data-status={row.status}>
                  {row.opensDetail ? (
                    <button type="button" className={styles.stepRow} onClick={() => setDetailStep(row)}>
                      {content}
                    </button>
                  ) : (
                    <div className={styles.stepRow}>{content}</div>
                  )}
                </li>
              );
            })}
          </ol>

          {presentation.pausedStep && pendingReauth ? (
            <div className={styles.stepsPause} data-mcp-paused>
              <div className={styles.stepsPauseActions}>
                <button type="button" className={styles.softPrimaryButton} onClick={() => setReauthOpen(true)}>
                  {t('reauthorize')}
                </button>
                <button type="button" className={styles.outlineButton} onClick={() => resolveMcpReauthorization(pendingReauth.id, 'skip')}>
                  {t('skip')}
                </button>
              </div>
              <p className={styles.footnote}>{t('reauthHint')}</p>
            </div>
          ) : null}

          {presentation.limitReached ? <p className={styles.stepsLimit}>{t('limitReached')}</p> : null}
        </div>
      ) : null}

      {detailStep ? (
        <McpStepDetailDialog step={detailStep.step} status={detailStep.status} messageId={messageId} onClose={() => setDetailStep(null)} />
      ) : null}
      {reauthOpen && pendingReauth ? (
        <McpReauthDialog
          server={reauthServer}
          trigger="mid_loop"
          onClose={() => setReauthOpen(false)}
          onAuthorized={() => resolveMcpReauthorization(pendingReauth.id, 'reauthorized')}
        />
      ) : null}
    </section>
  );
}
